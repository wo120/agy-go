import 'dart:async';
import 'dart:convert';

import 'package:agy_client/agy_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'native_bridge.dart';

const _kPairingStorageKey = 'agy_mobile_pairing_v1';
const _kQuotaCollapsedKey = 'agy_mobile_quota_collapsed';

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

  bool get isPaired => pairing != null && pairing!.token.isNotEmpty;
  String get hostName => pairing?.hostName ?? '未连接主机';

  String get connectionBanner {
    if (!isPaired) return '点击扫码配对 Mac 主机';
    switch (status) {
      case MuxConnectionStatus.connected:
        final mode = isDirect ? '已直连' : '已中继';
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
    bool? desktopOnline,
    MuxConnectionStatus? status,
    String? errorMessage,
    bool clearError = false,
    bool? alwaysOnEnabled,
    List<WorkspaceInfo>? workspaces,
  }) {
    return HostConnectionState(
      pairing: clearPairing ? null : (pairing ?? this.pairing),
      activeEndpoint: clearPairing ? null : (activeEndpoint ?? this.activeEndpoint),
      isDirect: isDirect ?? this.isDirect,
      rttMs: rttMs ?? this.rttMs,
      desktopOnline: desktopOnline ?? this.desktopOnline,
      status: status ?? this.status,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      alwaysOnEnabled: alwaysOnEnabled ?? this.alwaysOnEnabled,
      workspaces: workspaces ?? this.workspaces,
    );
  }
}

class HostConnectionNotifier extends Notifier<HostConnectionState> {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  AgyHttpCarrier? _carrier;
  AgyMuxClient? _mux;
  StreamSubscription? _statusSub;
  StreamSubscription? _rttSub;
  StreamSubscription? _msgSub;
  String? _activeConversationId;

  AgyHttpCarrier? get carrier => _carrier;
  AgyMuxClient? get mux => _mux;

  @override
  HostConnectionState build() {
    ref.onDispose(_teardownTransport);
    NativeBridge.instance.init();
    NativeBridge.instance.onNotificationReply = _handleNotificationReply;
    Future.microtask(_loadSavedPairing);
    return const HostConnectionState();
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

  Future<void> connectWithPairing(PairingPayload payload, {bool persist = true}) async {
    _teardownTransport();
    state = state.copyWith(
      pairing: payload,
      status: MuxConnectionStatus.connecting,
      clearError: true,
    );

    if (persist) {
      await _storage.write(key: _kPairingStorageKey, value: jsonEncode(payload.toJson()));
    }

    final probe = await AgyHttpCarrier.probeBestEndpoint(payload.endpoints);
    final chosenUrl = probe?.endpoint ?? payload.endpoints.first;
    final direct = probe?.isDirect ?? isDirectEndpointUrl(chosenUrl);

    _carrier = AgyHttpCarrier(baseUrl: chosenUrl, token: payload.token);
    _mux = AgyMuxClient(baseUrl: chosenUrl, token: payload.token);

    state = state.copyWith(
      activeEndpoint: chosenUrl,
      isDirect: direct,
      rttMs: probe?.rttMs,
      desktopOnline: probe?.desktopOnline ?? false,
    );

    _statusSub = _mux!.statusStream.listen((st) {
      state = state.copyWith(status: st);
      if (st == MuxConnectionStatus.connected && state.alwaysOnEnabled) {
        NativeBridge.instance.startAlwaysOnService(
          hostName: state.hostName,
          statusText: state.connectionBanner,
        );
      }
    });

    _rttSub = _mux!.rttStream.listen((info) {
      state = state.copyWith(rttMs: info.rttMs, desktopOnline: info.desktopOnline);
    });

    _msgSub = _mux!.messages.listen(_routeMuxMessage);
    _mux!.connect();

    // Hydrate initial state via RPC as well for fast first paint.
    await refreshAll();
  }

  Future<void> reconnect() async {
    final p = state.pairing;
    if (p != null) {
      await connectWithPairing(p, persist: false);
    }
  }

  Future<void> disconnectAndClear() async {
    _teardownTransport();
    await _storage.delete(key: _kPairingStorageKey);
    await NativeBridge.instance.stopAlwaysOnService();
    state = const HostConnectionState();
  }

  Future<void> setAlwaysOn(bool enabled) async {
    state = state.copyWith(alwaysOnEnabled: enabled);
    if (enabled && state.status == MuxConnectionStatus.connected) {
      await NativeBridge.instance.startAlwaysOnService(
        hostName: state.hostName,
        statusText: state.connectionBanner,
      );
    } else if (!enabled) {
      await NativeBridge.instance.stopAlwaysOnService();
    }
  }

  Future<void> refreshAll() async {
    final c = _carrier;
    if (c == null) return;
    try {
      final results = await Future.wait([
        c.getQuota(),
        c.listSessions(mode: ref.read(sessionsStateProvider).mode),
        c.listWorkspaces(),
        c.listAlerts(),
      ]);
      ref.read(quotaStateProvider.notifier).applySnapshot(results[0] as QuotaSnapshot);
      ref.read(sessionsStateProvider.notifier).applyListResult(results[1] as SessionListResult);
      state = state.copyWith(workspaces: results[2] as List<WorkspaceInfo>, clearError: true);
      ref.read(alertsStateProvider.notifier).setAlerts(results[3] as List<AgentAlert>);
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    }
  }

  void _routeMuxMessage(MuxEventMessage msg) {
    if (msg.channel == '\$global') {
      if (msg.type == 'snapshot' && msg.data is Map<String, dynamic>) {
        final d = msg.data as Map<String, dynamic>;
        state = state.copyWith(desktopOnline: (d['desktopOnline'] as bool?) ?? state.desktopOnline);
        if (d['quota'] is Map<String, dynamic>) {
          ref.read(quotaStateProvider.notifier).applySnapshot(
                QuotaSnapshot.fromJson(d['quota'] as Map<String, dynamic>),
              );
        }
        if (d['sessions'] is Map<String, dynamic>) {
          ref.read(sessionsStateProvider.notifier).applyListResult(
                SessionListResult.fromJson(d['sessions'] as Map<String, dynamic>),
              );
        }
      } else if (msg.type == 'event') {
        if (msg.event == 'quota.updated' && msg.data is Map<String, dynamic>) {
          ref.read(quotaStateProvider.notifier).applySnapshot(
                QuotaSnapshot.fromJson(msg.data as Map<String, dynamic>),
              );
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
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  @override
  QuotaUiState build() {
    Future.microtask(_loadCollapsed);
    return const QuotaUiState();
  }

  Future<void> _loadCollapsed() async {
    final v = await _storage.read(key: _kQuotaCollapsedKey);
    if (v == '1') {
      state = state.copyWith(collapsed: true);
    }
  }

  void applySnapshot(QuotaSnapshot snap) {
    state = state.copyWith(snapshot: snap);
  }

  Future<void> toggleCollapsed() async {
    final next = !state.collapsed;
    state = state.copyWith(collapsed: next);
    await _storage.write(key: _kQuotaCollapsedKey, value: next ? '1' : '0');
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

class ChatSessionNotifier extends AutoDisposeFamilyNotifier<ChatSessionState, String> {
  StreamSubscription? _muxSub;

  @override
  ChatSessionState build(String conversationId) {
    final hostNotifier = ref.read(hostConnectionProvider.notifier);
    hostNotifier.setActiveConversation(conversationId);

    final mux = hostNotifier.mux;
    if (mux != null) {
      mux.subscribe('session:$conversationId');
      _muxSub = mux.messages.listen((msg) {
        if (msg.channel != 'session:$conversationId') return;
        _onChannelMessage(msg);
      });
    }

    ref.onDispose(() {
      _muxSub?.cancel();
      hostNotifier.mux?.unsubscribe('session:$conversationId');
      hostNotifier.setActiveConversation(null);
    });

    Future.microtask(() => loadInitial(conversationId));
    return const ChatSessionState();
  }

  Future<void> loadInitial(String conversationId) async {
    final c = ref.read(hostConnectionProvider.notifier).carrier;
    if (c == null) {
      state = state.copyWith(loading: false, error: '尚未连接主机');
      return;
    }
    try {
      final res = await c.getSession(conversationId);
      final rows = TranscriptReducer.reduce(res.steps);
      state = state.copyWith(
        session: res.session,
        steps: res.steps,
        rows: rows,
        artifacts: res.artifacts,
        hasMore: res.hasMore,
        loading: false,
        clearError: true,
      );
      if (res.steps.isNotEmpty) {
        unawaited(c.markRead(conversationId, res.steps.last.stepIndex));
      }
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  Future<void> sendMessage(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || state.sending) return;
    final c = ref.read(hostConnectionProvider.notifier).carrier;
    if (c == null) return;

    state = state.copyWith(sending: true, clearError: true);
    final reqId = c.nextRequestId();
    try {
      await c.sendMessage(arg, trimmed, requestId: reqId);
      state = state.copyWith(sending: false);
    } on BridgeRemoteException catch (e) {
      state = state.copyWith(sending: false, error: e.message);
    } catch (e) {
      state = state.copyWith(sending: false, error: '发送失败：$e');
    }
  }

  void _onChannelMessage(MuxEventMessage msg) {
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
      state = state.copyWith(
        session: session,
        steps: steps,
        rows: TranscriptReducer.reduce(steps),
        artifacts: artifacts,
        loading: false,
      );
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
      state = state.copyWith(
        steps: sorted,
        rows: TranscriptReducer.reduce(sorted),
      );
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
  }
}

final chatSessionProvider = AutoDisposeNotifierProviderFamily<ChatSessionNotifier, ChatSessionState, String>(
  ChatSessionNotifier.new,
);
