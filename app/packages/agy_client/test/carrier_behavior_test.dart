import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agy_client/agy_client.dart';
import 'package:test/test.dart';

void main() {
  group('AgyHttpCarrier behavior against live HTTP server', () {
    late HttpServer server;
    late String baseUrl;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUrl = 'http://127.0.0.1:${server.port}';

      server.listen((req) async {
        if (req.uri.path == '/api/v1/health') {
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({
              'ok': true,
              'hostName': 'MacBook-Pro',
              'desktopOnline': true,
            }));
          await req.response.close();
          return;
        }

        if (req.headers.value('authorization') != 'Bearer valid_tok') {
          req.response
            ..statusCode = 401
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'ok': false, 'error': {'code': 'UNAUTHORIZED', 'message': 'bad token'}}));
          await req.response.close();
          return;
        }

        if (req.uri.path == '/api/v1/rpc') {
          final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
          final method = body['method'] as String?;
          if (method == 'sessions.sendMessage') {
            req.response
              ..statusCode = 200
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({
                'requestId': body['requestId'],
                'ok': false,
                'error': {'code': 'DESKTOP_OFFLINE', 'message': 'Antigravity desktop not running'},
              }));
          } else {
            req.response
              ..statusCode = 200
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({
                'requestId': body['requestId'],
                'ok': true,
                'data': {'subscriptionTier': 'Google AI Pro', 'updatedAt': 100, 'pools': []},
              }));
          }
          await req.response.close();
          return;
        }

        if (req.uri.path == '/api/v1/files/content') {
          final p = req.uri.queryParameters['path'] ?? '';
          if (p.contains('.env')) {
            req.response
              ..statusCode = 200
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({
                'ok': false,
                'error': {'code': 'PATH_FORBIDDEN', 'message': 'blocked'},
              }));
          } else {
            req.response
              ..statusCode = 200
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({
                'ok': true,
                'data': {
                  'path': p,
                  'name': 'plan.md',
                  'kind': 'markdown',
                  'mimeType': 'text/markdown',
                  'content': '# Hello',
                  'offset': 0,
                  'totalBytes': 7,
                  'truncated': false,
                },
              }));
          }
          await req.response.close();
          return;
        }

        req.response.statusCode = 404;
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('probeBestEndpoint picks reachable host even alongside dead endpoint', () async {
      final result = await AgyHttpCarrier.probeBestEndpoint(
        ['http://127.0.0.1:1', baseUrl],
        timeout: const Duration(milliseconds: 1200),
      );
      expect(result, isNotNull);
      expect(result!.endpoint, baseUrl);
      expect(result.hostName, 'MacBook-Pro');
      expect(result.desktopOnline, isTrue);
      expect(result.isDirect, isTrue);
    });

    test('distinguishes UNAUTHORIZED, DESKTOP_OFFLINE, and PATH_FORBIDDEN', () async {
      final badAuth = AgyHttpCarrier(baseUrl: baseUrl, token: 'wrong');
      addTearDown(badAuth.close);
      await expectLater(
        badAuth.getQuota(),
        throwsA(isA<BridgeRemoteException>().having((e) => e.isUnauthorized, 'isUnauthorized', isTrue)),
      );

      final good = AgyHttpCarrier(baseUrl: baseUrl, token: 'valid_tok');
      addTearDown(good.close);
      final snap = await good.getQuota();
      expect(snap.subscriptionTier, 'Google AI Pro');

      await expectLater(
        good.sendMessage('c1', 'go'),
        throwsA(isA<BridgeRemoteException>().having((e) => e.isDesktopOffline, 'isDesktopOffline', isTrue)),
      );

      await expectLater(
        good.fetchFileContent('c1', '/tmp/.env'),
        throwsA(isA<BridgeRemoteException>().having((e) => e.isPathForbidden, 'isPathForbidden', isTrue)),
      );

      final page = await good.fetchFileContent('c1', 'plan.md');
      expect(page.content, '# Hello');
      expect(page.kind, 'markdown');
    });
  });

  group('AgyMuxClient WebSocket behavior', () {
    test('measures RTT pong and requests resync on seq gap', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      final resubCompleter = Completer<String>();
      server.transform(WebSocketTransformer()).listen((ws) {
        ws.add(jsonEncode({
          'type': 'snapshot',
          'channel': '\$global',
          'generation': 'g1',
          'seq': 1,
          'data': {'hostName': 'MacBook-Pro'},
        }));
        // Intentionally skip seq 2 and send seq 3 to force automatic resync sub frame.
        ws.add(jsonEncode({
          'type': 'event',
          'channel': '\$global',
          'generation': 'g1',
          'seq': 3,
          'event': 'quota.updated',
          'data': {},
        }));
        ws.listen((raw) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          if (frame['type'] == 'ping') {
            ws.add(jsonEncode({
              'type': 'pong',
              'clientTs': frame['clientTs'],
              'serverTs': DateTime.now().millisecondsSinceEpoch,
              'desktopOnline': true,
            }));
          } else if (frame['type'] == 'sub' && !resubCompleter.isCompleted) {
            resubCompleter.complete(frame['channel'] as String);
          }
        });
      });

      final mux = AgyMuxClient(baseUrl: 'http://127.0.0.1:${server.port}', token: 'valid_tok');
      addTearDown(mux.dispose);

      final snapFuture = mux.messages.firstWhere((m) => m.type == 'snapshot');
      final rttFuture = mux.rttStream.first;
      mux.connect();

      final snap = await snapFuture.timeout(const Duration(seconds: 3));
      expect(snap.channel, '\$global');

      final rtt = await rttFuture.timeout(const Duration(seconds: 3));
      expect(rtt.desktopOnline, isTrue);
      expect(rtt.rttMs, greaterThanOrEqualTo(1));

      final resubChannel = await resubCompleter.future.timeout(const Duration(seconds: 3));
      expect(resubChannel, '\$global');
    });

    test('never reports connected on unreachable port and detects silent half-open server', () async {
      // 1. Unreachable port must transition connecting -> reconnecting without false connected.
      final statuses = <MuxConnectionStatus>[];
      final badMux = AgyMuxClient(
        baseUrl: 'http://127.0.0.1:1',
        token: 'tok',
        connectTimeout: const Duration(milliseconds: 500),
      );
      addTearDown(badMux.dispose);
      final sub = badMux.statusStream.listen(statuses.add);
      addTearDown(sub.cancel);

      badMux.connect();
      await badMux.statusStream
          .firstWhere((s) => s == MuxConnectionStatus.reconnecting)
          .timeout(const Duration(seconds: 3));
      expect(statuses, isNot(contains(MuxConnectionStatus.connected)));

      // 2. Silent server (never responds to ping) triggers half-open reconnect watchdog.
      final silentServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => silentServer.close(force: true));
      silentServer.transform(WebSocketTransformer()).listen((ws) {
        ws.listen((_) {}); // intentionally drop all pings
      });

      final silentMux = AgyMuxClient(
        baseUrl: 'http://127.0.0.1:${silentServer.port}',
        token: 'tok',
        pingInterval: const Duration(milliseconds: 120),
        pongTimeout: const Duration(milliseconds: 220),
      );
      addTearDown(silentMux.dispose);

      final connectedF = silentMux.statusStream.firstWhere((s) => s == MuxConnectionStatus.connected);
      final reconnectingF = silentMux.statusStream.firstWhere((s) => s == MuxConnectionStatus.reconnecting);
      silentMux.connect();
      await connectedF.timeout(const Duration(seconds: 2));
      await reconnectingF.timeout(const Duration(seconds: 2));
    });

    test('verifyAlive detects silent half-open server immediately before pongTimeout', () async {
      var respondToPing = true;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.transform(WebSocketTransformer()).listen((ws) {
        ws.listen((raw) {
          if (!respondToPing) return;
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          if (frame['type'] == 'ping') {
            ws.add(jsonEncode({
              'type': 'pong',
              'clientTs': frame['clientTs'],
              'serverTs': DateTime.now().millisecondsSinceEpoch,
              'desktopOnline': true,
            }));
          }
        });
      });

      final mux = AgyMuxClient(
        baseUrl: 'http://127.0.0.1:${server.port}',
        token: 'tok',
        pingInterval: const Duration(seconds: 30),
        pongTimeout: const Duration(seconds: 60),
      );
      addTearDown(mux.dispose);

      final connectedF = mux.statusStream.firstWhere((s) => s == MuxConnectionStatus.connected);
      mux.connect();
      await connectedF.timeout(const Duration(seconds: 2));

      expect(await mux.verifyAlive(timeout: const Duration(milliseconds: 500)), isTrue);

      respondToPing = false;
      final reconnectingF = mux.statusStream.firstWhere((s) => s == MuxConnectionStatus.reconnecting);
      expect(await mux.verifyAlive(timeout: const Duration(milliseconds: 220)), isFalse);
      await reconnectingF.timeout(const Duration(seconds: 1));
    });
  });
}
