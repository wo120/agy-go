import 'package:agy_client/agy_client.dart';
import 'package:agy_mobile/state/app_state.dart';
import 'package:agy_mobile/theme/levity_theme.dart';
import 'package:agy_mobile/ui/chat/chat_screen.dart';
import 'package:agy_mobile/ui/home/home_screen.dart';
import 'package:agy_mobile/ui/home/new_session_sheet.dart';
import 'package:agy_mobile/ui/home/quota_card.dart';
import 'package:flutter/material.dart';
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
        theme: buildLevityTheme(),
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
        theme: buildLevityTheme(),
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
          theme: buildLevityTheme(),
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
          theme: buildLevityTheme(),
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
          theme: buildLevityTheme(),
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
        theme: buildLevityTheme(),
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
        theme: buildLevityTheme(),
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
}
