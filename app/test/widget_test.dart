import 'package:agy_client/agy_client.dart';
import 'package:agy_mobile/state/app_state.dart';
import 'package:agy_mobile/theme/levity_theme.dart';
import 'package:agy_mobile/ui/home/home_screen.dart';
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
}
