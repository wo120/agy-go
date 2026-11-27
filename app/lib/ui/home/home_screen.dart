import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../theme/agy_theme.dart';
import '../alerts/alerts_screen.dart';
import '../chat/chat_screen.dart';
import '../pairing/pairing_screen.dart';
import '../search/search_screen.dart';
import 'new_session_sheet.dart';
import 'quota_card.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _tabIndex = 0;
  final Set<int> _visitedTabs = {0};

  void _selectTab(int index) {
    if (_tabIndex == index) return;
    setState(() {
      _tabIndex = index;
      _visitedTabs.add(index);
    });
    if (index == 1) {
      ref.read(alertsStateProvider.notifier).clearUnread();
    } else if (index == 2) {
      ref.read(hostConnectionProvider.notifier).verifyConnection();
    }
  }

  @override
  Widget build(BuildContext context) {
    final host = ref.watch(hostConnectionProvider);
    final alerts = ref.watch(alertsStateProvider);

    return Scaffold(
      body: IndexedStack(
        index: _tabIndex,
        children: [
          _SessionsTabView(
            onTapHost: () => _selectTab(2),
            onOpenNewSession: () => _showNewSessionSheet(context, ref),
          ),
          _visitedTabs.contains(1)
              ? const AlertsScreen(embedded: true)
              : const SizedBox.shrink(),
          _visitedTabs.contains(2)
              ? PairingScreen(
                  embedded: true,
                  onPaired: () => _selectTab(0),
                )
              : const SizedBox.shrink(),
        ],
      ),
      floatingActionButton: _tabIndex == 0
          ? FloatingActionButton.extended(
              key: const Key('home_new_session_fab'),
              onPressed: () => _showNewSessionSheet(context, ref),
              backgroundColor: AgyColors.accent,
              foregroundColor: AgyColors.textOnAccent,
              elevation: 0,
              highlightElevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: const BorderSide(color: Color(0x40FFFFFF), width: 0.8),
              ),
              icon: const Icon(Icons.add_rounded, size: 20),
              label: const Text(
                '新对话',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, letterSpacing: 0.1),
              ),
            )
          : null,
      bottomNavigationBar: _AgyBottomDock(
        currentIndex: _tabIndex,
        unreadAlerts: alerts.unreadCount,
        hostState: host,
        onSelect: _selectTab,
      ),
    );
  }

  Future<void> _showNewSessionSheet(BuildContext context, WidgetRef ref) async {
    final carrier = ref.read(hostConnectionProvider.notifier).carrier;
    if (carrier == null) {
      _selectTab(2);
      return;
    }
    if (ref.read(hostConnectionProvider).models.isEmpty) {
      ref.read(hostConnectionProvider.notifier).refreshAll();
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: const Color(0xB8040608),
      builder: (_) {
        return Consumer(
          builder: (_, modalRef, __) {
            final host = modalRef.watch(hostConnectionProvider);
            return NewSessionSheet(
              workspaces: host.workspaces,
              models: host.models,
              onSubmit: ({
                required String prompt,
                required String title,
                required String model,
                String? workspacePath,
              }) async {
                final newId = await carrier.createSession(
                  prompt: prompt,
                  title: title,
                  model: model,
                  workspacePath: workspacePath,
                );
                await ref.read(hostConnectionProvider.notifier).refreshAll();
                if (newId != null && newId.isNotEmpty && context.mounted) {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => ChatScreen(conversationId: newId)),
                  );
                }
              },
            );
          },
        );
      },
    );
  }
}

class _SessionsTabView extends ConsumerWidget {
  const _SessionsTabView({
    required this.onTapHost,
    required this.onOpenNewSession,
  });

  final VoidCallback onTapHost;
  final VoidCallback onOpenNewSession;

  int _countSessions(SessionsUiState sessions) {
    if (sessions.mode == 'project') {
      return sessions.groups.fold<int>(0, (sum, g) => sum + g.sessions.length);
    }
    return sessions.pinned.length + sessions.regular.length;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final host = ref.watch(hostConnectionProvider);
    final sessions = ref.watch(sessionsStateProvider);
    final totalCount = _countSessions(sessions);

    return AgyCanvas(
      child: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          color: AgyColors.accentBright,
          backgroundColor: AgyColors.bgElevated,
          onRefresh: () => ref.read(hostConnectionProvider.notifier).refreshAll(),
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              // Clean industrial brand header
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  child: Row(
                    children: [
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: AgyColors.accentTint,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AgyColors.borderAccent),
                        ),
                        child: const Icon(
                          Icons.terminal_rounded,
                          size: 17,
                          color: AgyColors.accentBright,
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        'AGY Go',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: AgyColors.textPrimary,
                          letterSpacing: -0.4,
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (host.isPaired && !host.desktopOnline)
                        const AgyTag(
                          label: '只读',
                          color: AgyColors.warning,
                          backgroundColor: AgyColors.warningTint,
                          borderColor: Color(0x55F59E0B),
                        ),
                      const Spacer(),
                      AgyIconAction(
                        icon: Icons.search_rounded,
                        tooltip: '搜索全部会话',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const SearchScreen()),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Side-by-side dual-pool telemetry card
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: QuotaDashboardCard(onTapHost: onTapHost),
                ),
              ),

              // Architectural underline tab strip: 桌面顺序 | 按项目
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                  child: Container(
                    decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: AgyColors.borderHairline, width: 1)),
                    ),
                    child: Row(
                      children: [
                        _UnderlineModeTab(
                          label: '桌面顺序',
                          selected: sessions.mode == 'desktop',
                          onTap: () => ref.read(sessionsStateProvider.notifier).setMode('desktop'),
                        ),
                        const SizedBox(width: 20),
                        _UnderlineModeTab(
                          label: '按项目',
                          selected: sessions.mode == 'project',
                          onTap: () => ref.read(sessionsStateProvider.notifier).setMode('project'),
                        ),
                        const Spacer(),
                        if (host.isPaired)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              '$totalCount 会话',
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontFamily: 'monospace',
                                fontFeatures: kTabularFigures,
                                color: AgyColors.textMuted,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),

              if (!host.isPaired)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: ConsolePanel(
                        padding: const EdgeInsets.all(24),
                        borderColor: AgyColors.borderStrong,
                        onTap: onTapHost,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: AgyColors.accentTint,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: AgyColors.borderAccent),
                              ),
                              child: const Icon(
                                Icons.qr_code_scanner_rounded,
                                size: 24,
                                color: AgyColors.accentBright,
                              ),
                            ),
                            const SizedBox(height: 14),
                            const Text(
                              '连接 Mac 端 agy-bridge',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: AgyColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              '在 Mac 终端启动 agy-bridge serve 后扫描二维码，即可通过局域网或 5G 公网同步会话、配额与产物。',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 13, height: 1.45, color: AgyColors.textSecondary),
                            ),
                            const SizedBox(height: 16),
                            FilledButton.icon(
                              onPressed: onTapHost,
                              icon: const Icon(Icons.link_rounded, size: 17),
                              label: const Text('前往配对主机'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                )
              else if (sessions.mode == 'project')
                ..._buildProjectSlivers(context, ref, sessions)
              else
                ..._buildDesktopSlivers(context, ref, sessions),

              const SliverToBoxAdapter(child: SizedBox(height: 88)),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildDesktopSlivers(BuildContext context, WidgetRef ref, SessionsUiState sessions) {
    final slivers = <Widget>[];
    if (sessions.pinned.isNotEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.push_pin_rounded, size: 13.5, color: AgyColors.info),
                const SizedBox(width: 6),
                const Text(
                  '已置顶',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AgyColors.textSecondary),
                ),
                const SizedBox(width: 6),
                Text(
                  '${sessions.pinned.length}',
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontFamily: 'monospace',
                    fontFeatures: kTabularFigures,
                    color: AgyColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverList.separated(
            itemCount: sessions.pinned.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (ctx, idx) => SessionSummaryCard(
              card: sessions.pinned[idx],
              onTap: () => _openChat(ctx, sessions.pinned[idx].conversationId),
              onLongPress: () => ref.read(sessionsStateProvider.notifier).togglePin(sessions.pinned[idx]),
            ),
          ),
        ),
      );
    }

    if (sessions.regular.isNotEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, sessions.pinned.isEmpty ? 4 : 14, 16, 8),
            child: Text(
              sessions.pinned.isEmpty ? '最近对话' : '全部对话',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AgyColors.textMuted),
            ),
          ),
        ),
      );
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverList.separated(
            itemCount: sessions.regular.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (ctx, idx) => SessionSummaryCard(
              card: sessions.regular[idx],
              onTap: () => _openChat(ctx, sessions.regular[idx].conversationId),
              onLongPress: () => ref.read(sessionsStateProvider.notifier).togglePin(sessions.regular[idx]),
            ),
          ),
        ),
      );
    }

    if (sessions.pinned.isEmpty && sessions.regular.isEmpty) {
      slivers.add(
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: 48),
            child: Center(
              child: Text('暂无 Antigravity 会话记录', style: TextStyle(color: AgyColors.textMuted)),
            ),
          ),
        ),
      );
    }
    return slivers;
  }

  List<Widget> _buildProjectSlivers(BuildContext context, WidgetRef ref, SessionsUiState sessions) {
    if (sessions.groups.isEmpty) {
      return const [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: 48),
            child: Center(
              child: Text('暂无 Antigravity 会话记录', style: TextStyle(color: AgyColors.textMuted)),
            ),
          ),
        ),
      ];
    }

    final slivers = <Widget>[];
    for (final group in sessions.groups) {
      final expanded = sessions.isProjectExpanded(group);
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, expanded ? 8 : 4),
            child: ConsolePanel(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              borderRadius: 10,
              backgroundColor: expanded ? AgyColors.bgActive : AgyColors.bgSubtle,
              borderColor: expanded ? AgyColors.borderStrong : AgyColors.borderHairline,
              onTap: () => ref.read(sessionsStateProvider.notifier).toggleProjectExpanded(group),
              child: Row(
                children: [
                  Icon(
                    group.workspace.isGlobal ? Icons.public_rounded : Icons.folder_outlined,
                    size: 16,
                    color: group.workspace.isGlobal ? AgyColors.info : AgyColors.accentBright,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      group.workspace.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: AgyColors.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  AgyTag(
                    label: '${group.sessions.length}',
                    monospace: true,
                    color: AgyColors.textSecondary,
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    size: 18,
                    color: AgyColors.textMuted,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      if (expanded) {
        slivers.add(
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            sliver: SliverList.separated(
              itemCount: group.sessions.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (ctx, idx) => SessionSummaryCard(
                card: group.sessions[idx],
                onTap: () => _openChat(ctx, group.sessions[idx].conversationId),
                onLongPress: () => ref.read(sessionsStateProvider.notifier).togglePin(group.sessions[idx]),
              ),
            ),
          ),
        );
      }
    }
    return slivers;
  }

  void _openChat(BuildContext context, String conversationId) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ChatScreen(conversationId: conversationId)),
    );
  }
}

class _AgyBottomDock extends StatelessWidget {
  const _AgyBottomDock({
    required this.currentIndex,
    required this.unreadAlerts,
    required this.hostState,
    required this.onSelect,
  });

  final int currentIndex;
  final int unreadAlerts;
  final HostConnectionState hostState;
  final ValueChanged<int> onSelect;

  Color get _hostDotColor {
    if (!hostState.isPaired) return AgyColors.textMuted;
    switch (hostState.status) {
      case MuxConnectionStatus.connected:
        return AgyColors.online;
      case MuxConnectionStatus.connecting:
      case MuxConnectionStatus.reconnecting:
        return AgyColors.warning;
      case MuxConnectionStatus.disconnected:
        return AgyColors.danger;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AgyColors.bgDock,
        border: Border(top: BorderSide(color: AgyColors.borderHairline, width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 58,
          child: Row(
            children: [
              Expanded(
                child: _DockItem(
                  key: const Key('nav_tab_sessions'),
                  label: '对话',
                  icon: Icons.chat_bubble_outline_rounded,
                  activeIcon: Icons.chat_bubble_rounded,
                  selected: currentIndex == 0,
                  onTap: () => onSelect(0),
                ),
              ),
              Expanded(
                child: _DockItem(
                  key: const Key('nav_tab_alerts'),
                  label: '提醒',
                  icon: Icons.notifications_none_rounded,
                  activeIcon: Icons.notifications_rounded,
                  selected: currentIndex == 1,
                  badgeCount: unreadAlerts,
                  onTap: () => onSelect(1),
                ),
              ),
              Expanded(
                child: _DockItem(
                  key: const Key('nav_tab_host'),
                  label: '主机',
                  icon: Icons.dns_outlined,
                  activeIcon: Icons.dns_rounded,
                  selected: currentIndex == 2,
                  statusDotColor: _hostDotColor,
                  onTap: () => onSelect(2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DockItem extends StatelessWidget {
  const _DockItem({
    super.key,
    required this.label,
    required this.icon,
    required this.activeIcon,
    required this.selected,
    required this.onTap,
    this.badgeCount = 0,
    this.statusDotColor,
  });

  final String label;
  final IconData icon;
  final IconData activeIcon;
  final bool selected;
  final VoidCallback onTap;
  final int badgeCount;
  final Color? statusDotColor;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? AgyColors.accentBright : AgyColors.textMuted;

    return InkWell(
      onTap: onTap,
      splashColor: AgyColors.accentTint,
      highlightColor: Colors.transparent,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: selected ? 28 : 0,
            height: 2,
            decoration: BoxDecoration(
              color: selected ? AgyColors.accentBright : Colors.transparent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Icon(selected ? activeIcon : icon, size: 21, color: fg),
                    if (badgeCount > 0)
                      Positioned(
                        right: -8,
                        top: -4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4.5, vertical: 1),
                          decoration: BoxDecoration(
                            color: AgyColors.danger,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            badgeCount > 99 ? '99+' : '$badgeCount',
                            style: const TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w700,
                              fontFeatures: kTabularFigures,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      )
                    else if (statusDotColor != null)
                      Positioned(
                        right: -3,
                        top: -1,
                        child: Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: statusDotColor,
                            shape: BoxShape.circle,
                            border: Border.all(color: AgyColors.bgDock, width: 1.2),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _UnderlineModeTab extends StatelessWidget {
  const _UnderlineModeTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? AgyColors.accentBright : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? AgyColors.textPrimary : AgyColors.textMuted,
          ),
        ),
      ),
    );
  }
}

class SessionSummaryCard extends StatelessWidget {
  const SessionSummaryCard({
    super.key,
    required this.card,
    required this.onTap,
    required this.onLongPress,
  });

  final SessionCard card;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  Color? get _stripeColor {
    if (card.needsConfirm) return AgyColors.warning;
    if (card.unread || card.running) return AgyColors.accentBright;
    if (card.pinned) return AgyColors.info;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return ConsolePanel(
      padding: const EdgeInsets.fromLTRB(13, 12, 13, 11),
      accentStripeColor: _stripeColor,
      borderColor: card.needsConfirm
          ? AgyColors.warning.withValues(alpha: 0.4)
          : AgyColors.borderHairline,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (card.pinned)
                const Padding(
                  padding: EdgeInsets.only(right: 6),
                  child: Icon(Icons.push_pin_rounded, size: 13.5, color: AgyColors.info),
                ),
              Expanded(
                child: Text(
                  card.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AgyColors.textPrimary,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                formatSessionTime(card.lastModifiedUnix),
                style: const TextStyle(
                  fontSize: 11.5,
                  fontFamily: 'monospace',
                  fontFeatures: kTabularFigures,
                  color: AgyColors.textMuted,
                ),
              ),
            ],
          ),
          if (card.preview.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              card.preview,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                height: 1.42,
                color: AgyColors.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (card.pendingInteractionCount > 0)
                AgyTag(
                  icon: Icons.verified_user_outlined,
                  label: card.pendingInteractionCount > 1
                      ? '待授权 ×${card.pendingInteractionCount}'
                      : '待授权',
                  color: AgyColors.warning,
                  backgroundColor: AgyColors.warningTint,
                  borderColor: AgyColors.warning.withValues(alpha: 0.45),
                ),
              AgyTag(
                icon: card.workspace.isGlobal ? Icons.public_rounded : Icons.folder_outlined,
                label: card.workspace.label,
                color: AgyColors.textSecondary,
              ),
              if ((card.modelDisplay ?? '').isNotEmpty)
                AgyTag(
                  label: card.modelDisplay!,
                  monospace: true,
                  color: AgyColors.textMuted,
                  backgroundColor: Colors.transparent,
                ),
              if (card.subagentCount > 0)
                AgyTag(
                  icon: Icons.account_tree_outlined,
                  label: '${card.subagentCount} 子代理',
                  color: AgyColors.info,
                  backgroundColor: AgyColors.infoTint,
                  borderColor: AgyColors.info.withValues(alpha: 0.3),
                ),
              if (card.artifactCount > 0)
                AgyTag(
                  icon: Icons.description_outlined,
                  label: '${card.artifactCount} 产物',
                  color: AgyColors.accentBright,
                  backgroundColor: AgyColors.accentTint,
                  borderColor: AgyColors.borderAccent,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
