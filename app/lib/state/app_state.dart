import 'dart:async';
import 'dart:convert';

import 'package:agy_client/agy_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'native_bridge.dart';

const _kPairingStorageKey = 'agy_mobile_pairing_v1';
const _kQuotaCollapsedKey = 'agy_mobile_quota_collapsed';
const _kSecureStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(resetOnError: true),
);

class HostConnectionState {
  const HostConnectionState({
    this.pairing,
    this.activeEndpoint,
    this.isDirect = true,
    this.rttMs,
    this.desktopOnline = false,
    this.status = MuxConnectionStatus.disconnected,
    this.errorMessage,
    this.alwaysOnEnabled = true,
    this.workspaces = const [],
    this.models = const [],
    this.transportEpoch = 0,
  });

  final PairingPayload? pairing;
  final String? activeEndpoint;
  final bool isDirect;
  final int? rttMs;
  final bool desktopOnline;
  final MuxConnectionStatus status;
  final String? errorMessage;
  final bool alwaysOnEnabled;
  final List<WorkspaceInfo> workspaces;
  final List<ModelOption> models;
  final int transportEpoch;

  bool get isPaired => pairing != null && pairing!.token.isNotEmpty;
  String get hostName => pairing?.hostName ?? '未连接主机';

  String get connectionBanner {
    if (!isPaired) return '点击扫码配对 Mac 主机';
    switch (status) {
      case MuxConnectionStatus.connected:
        final mode = isDirect ? '已直连' : '公网5G';
        final ping = rttMs != null ? ' (${rttMs}ms)' : '';
        return '$hostName · $mode$ping';
      case MuxConnectionStatus.connecting:
        return '$hostName · 连接中...';
      case MuxConnectionStatus.reconnecting:
        return '$hostName · 重连中...';
      case MuxConnectionStatus.disconnected:
        return '$hostName · 未连接';
    }
  }

  HostConnectionState copyWith({
    PairingPayload? pairing,
    bool clearPairing = false,
    String? activeEndpoint,
    bool? isDirect,
    int? rttMs,
    bool clearRtt = false,
    bool? desktopOnline,
    MuxConnectionStatus? status,
    String? errorMessage,
    bool clearError = false,
    bool? alwaysOnEnabled,
    List<WorkspaceInfo>? workspaces,
    List<ModelOption>? models,
    int? transportEpoch,
  }) {
    return HostConnectionState(
      pairing: clearPairing ? null : (pairing ?? this.pairing),
      activeEndpoint: clearPairing ? null : (activeEndpoint ?? this.activeEndpoint),
      isDirect: isDirect ?? this.isDirect,
      rttMs: clearRtt ? null : (rttMs ?? this.rttMs),
      desktopOnline: desktopOnline ?? this.desktopOnline,
      status: status ?? this.status,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      alwaysOnEnabled: alwaysOnEnabled ?? this.alwaysOnEnabled,
      workspaces: workspaces ?? this.workspaces,
      models: models ?? this.models,
      transportEpoch: transportEpoch ?? this.transportEpoch,
    );
  }
}

class HostConnectionNotifier extends Notifier<HostConnectionState> {
  final FlutterSecureStorage _storage = _kSecureStorage;
  AgyHttpCarrier? _carrier;
  AgyMuxClient? _mux;
  StreamSubscription? _statusSub;
  StreamSubscription? _rttSub;
  StreamSubscription? _msgSub;
  String? _activeConversationId;
  bool _reprobingEndpoints = false;
  Future<void>? _verifyFuture;
  int _lastReprobeAtMs = 0;
  String _networkKind = 'unknown';
  String? _lastAlwaysOnBanner;

  AgyHttpCarrier? get carrier => _carrier;
  AgyMuxClient? get mux => _mux;

  @override
  HostConnectionState build() {
    ref.onDispose(_teardownTransport);
    NativeBridge.instance.init();
    NativeBridge.instance.onNotificationReply = _handleNotificationReply;
    NativeBridge.instance.onNetworkChanged = _handleNetworkChanged;
    Future.microtask(_loadSavedPairing);
    return const HostConnectionState();
  }

  void _handleNetworkChanged(String kind) {
    _networkKind = kind;
    if (!state.isPaired) return;
    if (kind == 'none') {
      state = state.copyWith(
        status: MuxConnectionStatus.reconnecting,
        desktopOnline: false,
        clearRtt: true,
      );
      _syncAlwaysOnNotification();
      return;
    }
    // Network switched (e.g. Wi-Fi turned off -> 5G cellular, or Wi-Fi restored):
    // immediately probe all endpoints and switch to the fastest reachable route.
    unawaited(verifyConnection(forceReprobe: true));
  }

  void setActiveConversation(String? convId) {
    _activeConversationId = convId;
  }

  Future<void> _loadSavedPairing() async {
    try {
      final raw = await _storage.read(key: _kPairingStorageKey);
      if (raw == null || raw.isEmpty) return;
      final payload = PairingPayload.parseQr(raw);
      await connectWithPairing(payload, persist: false);
    } catch (_) {}
  }

  Future<void> connectWithPairing(
    PairingPayload payload, {
    bool persist = true,
    EndpointProbeResult? preProbed,
  }) async {
    _teardownTransport();
    state = state.copyWith(
      pairing: payload,
      status: MuxConnectionStatus.connecting,
      desktopOnline: false,
      clearRtt: true,
      clearError: true,
    );
    _syncAlwaysOnNotification();

    if (persist) {
      try {
        await _storage.write(key: _kPairingStorageKey, value: jsonEncode(payload.toJson()));
      } catch (_) {}
    }

    final probe = preProbed ?? await AgyHttpCarrier.probeBestEndpoint(payload.endpoints);
    final chosenUrl = probe?.endpoint ?? _fallbackEndpointForCurrentNetwork(payload.endpoints);
    final direct = probe?.isDirect ?? isDirectEndpointUrl(chosenUrl);

    _carrier = AgyHttpCarrier(baseUrl: chosenUrl, token: payload.token);
    _mux = AgyMuxClient(
      baseUrl: chosenUrl,
      token: payload.token,
      onReconnectNeeded: _handleMuxReconnectNeeded,
    );

    state = state.copyWith(
      activeEndpoint: chosenUrl,
      isDirect: direct,
      rttMs: probe?.rttMs,
      clearRtt: probe == null,
      desktopOnline: probe?.desktopOnline ?? false,
      transportEpoch: state.transportEpoch + 1,
    );

    _statusSub = _mux!.statusStream.listen((st) {
      final wasConnected = state.status == MuxConnectionStatus.connected;
      if (st != MuxConnectionStatus.connected) {
        state = state.copyWith(status: st, desktopOnline: false, clearRtt: true);
      } else {
        state = state.copyWith(status: st);
        if (!wasConnected) {
          unawaited(refreshAll());
        }
      }
      _syncAlwaysOnNotification();
    });

    _rttSub = _mux!.rttStream.listen((info) {
      final hadRtt = state.rttMs != null;
      state = state.copyWith(rttMs: info.rttMs, desktopOnline: info.desktopOnline);
      if (!hadRtt && state.status == MuxConnectionStatus.connected) {
        _syncAlwaysOnNotification();
      }
    });

    _msgSub = _mux!.messages.listen(_routeMuxMessage);
    _mux!.connect();

    if (probe != null) {
      await refreshAll();
    }
  }

  Future<void> reconnect() async {
    final p = state.pairing;
    if (p != null) {
      await connectWithPairing(p, persist: false);
    }
  }

  String _fallbackEndpointForCurrentNetwork(List<String> endpoints) {
    if (_networkKind == 'cellular') {
      for (final ep in endpoints) {
        if (!isDirectEndpointUrl(ep)) return ep;
      }
    }
    return endpoints.first;
  }

  /// Actively verifies live connectivity (e.g. on network switch, app resume, pairing page open, or failed RPC).
  Future<void> verifyConnection({bool forceReprobe = false}) {
    final existing = _verifyFuture;
    if (existing != null) return existing;
    final f = _runVerifyConnection(forceReprobe: forceReprobe);
    _verifyFuture = f;
    f.whenComplete(() {
      if (identical(_verifyFuture, f)) {
        _verifyFuture = null;
      }
    });
    return f;
  }

  Future<void> _runVerifyConnection({required bool forceReprobe}) async {
    final p = state.pairing;
    if (p == null || p.endpoints.isEmpty) return;

    final probe = await AgyHttpCarrier.probeBestEndpoint(
      p.endpoints,
      timeout: const Duration(seconds: 8),
    );
    if (probe == null) {
      final alive = !forceReprobe &&
          _mux != null &&
          await _mux!.verifyAlive(timeout: const Duration(milliseconds: 1500));
      if (!alive && state.status == MuxConnectionStatus.connected) {
        state = state.copyWith(
          status: MuxConnectionStatus.reconnecting,
          desktopOnline: false,
          clearRtt: true,
        );
        _syncAlwaysOnNotification();
      }
      return;
    }

    if (probe.endpoint != state.activeEndpoint || _mux == null || _carrier == null) {
      await connectWithPairing(p, persist: false, preProbed: probe);
      return;
    }

    if (state.status == MuxConnectionStatus.connected) {
      final alive = await _mux!.verifyAlive(timeout: const Duration(milliseconds: 2500));
      if (alive) {
        state = state.copyWith(
          rttMs: probe.rttMs,
          desktopOnline: probe.desktopOnline,
          isDirect: probe.isDirect,
        );
        unawaited(refreshAll());
      }
    } else {
      await connectWithPairing(p, persist: false, preProbed: probe);
    }
  }

  Future<void> _handleMuxReconnectNeeded() async {
    if (_reprobingEndpoints) return;
    final p = state.pairing;
    if (p == null || p.endpoints.length <= 1) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastReprobeAtMs < 4000) return;
    _lastReprobeAtMs = now;

    _reprobingEndpoints = true;
    try {
      final probe = await AgyHttpCarrier.probeBestEndpoint(
        p.endpoints,
        timeout: const Duration(seconds: 8),
      );
      if (probe != null && probe.endpoint != state.activeEndpoint) {
        await connectWithPairing(p, persist: false, preProbed: probe);
      }
    } finally {
      _reprobingEndpoints = false;
    }
  }

  Future<void> disconnectAndClear() async {
    _teardownTransport();
    try {
      await _storage.delete(key: _kPairingStorageKey);
    } catch (_) {}
    _lastAlwaysOnBanner = null;
    await NativeBridge.instance.stopAlwaysOnService();
    state = const HostConnectionState();
  }

  Future<void> setAlwaysOn(bool enabled) async {
    state = state.copyWith(alwaysOnEnabled: enabled);
    if (enabled && state.isPaired) {
      _syncAlwaysOnNotification(force: true);
    } else if (!enabled) {
      _lastAlwaysOnBanner = null;
      await NativeBridge.instance.stopAlwaysOnService();
    }
  }

  void _syncAlwaysOnNotification({bool force = false}) {
    if (!state.alwaysOnEnabled || !state.isPaired) return;
    final banner = state.connectionBanner;
    if (!force && banner == _lastAlwaysOnBanner) return;
    _lastAlwaysOnBanner = banner;
    unawaited(
      NativeBridge.instance.startAlwaysOnService(
        hostName: state.hostName,
        statusText: banner,
      ),
    );
  }

  Future<void> refreshAll() async {
    final c = _carrier;
    if (c == null) return;
    try {
      final results = await Future.wait([
        c.getQuota(),
        c.listSessions(mode: ref.read(sessionsStateProvider).mode),
        c.getHostInfo(),
        c.listAlerts(),
      ]);
      final quota = results[0] as QuotaSnapshot;
      final hostInfo = results[2] as HostInfo;
      final liveModels = hostInfo.models.isNotEmpty ? hostInfo.models : quota.models;
      ref.read(quotaStateProvider.notifier).applySnapshot(quota);
      ref.read(sessionsStateProvider.notifier).applyListResult(results[1] as SessionListResult);
      state = state.copyWith(
        workspaces: hostInfo.workspaces,
        models: liveModels,
        desktopOnline: hostInfo.desktopOnline,
        clearError: true,
      );
      ref.read(alertsStateProvider.notifier).setAlerts(results[3] as List<AgentAlert>);
    } catch (e) {
      state = state.copyWith(desktopOnline: false, errorMessage: e.toString());
      unawaited(verifyConnection());
    }
  }

  void _routeMuxMessage(MuxEventMessage msg) {
    if (msg.channel == '\$global') {
      if (msg.type == 'snapshot' && msg.data is Map<String, dynamic>) {
        final d = msg.data as Map<String, dynamic>;
        state = state.copyWith(desktopOnline: (d['desktopOnline'] as bool?) ?? state.desktopOnline);
        if (d['quota'] is Map<String, dynamic>) {
          final snap = QuotaSnapshot.fromJson(d['quota'] as Map<String, dynamic>);
          ref.read(quotaStateProvider.notifier).applySnapshot(snap);
          if (snap.models.isNotEmpty) {
            state = state.copyWith(models: snap.models);
          }
        }
        if (d['sessions'] is Map<String, dynamic>) {
          ref.read(sessionsStateProvider.notifier).applyListResult(
                SessionListResult.fromJson(d['sessions'] as Map<String, dynamic>),
              );
        }
      } else if (msg.type == 'event') {
        if (msg.event == 'quota.updated' && msg.data is Map<String, dynamic>) {
          final snap = QuotaSnapshot.fromJson(msg.data as Map<String, dynamic>);
          ref.read(quotaStateProvider.notifier).applySnapshot(snap);
          if (snap.models.isNotEmpty) {
            state = state.copyWith(models: snap.models);
          }
        } else if (msg.event == 'session.summary' && msg.data is Map<String, dynamic>) {
          ref.read(sessionsStateProvider.notifier).upsertCard(
                SessionCard.fromJson(msg.data as Map<String, dynamic>),
              );
        }
      } else if (msg.type == 'alert' && msg.alert != null) {
        final al = msg.alert!;
        ref.read(alertsStateProvider.notifier).pushAlert(al);
        if (_activeConversationId != al.conversationId) {
          NativeBridge.instance.showAgentAlert(al);
        }
      }
    }
  }

  Future<void> _handleNotificationReply(String convId, String replyText) async {
    final c = _carrier;
    if (c == null) return;
    await c.sendMessage(convId, replyText);
  }

  void _teardownTransport() {
    _statusSub?.cancel();
    _rttSub?.cancel();
    _msgSub?.cancel();
    _mux?.dispose();
    _carrier?.close();
    _mux = null;
    _carrier = null;
  }
}

final hostConnectionProvider = NotifierProvider<HostConnectionNotifier, HostConnectionState>(
  HostConnectionNotifier.new,
);

// --- Quota State ---

class QuotaUiState {
  const QuotaUiState({
    this.snapshot,
    this.collapsed = false,
    this.calibrating = false,
  });

  final QuotaSnapshot? snapshot;
  final bool collapsed;
  final bool calibrating;

  QuotaUiState copyWith({
    QuotaSnapshot? snapshot,
    bool? collapsed,
    bool? calibrating,
  }) {
    return QuotaUiState(
      snapshot: snapshot ?? this.snapshot,
      collapsed: collapsed ?? this.collapsed,
      calibrating: calibrating ?? this.calibrating,
    );
  }
}

class QuotaStateNotifier extends Notifier<QuotaUiState> {
  final FlutterSecureStorage _storage = _kSecureStorage;

  @override
  QuotaUiState build() {
    Future.microtask(_loadCollapsed);
    return const QuotaUiState();
  }

  Future<void> _loadCollapsed() async {
    try {
      final v = await _storage.read(key: _kQuotaCollapsedKey);
      if (v == '1') {
        state = state.copyWith(collapsed: true);
      }
    } catch (_) {}
  }

  void applySnapshot(QuotaSnapshot snap) {
    state = state.copyWith(snapshot: snap);
  }

  Future<void> toggleCollapsed() async {
    final next = !state.collapsed;
    state = state.copyWith(collapsed: next);
    try {
      await _storage.write(key: _kQuotaCollapsedKey, value: next ? '1' : '0');
    } catch (_) {}
  }

  Future<void> calibrate({
    required String poolId,
    double? remaining5hPct,
    double? remaining7dPct,
    String? subscriptionTier,
  }) async {
    final c = ref.read(hostConnectionProvider.notifier).carrier;
    if (c == null) return;
    state = state.copyWith(calibrating: true);
    try {
      final snap = await c.calibrateQuota(
        poolId: poolId,
        remaining5hPct: remaining5hPct,
        remaining7dPct: remaining7dPct,
        subscriptionTier: subscriptionTier,
      );
      state = state.copyWith(snapshot: snap, calibrating: false);
    } catch (_) {
      state = state.copyWith(calibrating: false);
      rethrow;
    }
  }
}

final quotaStateProvider = NotifierProvider<QuotaStateNotifier, QuotaUiState>(
  QuotaStateNotifier.new,
);

// --- Sessions List State ---

class SessionsUiState {
  const SessionsUiState({
    this.mode = 'desktop',
    this.pinned = const [],
    this.regular = const [],
    this.groups = const [],
    this.expandedProjectKeys = const {},
    this.loading = false,
  });

  final String mode; // "desktop" | "project"
  final List<SessionCard> pinned;
  final List<SessionCard> regular;
  final List<ProjectGroup> groups;
  final Set<String> expandedProjectKeys;
  final bool loading;

  static String projectKey(WorkspaceInfo workspace) =>
      '${workspace.kind}:${workspace.rootPath ?? workspace.label}';

  bool isProjectExpanded(ProjectGroup group) =>
      expandedProjectKeys.contains(projectKey(group.workspace));

  SessionsUiState copyWith({
    String? mode,
    List<SessionCard>? pinned,
    List<SessionCard>? regular,
    List<ProjectGroup>? groups,
    Set<String>? expandedProjectKeys,
    bool? loading,
  }) {
    return SessionsUiState(
      mode: mode ?? this.mode,
      pinned: pinned ?? this.pinned,
      regular: regular ?? this.regular,
      groups: groups ?? this.groups,
      expandedProjectKeys: expandedProjectKeys ?? this.expandedProjectKeys,
      loading: loading ?? this.loading,
    );
  }
}

class SessionsStateNotifier extends Notifier<SessionsUiState> {
  @override
  SessionsUiState build() => const SessionsUiState();

  void applyListResult(SessionListResult res) {
    state = state.copyWith(
      pinned: res.pinned,
      regular: res.regular,
      groups: res.groups,
      loading: false,
    );
  }

  Future<void> setMode(String mode) async {
    if (mode == state.mode) return;
    state = state.copyWith(mode: mode, loading: true);
    final c = ref.read(hostConnectionProvider.notifier).carrier;
    if (c == null) {
      state = state.copyWith(loading: false);
      return;
    }
    final res = await c.listSessions(mode: mode);
    applyListResult(res);
  }

  void toggleProjectExpanded(ProjectGroup group) {
    final key = SessionsUiState.projectKey(group.workspace);
    final next = Set<String>.from(state.expandedProjectKeys);
    if (!next.add(key)) {
      next.remove(key);
    }
    state = state.copyWith(expandedProjectKeys: next);
  }

  Future<void> togglePin(SessionCard card) async {
    final c = ref.read(hostConnectionProvider.notifier).carrier;
    if (c == null) return;
    await c.pinSession(card.conversationId, !card.pinned);
    final res = await c.listSessions(mode: state.mode);
    applyListResult(res);
  }

  void upsertCard(SessionCard updated) {
    final pinned = state.pinned.where((e) => e.conversationId != updated.conversationId).toList();
    final regular = state.regular.where((e) => e.conversationId != updated.conversationId).toList();
    if (updated.pinned) {
      pinned.add(updated);
      pinned.sort((a, b) => a.pinnedOrder != b.pinnedOrder
          ? a.pinnedOrder.compareTo(b.pinnedOrder)
          : b.lastModifiedUnix.compareTo(a.lastModifiedUnix));
    } else {
      regular.add(updated);
      regular.sort((a, b) => b.lastModifiedUnix.compareTo(a.lastModifiedUnix));
    }
    state = state.copyWith(pinned: pinned, regular: regular);
  }
}

final sessionsStateProvider = NotifierProvider<SessionsStateNotifier, SessionsUiState>(
  SessionsStateNotifier.new,
);

// --- Alerts State ---

class AlertsUiState {
  const AlertsUiState({this.alerts = const [], this.unreadCount = 0});

  final List<AgentAlert> alerts;
  final int unreadCount;

  AlertsUiState copyWith({List<AgentAlert>? alerts, int? unreadCount}) {
    return AlertsUiState(
      alerts: alerts ?? this.alerts,
      unreadCount: unreadCount ?? this.unreadCount,
    );
  }
}

class AlertsStateNotifier extends Notifier<AlertsUiState> {
  @override
  AlertsUiState build() => const AlertsUiState();

  void setAlerts(List<AgentAlert> list) {
    state = state.copyWith(alerts: list);
  }

  void pushAlert(AgentAlert alert) {
    final dedup = state.alerts.where((a) => a.alertId != alert.alertId).toList();
    state = AlertsUiState(
      alerts: [alert, ...dedup].take(50).toList(),
      unreadCount: state.unreadCount + 1,
    );
  }

  void clearUnread() {
    state = state.copyWith(unreadCount: 0);
  }
}

final alertsStateProvider = NotifierProvider<AlertsStateNotifier, AlertsUiState>(
  AlertsStateNotifier.new,
);

// --- Chat Session Family State ---

class ChatSessionState {
  const ChatSessionState({
    this.session,
    this.steps = const [],
    this.rows = const [],
    this.artifacts = const [],
    this.hasMore = false,
    this.loading = true,
    this.sending = false,
    this.error,
  });

  final SessionCard? session;
  final List<TranscriptStep> steps;
  final List<ChatRow> rows;
  final List<ArtifactItem> artifacts;
  final bool hasMore;
  final bool loading;
  final bool sending;
  final String? error;

  ChatSessionState copyWith({
    SessionCard? session,
    List<TranscriptStep>? steps,
    List<ChatRow>? rows,
    List<ArtifactItem>? artifacts,
    bool? hasMore,
    bool? loading,
    bool? sending,
    String? error,
    bool clearError = false,
  }) {
    return ChatSessionState(
      session: session ?? this.session,
      steps: steps ?? this.steps,
      rows: rows ?? this.rows,
      artifacts: artifacts ?? this.artifacts,
      hasMore: hasMore ?? this.hasMore,
      loading: loading ?? this.loading,
      sending: sending ?? this.sending,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

// In-memory LRU cache of recently viewed sessions so revisiting a conversation paints in 0ms
// while the live WS snapshot refreshes in the background.
final Map<String, ChatSessionState> _recentChatCache = <String, ChatSessionState>{};
const int _kMaxRecentChatCache = 12;

void _saveChatCache(String conversationId, ChatSessionState snapshot) {
  if (snapshot.steps.isEmpty) return;
  _recentChatCache.remove(conversationId);
  _recentChatCache[conversationId] = snapshot.copyWith(loading: false, sending: false, clearError: true);
  while (_recentChatCache.length > _kMaxRecentChatCache) {
    _recentChatCache.remove(_recentChatCache.keys.first);
  }
}

class ChatSessionNotifier extends AutoDisposeFamilyNotifier<ChatSessionState, String> {
  StreamSubscription? _muxSub;
  AgyMuxClient? _boundMux;
  Timer? _httpFallbackTimer;
  bool _snapshotReceived = false;
  bool _disposed = false;

  @override
  ChatSessionState build(String conversationId) {
    _disposed = false;
    _snapshotReceived = false;
    final hostNotifier = ref.read(hostConnectionProvider.notifier);
    final hostState = ref.read(hostConnectionProvider);
    hostNotifier.setActiveConversation(conversationId);

    _bindMux(hostNotifier.mux, conversationId);

    ref.listen<HostConnectionState>(hostConnectionProvider, (prev, next) {
      if (_disposed) return;
      if (prev?.transportEpoch != next.transportEpoch) {
        _snapshotReceived = false;
        _bindMux(ref.read(hostConnectionProvider.notifier).mux, conversationId);
        _scheduleInitialFetch(conversationId, muxConnected: next.status == MuxConnectionStatus.connected);
      } else if (prev?.status != MuxConnectionStatus.connected &&
          next.status == MuxConnectionStatus.connected &&
          (state.loading || state.error != null || state.steps.isEmpty)) {
        _scheduleInitialFetch(conversationId, muxConnected: true);
      }
    });

    ref.onDispose(() {
      _disposed = true;
      _httpFallbackTimer?.cancel();
      _httpFallbackTimer = null;
      _unbindMux(conversationId);
      hostNotifier.setActiveConversation(null);
    });

    final cachedView = _recentChatCache[conversationId];
    final cachedCard = _findCachedCard(conversationId);
    _scheduleInitialFetch(
      conversationId,
      muxConnected: hostState.status == MuxConnectionStatus.connected && hostNotifier.mux != null,
    );
    if (cachedView != null) {
      return cachedView.copyWith(session: cachedCard ?? cachedView.session, loading: false, clearError: true);
    }
    return ChatSessionState(session: cachedCard);
  }

  void _scheduleInitialFetch(String conversationId, {required bool muxConnected}) {
    _httpFallbackTimer?.cancel();
    _httpFallbackTimer = null;
    if (muxConnected && _boundMux != null) {
      // Reuse the already-handshaked WS connection (avoids a 3s cold TLS handshake on 5G);
      // fall back to HTTP RPC only if WS snapshot does not arrive promptly.
      _httpFallbackTimer = Timer(const Duration(milliseconds: 2200), () {
        if (_disposed || _snapshotReceived) return;
        unawaited(loadInitial(conversationId));
      });
      return;
    }
    Future.microtask(() => loadInitial(conversationId));
  }

  SessionCard? _findCachedCard(String conversationId) {
    final list = ref.read(sessionsStateProvider);
    for (final c in list.pinned) {
      if (c.conversationId == conversationId) return c;
    }
    for (final c in list.regular) {
      if (c.conversationId == conversationId) return c;
    }
    for (final g in list.groups) {
      for (final c in g.sessions) {
        if (c.conversationId == conversationId) return c;
      }
    }
    return null;
  }

  void _bindMux(AgyMuxClient? mux, String conversationId) {
    if (identical(_boundMux, mux)) return;
    _unbindMux(conversationId);
    _boundMux = mux;
    if (mux == null) return;
    // Listen BEFORE subscribing so an immediate snapshot frame is never missed.
    _muxSub = mux.messages.listen((msg) {
      if (_disposed || msg.channel != 'session:$conversationId') return;
      _onChannelMessage(msg);
    });
    mux.subscribe('session:$conversationId');
  }

  void _unbindMux(String conversationId) {
    _muxSub?.cancel();
    _muxSub = null;
    _boundMux?.unsubscribe('session:$conversationId');
    _boundMux = null;
  }

  Future<void> reload() async {
    if (_disposed) return;
    state = state.copyWith(loading: true, clearError: true);
    await loadInitial(arg);
  }

  Future<void> loadInitial(String conversationId) async {
    if (_disposed) return;
    final c = ref.read(hostConnectionProvider.notifier).carrier;
    if (c == null) {
      state = state.copyWith(loading: false, error: '尚未连接主机');
      return;
    }
    try {
      final res = await c.getSession(conversationId);
      if (_disposed) return;
      final rows = TranscriptReducer.reduce(res.steps);
      final nextState = state.copyWith(
        session: res.session,
        steps: res.steps,
        rows: rows,
        artifacts: res.artifacts,
        hasMore: res.hasMore,
        loading: false,
        clearError: true,
      );
      _snapshotReceived = true;
      _httpFallbackTimer?.cancel();
      state = nextState;
      _saveChatCache(conversationId, nextState);
      if (res.steps.isNotEmpty) {
        unawaited(c.markRead(conversationId, res.steps.last.stepIndex));
      }
    } catch (e) {
      if (_disposed) return;
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  Future<void> sendMessage(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || state.sending || _disposed) return;
    final c = ref.read(hostConnectionProvider.notifier).carrier;
    if (c == null) return;

    state = state.copyWith(sending: true, clearError: true);
    final reqId = c.nextRequestId();
    try {
      await c.sendMessage(arg, trimmed, requestId: reqId);
      if (_disposed) return;
      state = state.copyWith(sending: false);
    } on BridgeRemoteException catch (e) {
      if (_disposed) return;
      state = state.copyWith(sending: false, error: e.message);
    } catch (e) {
      if (_disposed) return;
      state = state.copyWith(sending: false, error: '发送失败：$e');
    }
  }

  void _onChannelMessage(MuxEventMessage msg) {
    if (_disposed) return;
    try {
      if (msg.type == 'snapshot' && msg.data is Map<String, dynamic>) {
        final d = msg.data as Map<String, dynamic>;
        final steps = ((d['steps'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(TranscriptStep.fromJson)
            .toList();
        final artifacts = ((d['artifacts'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ArtifactItem.fromJson)
            .toList();
        final session = d['session'] is Map<String, dynamic>
            ? SessionCard.fromJson(d['session'] as Map<String, dynamic>)
            : state.session;
        final nextState = state.copyWith(
          session: session,
          steps: steps,
          rows: TranscriptReducer.reduce(steps),
          artifacts: artifacts,
          hasMore: (d['hasMore'] as bool?) ?? state.hasMore,
          loading: false,
          clearError: true,
        );
        _snapshotReceived = true;
        _httpFallbackTimer?.cancel();
        state = nextState;
        _saveChatCache(arg, nextState);
        final c = ref.read(hostConnectionProvider.notifier).carrier;
        if (c != null && steps.isNotEmpty) {
          unawaited(c.markRead(arg, steps.last.stepIndex));
        }
      } else if (msg.type == 'event' && msg.event == 'step.upsert' && msg.data is Map<String, dynamic>) {
        final d = msg.data as Map<String, dynamic>;
        final incoming = ((d['steps'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(TranscriptStep.fromJson)
            .toList();
        if (incoming.isEmpty) return;

        final merged = Map<int, TranscriptStep>.fromEntries(state.steps.map((s) => MapEntry(s.stepIndex, s)));
        for (final s in incoming) {
          merged[s.stepIndex] = s;
        }
        final sorted = merged.values.toList()..sort((a, b) => a.stepIndex.compareTo(b.stepIndex));
        final nextState = state.copyWith(
          steps: sorted,
          rows: TranscriptReducer.reduce(sorted),
        );
        state = nextState;
        _saveChatCache(arg, nextState);
        final c = ref.read(hostConnectionProvider.notifier).carrier;
        if (c != null && sorted.isNotEmpty) {
          unawaited(c.markRead(arg, sorted.last.stepIndex));
        }
      } else if (msg.type == 'event' && msg.event == 'artifact.changed' && msg.data is Map<String, dynamic>) {
        final d = msg.data as Map<String, dynamic>;
        final artifacts = ((d['artifacts'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ArtifactItem.fromJson)
            .toList();
        state = state.copyWith(artifacts: artifacts);
      }
    } catch (_) {
      // Ignore malformed incremental frame; HTTP loadInitial / reload provides explicit error feedback.
    }
  }
}

final chatSessionProvider = AutoDisposeNotifierProviderFamily<ChatSessionNotifier, ChatSessionState, String>(
  ChatSessionNotifier.new,
);
