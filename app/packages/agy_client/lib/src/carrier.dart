import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'models.dart';

/// Tracks monotonically increasing sequence numbers per generation to detect drops.
class MuxSeqTracker {
  String? _generation;
  int _lastSeq = 0;

  bool acceptSnapshot(String generation, int seq) {
    _generation = generation;
    _lastSeq = seq;
    return true;
  }

  /// Returns true when the event is strictly contiguous; false means resync snapshot is needed.
  bool acceptEvent(String generation, int seq) {
    if (_generation == null || _generation != generation) {
      return false;
    }
    if (seq != _lastSeq + 1) {
      return false;
    }
    _lastSeq = seq;
    return true;
  }

  void reset() {
    _generation = null;
    _lastSeq = 0;
  }
}

/// Checks whether a URL host belongs to private LAN or Tailscale CGNAT (100.64.0.0/10).
bool isDirectEndpointUrl(String rawUrl) {
  final uri = Uri.tryParse(rawUrl);
  if (uri == null) return false;
  final host = uri.host;
  if (host == 'localhost' || host == '127.0.0.1') return true;
  final parts = host.split('.');
  if (parts.length != 4) return false;
  final octets = parts.map(int.tryParse).toList();
  if (octets.any((e) => e == null || e < 0 || e > 255)) return false;
  final a = octets[0]!;
  final b = octets[1]!;
  if (a == 10) return true;
  if (a == 192 && b == 168) return true;
  if (a == 172 && b >= 16 && b <= 31) return true;
  if (a == 100 && b >= 64 && b <= 127) return true; // Tailscale / CGNAT
  return false;
}

HttpClient _createRawHttpClient({
  required bool directBypassProxy,
  Duration connectionTimeout = const Duration(seconds: 6),
  Duration idleTimeout = const Duration(seconds: 10),
}) {
  final client = HttpClient()
    ..connectionTimeout = connectionTimeout
    ..idleTimeout = idleTimeout;
  if (directBypassProxy) {
    client.findProxy = (_) => 'DIRECT';
  }
  return client;
}

class AgyHttpCarrier {
  AgyHttpCarrier({
    required this.baseUrl,
    required this.token,
    http.Client? httpClient,
  }) : _http = httpClient ??
            IOClient(
              _createRawHttpClient(directBypassProxy: isDirectEndpointUrl(baseUrl)),
            );

  final String baseUrl;
  final String token;
  final http.Client _http;
  final Random _rng = Random();

  String get _cleanBase => baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;

  Map<String, String> get authHeaders => {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      };

  /// Concurrently probes candidate LAN / Tailscale / public endpoints and returns the fastest reachable one.
  static Future<EndpointProbeResult?> probeBestEndpoint(
    List<String> endpoints, {
    Duration timeout = const Duration(milliseconds: 1800),
    http.Client? httpClient,
  }) async {
    if (endpoints.isEmpty) return null;
    final client = httpClient ??
        IOClient(
          HttpClient()
            ..connectionTimeout = timeout
            ..idleTimeout = const Duration(seconds: 5)
            ..findProxy = (uri) =>
                isDirectEndpointUrl(uri.toString()) ? 'DIRECT' : HttpClient.findProxyFromEnvironment(uri),
        );
    final ownsClient = httpClient == null;
    final completer = Completer<EndpointProbeResult?>();
    var remaining = endpoints.length;

    for (final ep in endpoints) {
      final clean = ep.endsWith('/') ? ep.substring(0, ep.length - 1) : ep;
      final sw = Stopwatch()..start();
      client
          .get(Uri.parse('$clean/api/v1/health'))
          .timeout(timeout)
          .then((resp) {
            sw.stop();
            if (resp.statusCode == 200) {
              final data = jsonDecode(resp.body) as Map<String, dynamic>;
              if (data['ok'] == true && !completer.isCompleted) {
                completer.complete(
                  EndpointProbeResult(
                    endpoint: clean,
                    rttMs: sw.elapsedMilliseconds,
                    isDirect: isDirectEndpointUrl(clean),
                    hostName: (data['hostName'] as String?) ?? 'AntigravityHost',
                    desktopOnline: (data['desktopOnline'] as bool?) ?? false,
                  ),
                );
              }
            }
          })
          .catchError((_) {})
          .whenComplete(() {
            remaining--;
            if (remaining <= 0 && !completer.isCompleted) {
              completer.complete(null);
            }
          });
    }

    final result = await completer.future;
    if (ownsClient) {
      client.close();
    }
    return result;
  }

  String nextRequestId() {
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final salt = _rng.nextInt(1 << 20).toRadixString(36);
    return 'req_${ts}_$salt';
  }

  Future<dynamic> callRpc(
    String method, [
    Map<String, dynamic> params = const {},
    String? requestId,
    Duration timeout = const Duration(seconds: 12),
  ]) async {
    final reqId = requestId ?? nextRequestId();
    http.Response resp;
    try {
      resp = await _http
          .post(
            Uri.parse('$_cleanBase/api/v1/rpc'),
            headers: authHeaders,
            body: jsonEncode({
              'requestId': reqId,
              'method': method,
              'params': params,
            }),
          )
          .timeout(timeout);
    } catch (e) {
      throw CarrierException('Network request failed for $method', e);
    }

    if (resp.statusCode == 401) {
      throw const BridgeRemoteException('UNAUTHORIZED', '设备令牌无效或已过期，请重新扫码配对');
    }
    if (resp.statusCode != 200) {
      throw CarrierException('Unexpected HTTP ${resp.statusCode} for $method');
    }

    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    if (decoded['ok'] != true) {
      final err = (decoded['error'] as Map<String, dynamic>?) ?? const {};
      throw BridgeRemoteException(
        (err['code'] as String?) ?? 'UNKNOWN_ERROR',
        (err['message'] as String?) ?? '请求失败',
      );
    }
    return decoded['data'];
  }

  Future<QuotaSnapshot> getQuota() async {
    final data = await callRpc('quota.get') as Map<String, dynamic>;
    return QuotaSnapshot.fromJson(data);
  }

  Future<QuotaSnapshot> calibrateQuota({
    required String poolId,
    double? remaining5hPct,
    double? remaining7dPct,
    String? subscriptionTier,
  }) async {
    final params = <String, dynamic>{'poolId': poolId};
    if (remaining5hPct != null) params['remaining5hPct'] = remaining5hPct;
    if (remaining7dPct != null) params['remaining7dPct'] = remaining7dPct;
    if (subscriptionTier != null) params['subscriptionTier'] = subscriptionTier;
    final data = await callRpc('quota.calibrate', params) as Map<String, dynamic>;
    return QuotaSnapshot.fromJson(data);
  }

  Future<SessionListResult> listSessions({String mode = 'desktop', int limit = 100}) async {
    final data = await callRpc('sessions.list', {'mode': mode, 'limit': limit}) as Map<String, dynamic>;
    return SessionListResult.fromJson(data);
  }

  Future<List<SearchHit>> searchSessions(String query, {int limit = 20}) async {
    final data = await callRpc('sessions.search', {'query': query, 'limit': limit}) as Map<String, dynamic>;
    return ((data['hits'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(SearchHit.fromJson)
        .toList();
  }

  Future<({SessionCard session, List<TranscriptStep> steps, bool hasMore, List<ArtifactItem> artifacts})>
      getSession(String conversationId, {int beforeStep = 0, int limit = 80}) async {
    final data = await callRpc('sessions.get', {
      'conversationId': conversationId,
      'beforeStep': beforeStep,
      'limit': limit,
    }) as Map<String, dynamic>;
    return (
      session: SessionCard.fromJson(data['session'] as Map<String, dynamic>),
      steps: ((data['steps'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(TranscriptStep.fromJson)
          .toList(),
      hasMore: (data['hasMore'] as bool?) ?? false,
      artifacts: ((data['artifacts'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ArtifactItem.fromJson)
          .toList(),
    );
  }

  Future<String?> createSession({
    required String prompt,
    String? title,
    String? model,
    String? workspacePath,
    String? requestId,
  }) async {
    final params = <String, dynamic>{'prompt': prompt};
    if (title != null && title.isNotEmpty) params['title'] = title;
    if (model != null && model.isNotEmpty) params['model'] = model;
    if (workspacePath != null && workspacePath.isNotEmpty) params['workspacePath'] = workspacePath;
    final data = await callRpc(
      'sessions.create',
      params,
      requestId,
      const Duration(seconds: 28),
    ) as Map<String, dynamic>?;
    return data?['conversationId'] as String?;
  }

  Future<void> sendMessage(String conversationId, String content, {String? requestId}) async {
    await callRpc(
      'sessions.sendMessage',
      {'conversationId': conversationId, 'content': content},
      requestId,
      const Duration(seconds: 28),
    );
  }

  Future<void> pinSession(String conversationId, bool pinned, {int order = 0}) async {
    await callRpc('sessions.pin', {'conversationId': conversationId, 'pinned': pinned, 'order': order});
  }

  Future<void> markRead(String conversationId, int stepIndex) async {
    await callRpc('sessions.markRead', {'conversationId': conversationId, 'stepIndex': stepIndex});
  }

  Future<List<ArtifactItem>> listArtifacts(String conversationId) async {
    final data = await callRpc('artifacts.list', {'conversationId': conversationId}) as Map<String, dynamic>;
    return ((data['artifacts'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(ArtifactItem.fromJson)
        .toList();
  }

  Future<List<AgentAlert>> listAlerts() async {
    final data = await callRpc('alerts.list') as Map<String, dynamic>;
    return ((data['alerts'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(AgentAlert.fromJson)
        .toList();
  }

  Future<HostInfo> getHostInfo() async {
    final data = await callRpc('host.info') as Map<String, dynamic>;
    return HostInfo.fromJson(data);
  }

  Future<List<WorkspaceInfo>> listWorkspaces() async {
    final info = await getHostInfo();
    return info.workspaces;
  }

  Future<TextContentPage> fetchFileContent(String conversationId, String path, {int offset = 0, int limit = 524288}) async {
    final uri = Uri.parse('$_cleanBase/api/v1/files/content').replace(queryParameters: {
      'convId': conversationId,
      'path': path,
      'offset': '$offset',
      'limit': '$limit',
    });
    http.Response resp;
    try {
      resp = await _http.get(uri, headers: authHeaders).timeout(const Duration(seconds: 20));
    } catch (e) {
      throw CarrierException('Failed to fetch file content', e);
    }
    if (resp.statusCode == 401) {
      throw const BridgeRemoteException('UNAUTHORIZED', '设备令牌无效');
    }
    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    if (decoded['ok'] != true) {
      final err = (decoded['error'] as Map<String, dynamic>?) ?? const {};
      throw BridgeRemoteException(
        (err['code'] as String?) ?? 'FILE_ERROR',
        (err['message'] as String?) ?? '文件读取失败',
      );
    }
    return TextContentPage.fromJson(decoded['data'] as Map<String, dynamic>);
  }

  Uri buildRawFileUri(String conversationId, String path) {
    return Uri.parse('$_cleanBase/api/v1/files/raw').replace(queryParameters: {
      'convId': conversationId,
      'path': path,
    });
  }

  void close() => _http.close();
}

enum MuxConnectionStatus { disconnected, connecting, connected, reconnecting }

class MuxEventMessage {
  const MuxEventMessage({
    required this.type,
    required this.channel,
    this.event,
    this.data,
    this.alert,
  });

  final String type; // "snapshot" | "event" | "alert"
  final String channel;
  final String? event;
  final dynamic data;
  final AgentAlert? alert;
}

/// Multiplexed WebSocket client with RTT ping/pong, exponential backoff, and contiguous seq resync.
class AgyMuxClient {
  AgyMuxClient({
    required this.baseUrl,
    required this.token,
    this.pingInterval = const Duration(seconds: 8),
    this.pongTimeout = const Duration(seconds: 14),
    this.connectTimeout = const Duration(seconds: 6),
    this.onReconnectNeeded,
  });

  final String baseUrl;
  final String token;
  final Duration pingInterval;
  final Duration pongTimeout;
  final Duration connectTimeout;
  final void Function()? onReconnectNeeded;

  final _statusCtrl = StreamController<MuxConnectionStatus>.broadcast();
  final _rttCtrl = StreamController<({int rttMs, bool desktopOnline})>.broadcast();
  final _msgCtrl = StreamController<MuxEventMessage>.broadcast();

  Stream<MuxConnectionStatus> get statusStream => _statusCtrl.stream;
  Stream<({int rttMs, bool desktopOnline})> get rttStream => _rttCtrl.stream;
  Stream<MuxEventMessage> get messages => _msgCtrl.stream;

  WebSocketChannel? _channel;
  HttpClient? _wsHttpClient;
  StreamSubscription? _sub;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  Completer<bool>? _verifyPongCompleter;
  int _verifyPingTs = 0;
  final Set<String> _activeSubs = {'\$global'};
  final MuxSeqTracker _seqTracker = MuxSeqTracker();
  int _backoffMs = 500;
  int _socketEpoch = 0;
  int _consecutiveFailures = 0;
  int _lastActivityMs = 0;
  bool _disposed = false;

  void connect() {
    if (_disposed) return;
    _statusCtrl.add(MuxConnectionStatus.connecting);
    unawaited(_openSocket());
  }

  void subscribe(String channel) {
    _activeSubs.add(channel);
    _send({'type': 'sub', 'channel': channel});
  }

  void unsubscribe(String channel) {
    if (channel == '\$global') return;
    _activeSubs.remove(channel);
    _send({'type': 'unsub', 'channel': channel});
  }

  /// Sends an immediate ping and waits briefly for any server frame; forces reconnect on half-open sockets.
  Future<bool> verifyAlive({Duration timeout = const Duration(milliseconds: 1500)}) async {
    if (_disposed || _channel == null) return false;
    final existing = _verifyPongCompleter;
    if (existing != null && !existing.isCompleted) {
      return existing.future;
    }

    final completer = Completer<bool>();
    final pingTs = max(DateTime.now().millisecondsSinceEpoch, _verifyPingTs + 1);
    _verifyPongCompleter = completer;
    _verifyPingTs = pingTs;
    _send({'type': 'ping', 'clientTs': pingTs});

    final ok = await completer.future.timeout(timeout, onTimeout: () => false);
    if (!completer.isCompleted) {
      completer.complete(ok);
    }
    if (identical(_verifyPongCompleter, completer)) {
      _verifyPongCompleter = null;
    }
    if (!ok && !_disposed) {
      _scheduleReconnect();
    }
    return ok;
  }

  Future<void> _openSocket() async {
    if (_disposed) return;
    _cleanupSocket();
    _seqTracker.reset();
    final epoch = ++_socketEpoch;

    final clean = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    final wsUrl = clean.startsWith('https://')
        ? clean.replaceFirst('https://', 'wss://')
        : clean.replaceFirst('http://', 'ws://');

    final customClient = _createRawHttpClient(
      directBypassProxy: isDirectEndpointUrl(baseUrl),
      connectionTimeout: connectTimeout,
    );
    _wsHttpClient = customClient;

    try {
      final channel = IOWebSocketChannel.connect(
        Uri.parse('$wsUrl/api/v1/mux'),
        headers: {'Authorization': 'Bearer $token'},
        pingInterval: const Duration(seconds: 25),
        connectTimeout: connectTimeout,
        customClient: customClient,
      );
      _channel = channel;

      // Wait until the WebSocket handshake actually completes before reporting connected.
      await channel.ready.timeout(connectTimeout);
      if (_disposed || epoch != _socketEpoch) {
        try {
          await channel.sink.close();
        } catch (_) {}
        return;
      }

      _backoffMs = 500;
      _consecutiveFailures = 0;
      _lastActivityMs = DateTime.now().millisecondsSinceEpoch;

      _sub = channel.stream.listen(
        _onRawMessage,
        onError: (_) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
        cancelOnError: true,
      );

      _statusCtrl.add(MuxConnectionStatus.connected);

      // Re-subscribe any non-global session channels on reconnect.
      for (final ch in _activeSubs) {
        if (ch != '\$global') {
          _send({'type': 'sub', 'channel': ch});
        }
      }

      _startPingLoop();
    } catch (_) {
      if (_disposed || epoch != _socketEpoch) return;
      _consecutiveFailures++;
      if (_consecutiveFailures == 2) {
        onReconnectNeeded?.call();
      }
      _scheduleReconnect();
    }
  }

  void _onRawMessage(dynamic raw) {
    if (raw is! String) return;
    _lastActivityMs = DateTime.now().millisecondsSinceEpoch;
    Map<String, dynamic> frame;
    try {
      frame = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final type = (frame['type'] as String?) ?? '';
    if (type == 'pong') {
      final clientTs = (frame['clientTs'] as num?)?.toInt() ?? 0;
      final pendingVerify = _verifyPongCompleter;
      if (pendingVerify != null && !pendingVerify.isCompleted && clientTs >= _verifyPingTs) {
        pendingVerify.complete(true);
      }
      if (clientTs > 0) {
        final rtt = max(1, DateTime.now().millisecondsSinceEpoch - clientTs);
        _rttCtrl.add((rttMs: rtt, desktopOnline: (frame['desktopOnline'] as bool?) ?? false));
      }
      return;
    }

    final pendingVerify = _verifyPongCompleter;
    if (pendingVerify != null && !pendingVerify.isCompleted) {
      pendingVerify.complete(true);
    }

    final channel = (frame['channel'] as String?) ?? '\$global';
    final gen = (frame['generation'] as String?) ?? '';
    final seq = (frame['seq'] as num?)?.toInt() ?? 0;

    if (type == 'snapshot') {
      _seqTracker.acceptSnapshot(gen, seq);
      _msgCtrl.add(MuxEventMessage(type: 'snapshot', channel: channel, data: frame['data']));
      return;
    }

    if (type == 'event' || type == 'alert') {
      if (!_seqTracker.acceptEvent(gen, seq)) {
        // Out-of-order or dropped frame detected: request fresh snapshot immediately.
        _send({'type': 'sub', 'channel': channel});
        return;
      }
      final alertMap = frame['alert'] as Map<String, dynamic>?;
      _msgCtrl.add(
        MuxEventMessage(
          type: type,
          channel: channel,
          event: frame['event'] as String?,
          data: frame['data'],
          alert: alertMap != null ? AgentAlert.fromJson(alertMap) : null,
        ),
      );
    }
  }

  void _startPingLoop() {
    _pingTimer?.cancel();
    _send({'type': 'ping', 'clientTs': DateTime.now().millisecondsSinceEpoch});
    _pingTimer = Timer.periodic(pingInterval, (_) {
      final idleMs = DateTime.now().millisecondsSinceEpoch - _lastActivityMs;
      if (idleMs > pongTimeout.inMilliseconds) {
        // Half-open TCP socket detected (e.g. Wi-Fi <-> 5G switch or container freeze).
        _scheduleReconnect();
        return;
      }
      _send({'type': 'ping', 'clientTs': DateTime.now().millisecondsSinceEpoch});
    });
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _cleanupSocket();
    _statusCtrl.add(MuxConnectionStatus.reconnecting);
    final delay = Duration(milliseconds: _backoffMs);
    _backoffMs = min(_backoffMs * 2, 10000);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () => unawaited(_openSocket()));
  }

  void _send(Map<String, dynamic> payload) {
    try {
      _channel?.sink.add(jsonEncode(payload));
    } catch (_) {}
  }

  void _cleanupSocket() {
    _pingTimer?.cancel();
    _pingTimer = null;
    final pendingVerify = _verifyPongCompleter;
    if (pendingVerify != null && !pendingVerify.isCompleted) {
      pendingVerify.complete(false);
    }
    _verifyPongCompleter = null;
    _sub?.cancel();
    _sub = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    try {
      _wsHttpClient?.close(force: true);
    } catch (_) {}
    _wsHttpClient = null;
  }

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _cleanupSocket();
    _statusCtrl.close();
    _rttCtrl.close();
    _msgCtrl.close();
  }
}
