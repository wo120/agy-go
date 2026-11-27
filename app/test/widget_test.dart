import 'dart:convert';
import 'dart:io';

import 'package:agy_client/agy_client.dart';
import 'package:agy_mobile/state/app_state.dart';
import 'package:agy_mobile/state/native_bridge.dart';
import 'package:agy_mobile/theme/agy_theme.dart';
import 'package:agy_mobile/ui/chat/chat_screen.dart';
import 'package:agy_mobile/ui/home/home_screen.dart';
import 'package:agy_mobile/ui/home/new_session_sheet.dart';
import 'package:agy_mobile/ui/home/quota_card.dart';
import 'package:agy_mobile/ui/pairing/pairing_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeHostNotifier extends HostConnectionNotifier {
  @override
  HostConnectionState build() {
    return const HostConnectionState(
      pairing: PairingPayload(
        version: 1,
        hostName: 'MacBook-Pro',
        endpoints: ['http://192.168.1.10:8765'],
        token: 'agy_live_test',
      ),
      activeEndpoint: 'http://192.168.1.10:8765',
      isDirect: true,
      rttMs: 18,
      desktopOnline: true,
      status: MuxConnectionStatus.connected,
    );
  }
}

class _FakeQuotaNotifier extends QuotaStateNotifier {
  @override
  QuotaUiState build() {
    return const QuotaUiState(
      collapsed: false,
      snapshot: QuotaSnapshot(
        subscriptionTier: 'Google AI Pro',
        updatedAt: 1795527000,
        pools: [
          PoolQuota(
            poolId: 'gemini',
            displayName: 'Gemini',
            remaining5hPct: 34,
            reset5hAt: 1795542978,
            remaining7dPct: 67,
            reset7dAt: 1795766393,
            level: 'warning',
            source: 'direct',
          ),
          PoolQuota(
            poolId: 'claude_gpt',
            displayName: 'Claude · GPT',
            remaining5hPct: 100,
            reset5hAt: null,
            remaining7dPct: 100,
            reset7dAt: null,
            level: 'full',
            source: 'direct',
          ),
        ],
      ),
    );
  }

  @override
  Future<void> toggleCollapsed() async {
    state = state.copyWith(collapsed: !state.collapsed);
  }
}

class _FakeSessionsNotifier extends SessionsStateNotifier {
  @override
  SessionsUiState build() {
    const ws1 = WorkspaceInfo(
      kind: 'workspace',
      label: 'antigravity-mobile',
      rootPath: '/Users/apple/go-project/ai/antigravity-mobile',
    );
    const ws2 = WorkspaceInfo(kind: 'global', label: '通用对话');
    return const SessionsUiState(
      mode: 'project',
      groups: [
        ProjectGroup(
          workspace: ws1,
          latestActiveUnix: 1795527000,
          sessions: [
            SessionCard(
              conversationId: 'c1',
              title: '会话 A1',
              preview: '预览 A1',
              stepCount: 3,
              lastModifiedUnix: 1795527000,
              workspace: ws1,
              status: 'IDLE',
              running: false,
              subagentCount: 0,
              artifactCount: 0,
              pinned: false,
              pinnedOrder: 0,
              unread: false,
              needsConfirm: false,
            ),
            SessionCard(
              conversationId: 'c2',
              title: '会话 A2',
              preview: '预览 A2',
              stepCount: 2,
              lastModifiedUnix: 1795526900,
              workspace: ws1,
              status: 'IDLE',
              running: false,
              subagentCount: 0,
              artifactCount: 0,
              pinned: false,
              pinnedOrder: 0,
              unread: false,
              needsConfirm: false,
            ),
          ],
        ),
        ProjectGroup(
          workspace: ws2,
          latestActiveUnix: 1795526800,
          sessions: [
            SessionCard(
              conversationId: 'c3',
              title: '会话 B1',
              preview: '预览 B1',
              stepCount: 1,
              lastModifiedUnix: 1795526800,
              workspace: ws2,
              status: 'IDLE',
              running: false,
              subagentCount: 0,
              artifactCount: 0,
              pinned: false,
              pinnedOrder: 0,
              unread: false,
              needsConfirm: false,
            ),
          ],
        ),
      ],
    );
  }
}

class _FakeChatSessionNotifier extends ChatSessionNotifier {
  @override
  ChatSessionState build(String conversationId) {
    final steps = [
      for (var i = 0; i < 24; i++)
        TranscriptStep(
          stepIndex: i,
          source: i.isEven ? 'USER_EXPLICIT' : 'MODEL',
          type: i.isEven ? 'USER_INPUT' : 'PLANNER_RESPONSE',
          status: 'DONE',
          createdAtUnix: 1795527000 + i,
          content: '消息 $i',
        ),
    ];
    return ChatSessionState(
      session: const SessionCard(
        conversationId: 'c-tail',
        title: '长会话测试',
        preview: '消息 23',
        stepCount: 24,
        lastModifiedUnix: 1795527023,
        workspace: WorkspaceInfo(kind: 'workspace', label: 'antigravity-mobile'),
        status: 'IDLE',
        running: false,
        subagentCount: 0,
        artifactCount: 0,
        pinned: false,
        pinnedOrder: 0,
        unread: false,
        needsConfirm: false,
      ),
      steps: steps,
      rows: TranscriptReducer.reduce(steps),
      loading: false,
    );
  }
}

void main() {
  test('formatResetCountdown formats full, hours, and days accurately', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1795527000 * 1000);
    expect(formatResetCountdown(null, 100, now: now), '满额');
    expect(formatResetCountdown(1795527000 + 4140, 84, now: now), '1h 9m 后重置');
    expect(formatResetCountdown(1795527000 + (4 * 86400 + 10 * 3600), 34, now: now), '4d 10h 后重置');
  });

  testWidgets('SessionSummaryCard hides artifact badge when artifactCount is 0 and shows when > 0', (tester) async {
    const cardZero = SessionCard(
      conversationId: 'c1',
      title: 'Antigravity 大百科',
      preview: '搞定收工！',
      stepCount: 5,
      lastModifiedUnix: 1795527000,
      workspace: WorkspaceInfo(kind: 'global', label: '通用对话'),
      status: 'IDLE',
      running: false,
      subagentCount: 3,
      artifactCount: 0,
      modelDisplay: 'Hydrogen · XHigh',
      pinned: true,
      pinnedOrder: 1,
      unread: false,
      needsConfirm: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAgyTheme(),
        home: Scaffold(
          body: SessionSummaryCard(
            card: cardZero,
            onTap: () {},
            onLongPress: () {},
          ),
        ),
      ),
    );

    expect(find.text('Antigravity 大百科'), findsOneWidget);
    expect(find.text('通用对话'), findsOneWidget);
    expect(find.text('Hydrogen · XHigh'), findsOneWidget);
    expect(find.text('3 子代理'), findsOneWidget);
    expect(find.textContaining('产物'), findsNothing);

    const cardWithArtifacts = SessionCard(
      conversationId: 'c2',
      title: 'AGY Go',
      preview: '已生成规范文档',
      stepCount: 10,
      lastModifiedUnix: 1795527000,
      workspace: WorkspaceInfo(kind: 'workspace', label: 'antigravity-mobile'),
      status: 'IDLE',
      running: false,
      subagentCount: 1,
      artifactCount: 5,
      modelDisplay: 'Neon · High',
      pinned: false,
      pinnedOrder: 0,
      unread: true,
      needsConfirm: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAgyTheme(),
        home: Scaffold(
          body: SessionSummaryCard(
            card: cardWithArtifacts,
            onTap: () {},
            onLongPress: () {},
          ),
        ),
      ),
    );

    expect(find.text('antigravity-mobile'), findsOneWidget);
    expect(find.text('5 产物'), findsOneWidget);
  });

  testWidgets('QuotaDashboardCard displays live Google AI Pro tier, warning pct, and collapses on tap', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostConnectionProvider.overrideWith(_FakeHostNotifier.new),
          quotaStateProvider.overrideWith(_FakeQuotaNotifier.new),
        ],
        child: MaterialApp(
          theme: buildAgyTheme(),
          home: Scaffold(
            body: QuotaDashboardCard(onTapHost: () {}),
          ),
        ),
      ),
    );

    expect(find.text('MacBook-Pro · 已直连 (18ms)'), findsOneWidget);
    expect(find.text('Google AI Pro'), findsOneWidget);
    expect(find.text('34%'), findsOneWidget);
    expect(find.text('满额'), findsNWidgets(2));

    // Toggle collapse by tapping tier label
    await tester.tap(find.text('Google AI Pro'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);
  });

  testWidgets('HomeScreen project mode collapses groups by default and toggles on tap', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostConnectionProvider.overrideWith(_FakeHostNotifier.new),
          quotaStateProvider.overrideWith(_FakeQuotaNotifier.new),
          sessionsStateProvider.overrideWith(_FakeSessionsNotifier.new),
        ],
        child: MaterialApp(
          theme: buildAgyTheme(),
          home: const HomeScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('antigravity-mobile'), findsOneWidget);
    expect(find.text('通用对话'), findsOneWidget);
    expect(find.text('会话 A1'), findsNothing);
    expect(find.text('会话 A2'), findsNothing);
    expect(find.text('会话 B1'), findsNothing);
    expect(find.byIcon(Icons.expand_more_rounded), findsNWidgets(2));

    await tester.tap(find.text('antigravity-mobile'));
    await tester.pumpAndSettle();
    expect(find.text('会话 A1'), findsOneWidget);
    expect(find.text('会话 B1'), findsNothing);
    expect(find.byIcon(Icons.expand_less_rounded), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('会话 A2'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('会话 A2'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('通用对话'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byIcon(Icons.expand_more_rounded), findsOneWidget);
    expect(find.text('会话 B1'), findsNothing);

    await tester.scrollUntilVisible(
      find.byIcon(Icons.expand_less_rounded),
      -150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byIcon(Icons.expand_less_rounded));
    await tester.pumpAndSettle();
    expect(find.text('会话 A1'), findsNothing);
    expect(find.text('会话 A2'), findsNothing);
  });

  testWidgets('ChatScreen defaults scroll position to tail and supports scroll-to-bottom button', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostConnectionProvider.overrideWith(_FakeHostNotifier.new),
          chatSessionProvider.overrideWith(_FakeChatSessionNotifier.new),
        ],
        child: MaterialApp(
          theme: buildAgyTheme(),
          home: const ChatScreen(conversationId: 'c-tail'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('消息 23'), findsOneWidget);
    expect(find.text('消息 0'), findsNothing);
    expect(find.byIcon(Icons.keyboard_double_arrow_down_rounded), findsNothing);

    await tester.drag(find.byType(ListView), const Offset(0, 1000));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.keyboard_double_arrow_down_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.keyboard_double_arrow_down_rounded));
    await tester.pumpAndSettle();
    expect(find.text('消息 23'), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_double_arrow_down_rounded), findsNothing);
  });

  testWidgets('NewSessionSheet uses live desktop models, switches effort pills, and falls back offline', (tester) async {
    String? submittedModel;
    String? submittedPrompt;

    const liveModels = [
      ModelOption(modelId: 'gemini-4-neon-high', label: 'Gemini 4 Neon (High)', poolId: 'gemini', tag: 'New', isDefault: true),
      ModelOption(modelId: 'gemini-4-neon-xhigh', label: 'Gemini 4 Neon (XHigh)', poolId: 'gemini', tag: 'New'),
      ModelOption(modelId: 'gemini-4-neon-low', label: 'Gemini 4 Neon (Low)', poolId: 'gemini', tag: 'New'),
      ModelOption(modelId: 'claude-opus-5-5-medium', label: 'Claude Opus 5.5 (Medium)', poolId: 'claude_gpt', tag: 'New'),
      ModelOption(modelId: 'claude-opus-5-5-high', label: 'Claude Opus 5.5 (High)', poolId: 'claude_gpt', tag: 'New'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAgyTheme(),
        home: Scaffold(
          body: NewSessionSheet(
            workspaces: const [
              WorkspaceInfo(kind: 'workspace', label: 'antigravity-mobile', rootPath: '/repo/app'),
            ],
            models: liveModels,
            onSubmit: ({
              required String prompt,
              required String title,
              required String model,
              String? workspacePath,
            }) async {
              submittedPrompt = prompt;
              submittedModel = model;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Defaults to desktop default modelId
    expect(find.text('gemini-4-neon-high'), findsOneWidget);
    expect(find.text('Low'), findsOneWidget);
    expect(find.text('High'), findsOneWidget);
    expect(find.text('XHigh'), findsOneWidget);

    // Tap XHigh effort pill
    await tester.tap(find.text('XHigh'));
    await tester.pumpAndSettle();
    expect(find.text('gemini-4-neon-xhigh'), findsOneWidget);

    // Optional title field is collapsed by default and expands on tap
    expect(find.byKey(const Key('new_session_title_field')), findsNothing);
    await tester.tap(find.text('自定义标题'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('new_session_title_field')), findsOneWidget);

    // Enter prompt and submit
    await tester.enterText(find.byKey(const Key('new_session_prompt_field')), '测试实机模型选择');
    await tester.pumpAndSettle();
    await tester.tap(find.text('发送到 Mac 执行'));
    await tester.pumpAndSettle();

    expect(submittedPrompt, '测试实机模型选择');
    expect(submittedModel, 'gemini-4-neon-xhigh');

    // Offline fallback when models list is empty
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAgyTheme(),
        home: Scaffold(
          body: NewSessionSheet(
            workspaces: const [],
            models: const [],
            onSubmit: ({
              required String prompt,
              required String title,
              required String model,
              String? workspacePath,
            }) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('pro'), findsOneWidget);
    expect(find.textContaining('已回退为基础档位'), findsOneWidget);
  });

  testWidgets('ChatScreen renders actionable error card with retry button on load failure', (tester) async {
    var reloadCount = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostConnectionProvider.overrideWith(_FakeHostNotifier.new),
          chatSessionProvider.overrideWith(() => _FailingChatSessionNotifier(() => reloadCount++)),
        ],
        child: MaterialApp(
          theme: buildAgyTheme(),
          home: const ChatScreen(conversationId: 'c-err'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('会话内容加载失败'), findsOneWidget);
    expect(find.textContaining('Network request failed'), findsOneWidget);
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();
    expect(reloadCount, 1);
  });

  test('HostConnectionNotifier clears stale connected banner and updates AlwaysOn notification when host becomes unreachable', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final prevHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    final serviceCalls = <String>[];
    const channel = MethodChannel('agy/native');
    NativeBridge.instance.forceAndroidForTest = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async {
        if (call.method == 'startAlwaysOnService') {
          final args = (call.arguments as Map?) ?? const {};
          serviceCalls.add('${args['statusText']}');
        }
        return true;
      },
    );
    addTearDown(() {
      HttpOverrides.global = prevHttpOverrides;
      NativeBridge.instance.forceAndroidForTest = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final baseUrl = 'http://127.0.0.1:${server.port}';
    final sockets = <WebSocket>[];
    var dropPings = false;
    server.listen((req) async {
      if (req.uri.path == '/api/v1/mux') {
        final ws = await WebSocketTransformer.upgrade(req);
        sockets.add(ws);
        ws.listen((raw) {
          if (dropPings) return;
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
        return;
      }
      if (req.uri.path == '/api/v1/health') {
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'ok': true, 'hostName': 'MacBook-Pro', 'desktopOnline': true}));
        await req.response.close();
        return;
      }
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'ok': true, 'data': {}}));
      await req.response.close();
    });
    addTearDown(() async {
      for (final s in sockets) {
        await s.close();
      }
      await server.close(force: true);
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(hostConnectionProvider.notifier);
    await notifier.connectWithPairing(
      PairingPayload(version: 1, hostName: 'MacBook-Pro', endpoints: [baseUrl], token: 'tok'),
      persist: false,
    );

    // Wait for WebSocket connected state.
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (container.read(hostConnectionProvider).status != MuxConnectionStatus.connected &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(container.read(hostConnectionProvider).status, MuxConnectionStatus.connected);
    expect(serviceCalls.any((s) => s.contains('已直连')), isTrue);

    // Simulate switching to 5G where server is unreachable (health fails & half-open WS stops answering pings).
    dropPings = true;
    await server.close(force: true);

    await notifier.verifyConnection();

    final after = container.read(hostConnectionProvider);
    expect(after.status, MuxConnectionStatus.reconnecting);
    expect(after.desktopOnline, isFalse);
    expect(after.rttMs, isNull);
    expect(after.connectionBanner, 'MacBook-Pro · 重连中...');
    expect(after.connectionBanner.contains('已直连'), isFalse);
    expect(serviceCalls.last, 'MacBook-Pro · 重连中...');
  });

  testWidgets('PairingScreen triggers verifyConnection on open and never displays 已直连 when reconnecting', (tester) async {
    var verifyCount = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostConnectionProvider.overrideWith(() => _ReconnectingHostNotifier(() => verifyCount++)),
        ],
        child: MaterialApp(
          theme: buildAgyTheme(),
          home: const PairingScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(verifyCount, 1);
    expect(find.text('MacBook-Pro · 重连中...'), findsOneWidget);
    expect(find.text('目标节点：http://192.168.1.10:8765'), findsOneWidget);
    expect(find.textContaining('未连接宿主机'), findsOneWidget);
    expect(find.textContaining('已直连'), findsNothing);
  });

  test('formatMessageTime formats today, same year, and cross-year accurately', () {
    final now = DateTime(2026, 11, 25, 14, 30);
    final sameDay = DateTime(2026, 11, 25, 4, 7).millisecondsSinceEpoch ~/ 1000;
    final earlierDay = DateTime(2026, 11, 24, 22, 53).millisecondsSinceEpoch ~/ 1000;
    final prevYear = DateTime(2025, 12, 31, 9, 5).millisecondsSinceEpoch ~/ 1000;

    expect(formatMessageTime(0, now: now), '');
    expect(formatMessageTime(sameDay, now: now), '04:07');
    expect(formatMessageTime(earlierDay, now: now), '11-24 22:53');
    expect(formatMessageTime(prevYear, now: now), '2025-12-31 09:05');
  });

  testWidgets('ChatScreen shows send time and allows toggling preserved user metadata', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostConnectionProvider.overrideWith(_FakeHostNotifier.new),
          chatSessionProvider.overrideWith(_UserMetaChatSessionNotifier.new),
        ],
        child: MaterialApp(
          theme: buildAgyTheme(),
          home: const ChatScreen(conversationId: 'c-meta'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('先优化'), findsOneWidget);
    expect(find.text(formatMessageTime(1795597636)), findsAtLeastNWidgets(1));
    expect(find.text('元信息'), findsOneWidget);
    expect(find.textContaining('The current local time is:'), findsNothing);

    await tester.tap(find.text('元信息'));
    await tester.pumpAndSettle();

    expect(find.text('收起元信息'), findsOneWidget);
    expect(find.textContaining('The current local time is: 2026-11-25T04:07:16-05:00.'), findsOneWidget);
  });

  testWidgets('HomeScreen 3-tab bottom dock switches between sessions, alerts, and host tabs', (tester) async {
    var verifyCount = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostConnectionProvider.overrideWith(() => _ReconnectingHostNotifier(() => verifyCount++)),
          quotaStateProvider.overrideWith(_FakeQuotaNotifier.new),
          sessionsStateProvider.overrideWith(_FakeSessionsNotifier.new),
          alertsStateProvider.overrideWith(_FakeUnreadAlertsNotifier.new),
        ],
        child: MaterialApp(
          theme: buildAgyTheme(),
          home: const HomeScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Tab 0 (对话) shows AGY Go header, FAB, and unread alert badge "2"
    expect(find.text('AGY Go'), findsOneWidget);
    expect(find.byKey(const Key('home_new_session_fab')), findsOneWidget);
    final unreadBadgeFinder = find.descendant(
      of: find.byKey(const Key('nav_tab_alerts')),
      matching: find.text('2'),
    );
    expect(unreadBadgeFinder, findsOneWidget);
    expect(verifyCount, 0);

    // Switch to Tab 1 (提醒): clears unread badge, hides FAB, shows AlertsScreen header
    await tester.tap(find.byKey(const Key('nav_tab_alerts')));
    await tester.pumpAndSettle();
    expect(find.text('提醒中心'), findsOneWidget);
    expect(find.byKey(const Key('home_new_session_fab')), findsNothing);
    expect(unreadBadgeFinder, findsNothing);

    // Switch to Tab 2 (主机): triggers verifyConnection once and shows Host panel
    await tester.tap(find.byKey(const Key('nav_tab_host')));
    await tester.pumpAndSettle();
    expect(verifyCount, 1);
    expect(find.text('主机与连接'), findsOneWidget);
    expect(find.byKey(const Key('home_new_session_fab')), findsNothing);

    // Switch back to Tab 0 (对话): restores FAB
    await tester.tap(find.byKey(const Key('nav_tab_sessions')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home_new_session_fab')), findsOneWidget);
  });

  testWidgets('Redesigned HomeScreen and ChatScreen render cleanly on narrow 360dp viewport without overflow', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostConnectionProvider.overrideWith(_FakeHostNotifier.new),
          quotaStateProvider.overrideWith(_FakeQuotaNotifier.new),
          sessionsStateProvider.overrideWith(_FakeDesktopSessionsNotifier.new),
          alertsStateProvider.overrideWith(_FakeUnreadAlertsNotifier.new),
        ],
        child: MaterialApp(
          theme: buildAgyTheme(),
          home: const HomeScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Gemini'), findsOneWidget);
    expect(find.text('Claude · GPT'), findsOneWidget);
    expect(find.text('已置顶'), findsOneWidget);
    expect(find.text('原创 UI 重构方案与验证'), findsOneWidget);

    await tester.pumpWidget(
      ProviderScope(
        key: const ValueKey('chat_narrow_scope'),
        overrides: [
          hostConnectionProvider.overrideWith(_FakeHostNotifier.new),
          chatSessionProvider.overrideWith(_UserMetaChatSessionNotifier.new),
        ],
        child: MaterialApp(
          theme: buildAgyTheme(),
          home: const ChatScreen(conversationId: 'c-meta'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('QuotaDashboardCard renders TPS strip and opens per-model breakdown sheet cleanly on 360dp', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostConnectionProvider.overrideWith(_FakeHostNotifier.new),
          quotaStateProvider.overrideWith(_FakeQuotaNotifier.new),
          tpsStateProvider.overrideWith(_FakeTpsNotifier.new),
        ],
        child: MaterialApp(
          theme: buildAgyTheme(),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: QuotaDashboardCard(onTapHost: () {}),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('143.0 tok/s'), findsOneWidget);
    expect(find.textContaining('E2E 72.0 · TTFT 6.5s'), findsOneWidget);
    expect(find.text('最近：Gemini 4 Neon (High)'), findsOneWidget);

    await tester.tap(find.byKey(const Key('quota_tps_strip')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('输出速度监控 (TPS · 5h)'), findsOneWidget);
    expect(find.text('近 5h 分模型速度'), findsOneWidget);
    expect(find.text('Gemini 4 Neon (High)'), findsOneWidget);
    expect(find.text('Claude Opus 5.5 (High)'), findsOneWidget);
  });

  testWidgets('ChatScreen displays per-turn TPS badge and expands Stream/E2E/TTFT details on tap', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostConnectionProvider.overrideWith(_FakeHostNotifier.new),
          chatSessionProvider.overrideWith(_SpeedChatSessionNotifier.new),
        ],
        child: MaterialApp(
          theme: buildAgyTheme(),
          home: const ChatScreen(conversationId: 'c-speed'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('152 tok/s'), findsOneWidget);
    expect(find.textContaining('TTFT 6.2s'), findsNothing);

    await tester.tap(find.text('152 tok/s'));
    await tester.pumpAndSettle();

    expect(find.text('流式 152.4 tok/s · E2E 95.8 tok/s · TTFT 6.2s · 1600 tok'), findsOneWidget);
  });

  testWidgets('ChatScreen renders pending permission approval dock and submits allow/persist/deny', (tester) async {
    final decisions = <({bool allow, String scope, String? feedback})>[];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostConnectionProvider.overrideWith(_FakeHostNotifier.new),
          chatSessionProvider.overrideWith(() => _PermissionChatSessionNotifier(decisions)),
        ],
        child: MaterialApp(
          theme: buildAgyTheme(),
          home: const ChatScreen(conversationId: 'c-perm'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('pending_interaction_dock')), findsOneWidget);
    expect(find.text('允许 检查当前运行进程?'), findsOneWidget);
    expect(find.text('ps -eo pid,comm,args'), findsOneWidget);
    expect(find.text('终端命令'), findsOneWidget);
    expect(find.text("本次会话始终允许 'ps'"), findsOneWidget);
    expect(find.text("始终允许 'ps'"), findsOneWidget);

    await tester.tap(find.byKey(const Key('perm_deny_with_reason_toggle')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('perm_deny_reason_input')), '改用 pgrep');
    await tester.tap(find.byKey(const Key('perm_deny_reason_submit')));
    await tester.pumpAndSettle();

    expect(decisions.length, 1);
    expect(decisions.first.allow, isFalse);
    expect(decisions.first.scope, 'once');
    expect(decisions.first.feedback, '改用 pgrep');
    expect(find.byKey(const Key('pending_interaction_dock')), findsNothing);
  });

  testWidgets('SessionSummaryCard displays 待授权 badge when pendingInteractionCount > 0', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAgyTheme(),
        home: Scaffold(
          body: SessionSummaryCard(
            card: const SessionCard(
              conversationId: 'c-auth',
              title: '检查系统进程',
              preview: '正在执行命令',
              stepCount: 8,
              lastModifiedUnix: 1795527000,
              workspace: WorkspaceInfo(kind: 'workspace', label: 'antigravity-mobile'),
              status: 'RUNNING',
              running: true,
              subagentCount: 0,
              artifactCount: 0,
              pinned: false,
              pinnedOrder: 0,
              unread: false,
              needsConfirm: true,
              pendingInteractionCount: 1,
            ),
            onTap: () {},
            onLongPress: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('待授权'), findsOneWidget);
  });
}

class _FakeDesktopSessionsNotifier extends SessionsStateNotifier {
  @override
  SessionsUiState build() {
    const ws = WorkspaceInfo(
      kind: 'workspace',
      label: 'antigravity-mobile',
      rootPath: '/Users/apple/go-project/ai/antigravity-mobile',
    );
    return const SessionsUiState(
      mode: 'desktop',
      pinned: [
        SessionCard(
          conversationId: 'p1',
          title: '原创 UI 重构方案与验证',
          preview: '切换到碳黑工业控制台风格并完成全量测试。',
          stepCount: 12,
          lastModifiedUnix: 1795527000,
          workspace: ws,
          status: 'IDLE',
          running: false,
          subagentCount: 2,
          artifactCount: 3,
          modelDisplay: 'Gemini 4 Neon · High',
          pinned: true,
          pinnedOrder: 1,
          unread: true,
          needsConfirm: false,
        ),
      ],
      regular: [
        SessionCard(
          conversationId: 'r1',
          title: '等待确认的生产发布清单',
          preview: '请确认是否立即发布 Android APK。',
          stepCount: 5,
          lastModifiedUnix: 1795526000,
          workspace: ws,
          status: 'WAITING',
          running: false,
          subagentCount: 0,
          artifactCount: 1,
          modelDisplay: 'Claude Opus 5.5 · High',
          pinned: false,
          pinnedOrder: 0,
          unread: false,
          needsConfirm: true,
        ),
      ],
    );
  }
}

class _FakeUnreadAlertsNotifier extends AlertsStateNotifier {
  @override
  AlertsUiState build() {
    return const AlertsUiState(
      unreadCount: 2,
      alerts: [
        AgentAlert(
          alertId: 'a1',
          conversationId: 'c1',
          kind: 'NEED_CONFIRM',
          title: '等待确认架构方案',
          body: '是否继续执行？',
          workspace: 'antigravity-mobile',
          createdAt: 1795527000,
          quickReplies: ['继续'],
        ),
      ],
    );
  }
}

class _UserMetaChatSessionNotifier extends ChatSessionNotifier {
  @override
  ChatSessionState build(String conversationId) {
    const steps = [
      TranscriptStep(
        stepIndex: 0,
        source: 'USER_EXPLICIT',
        type: 'USER_INPUT',
        status: 'DONE',
        createdAtUnix: 1795597636,
        content: '<USER_REQUEST>\n先优化\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nThe current local time is: 2026-11-25T04:07:16-05:00.\n</ADDITIONAL_METADATA>',
      ),
      TranscriptStep(
        stepIndex: 1,
        source: 'MODEL',
        type: 'PLANNER_RESPONSE',
        status: 'DONE',
        createdAtUnix: 1795597642,
        modelDisplay: 'Hydrogen · High',
        content: '好的，已处理。',
      ),
    ];
    return ChatSessionState(
      session: const SessionCard(
        conversationId: 'c-meta',
        title: '元信息测试',
        preview: '好的，已处理。',
        stepCount: 2,
        lastModifiedUnix: 1795597642,
        workspace: WorkspaceInfo(kind: 'workspace', label: 'antigravity-mobile'),
        status: 'IDLE',
        running: false,
        subagentCount: 0,
        artifactCount: 0,
        pinned: false,
        pinnedOrder: 0,
        unread: false,
        needsConfirm: false,
      ),
      steps: steps,
      rows: TranscriptReducer.reduce(steps),
      loading: false,
    );
  }
}

class _ReconnectingHostNotifier extends HostConnectionNotifier {
  _ReconnectingHostNotifier(this.onVerify);

  final VoidCallback onVerify;

  @override
  HostConnectionState build() {
    return const HostConnectionState(
      pairing: PairingPayload(
        version: 1,
        hostName: 'MacBook-Pro',
        endpoints: ['http://192.168.1.10:8765'],
        token: 'agy_live_test',
      ),
      activeEndpoint: 'http://192.168.1.10:8765',
      isDirect: true,
      desktopOnline: false,
      status: MuxConnectionStatus.reconnecting,
    );
  }

  @override
  Future<void> verifyConnection({bool forceReprobe = false}) async {
    onVerify();
  }
}

class _FailingChatSessionNotifier extends ChatSessionNotifier {
  _FailingChatSessionNotifier(this.onReload);

  final VoidCallback onReload;

  @override
  ChatSessionState build(String conversationId) {
    return const ChatSessionState(
      loading: false,
      error: 'CarrierException: Network request failed for sessions.get',
    );
  }

  @override
  Future<void> reload() async {
    onReload();
  }
}

class _FakeTpsNotifier extends TpsStateNotifier {
  @override
  TpsUiState build() {
    return const TpsUiState(
      snapshot: TpsSnapshot(
        updatedAt: 1795600000,
        windowSeconds: 18000,
        sampleCount: 15,
        streamSamples: 12,
        outputTokens: 24500,
        streamTps: 143.0,
        e2eTps: 72.0,
        avgTtftMs: 6500,
        latest: TpsTurn(
          conversationId: 'c-1',
          stepIndex: 8,
          createdAtUnix: 1795599990,
          poolId: 'gemini',
          model: 'gemini-4-neon',
          modelDisplay: 'Gemini 4 Neon (High)',
          outputTokens: 1600,
          ttftMs: 6200,
          streamingMs: 10500,
          streamTps: 152.4,
          e2eTps: 95.8,
        ),
        models: [
          ModelTpsStats(
            model: 'gemini-4-neon',
            modelDisplay: 'Gemini 4 Neon (High)',
            poolId: 'gemini',
            sampleCount: 12,
            streamSamples: 10,
            outputTokens: 20000,
            streamTps: 148.5,
            e2eTps: 75.0,
            avgTtftMs: 7000,
            lastActiveUnix: 1795599990,
          ),
          ModelTpsStats(
            model: 'claude-opus-5-5',
            modelDisplay: 'Claude Opus 5.5 (High)',
            poolId: 'claude_gpt',
            sampleCount: 3,
            streamSamples: 2,
            outputTokens: 4500,
            streamTps: 88.2,
            e2eTps: 68.4,
            avgTtftMs: 2600,
            lastActiveUnix: 1795599500,
          ),
        ],
      ),
    );
  }
}

class _SpeedChatSessionNotifier extends ChatSessionNotifier {
  @override
  ChatSessionState build(String conversationId) {
    const steps = [
      TranscriptStep(
        stepIndex: 0,
        source: 'USER_EXPLICIT',
        type: 'USER_INPUT',
        status: 'DONE',
        createdAtUnix: 1795599980,
        content: '测一下速度展示',
      ),
      TranscriptStep(
        stepIndex: 1,
        source: 'MODEL',
        type: 'PLANNER_RESPONSE',
        status: 'DONE',
        createdAtUnix: 1795599990,
        modelDisplay: 'Neon · High',
        content: '这是带 TPS 指标的回复。',
        outputTokens: 1600,
        ttftMs: 6200,
        streamingMs: 10500,
        streamTps: 152.4,
        e2eTps: 95.8,
      ),
    ];
    return ChatSessionState(
      session: const SessionCard(
        conversationId: 'c-speed',
        title: 'TPS 展示测试',
        preview: '这是带 TPS 指标的回复。',
        stepCount: 2,
        lastModifiedUnix: 1795599990,
        workspace: WorkspaceInfo(kind: 'workspace', label: 'antigravity-mobile'),
        status: 'IDLE',
        running: false,
        subagentCount: 0,
        artifactCount: 0,
        pinned: false,
        pinnedOrder: 0,
        unread: false,
        needsConfirm: false,
      ),
      steps: steps,
      rows: TranscriptReducer.reduce(steps),
      loading: false,
    );
  }
}

class _PermissionChatSessionNotifier extends ChatSessionNotifier {
  _PermissionChatSessionNotifier(this.decisions);

  final List<({bool allow, String scope, String? feedback})> decisions;

  @override
  ChatSessionState build(String conversationId) {
    const steps = [
      TranscriptStep(
        stepIndex: 0,
        source: 'USER_EXPLICIT',
        type: 'USER_INPUT',
        status: 'DONE',
        createdAtUnix: 1795597636,
        content: '检查当前运行进程',
      ),
    ];
    return ChatSessionState(
      session: const SessionCard(
        conversationId: 'c-perm',
        title: '进程检查',
        preview: '准备执行 ps',
        stepCount: 8,
        lastModifiedUnix: 1795597642,
        workspace: WorkspaceInfo(kind: 'workspace', label: 'antigravity-mobile'),
        status: 'RUNNING',
        running: true,
        subagentCount: 0,
        artifactCount: 0,
        pinned: false,
        pinnedOrder: 0,
        unread: false,
        needsConfirm: true,
        pendingInteractionCount: 1,
      ),
      steps: steps,
      rows: TranscriptReducer.reduce(steps),
      pendingInteractions: const [
        PendingInteraction(
          conversationId: 'c-perm',
          trajectoryId: 'traj-perm',
          stepIndex: 8,
          kind: 'permission',
          toolName: 'run_command',
          permission: PermissionRequest(
            action: 'command',
            target: 'ps -eo pid,comm,args',
            actionDescription: '检查当前运行进程',
            suggestedPersistPattern: 'ps',
            allowPersist: true,
            shellName: 'zsh',
          ),
        ),
      ],
      loading: false,
    );
  }

  @override
  Future<void> respondPermission(
    PendingInteraction interaction, {
    required bool allow,
    String scope = 'once',
    String? feedback,
  }) async {
    decisions.add((allow: allow, scope: scope, feedback: feedback));
    state = state.copyWith(pendingInteractions: const []);
  }
}
