import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../theme/levity_theme.dart';
import '../alerts/alerts_screen.dart';
import '../chat/chat_screen.dart';
import '../pairing/pairing_screen.dart';
import '../search/search_screen.dart';
import 'quota_card.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final host = ref.watch(hostConnectionProvider);
    final sessions = ref.watch(sessionsStateProvider);
    final alerts = ref.watch(alertsStateProvider);

    return Scaffold(
      body: LevityBackground(
        child: SafeArea(
          child: RefreshIndicator(
            color: LevityColors.purpleSubagent,
            backgroundColor: const Color(0xFF1A1C2E),
            onRefresh: () => ref.read(hostConnectionProvider.notifier).refreshAll(),
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                // Top left & right translucent glass capsules
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        GlassCapsule(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _CapsuleIconButton(
                                icon: Icons.podcasts_rounded,
                                color: host.status == MuxConnectionStatus.connected
                                    ? LevityColors.greenDirect
                                    : LevityColors.textSecondary,
                                tooltip: '主机连接与扫码配对',
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute(builder: (_) => const PairingScreen()),
                                ),
                              ),
                              const SizedBox(width: 4),
                              Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  _CapsuleIconButton(
                                    icon: Icons.notifications_rounded,
                                    color: LevityColors.greenDirect,
                                    tooltip: '通知中心',
                                    onTap: () {
                                      ref.read(alertsStateProvider.notifier).clearUnread();
                                      Navigator.of(context).push(
                                        MaterialPageRoute(builder: (_) => const AlertsScreen()),
                                      );
                                    },
                                  ),
                                  if (alerts.unreadCount > 0)
                                    Positioned(
                                      right: 6,
                                      top: 6,
                                      child: Container(
                                        width: 8,
                                        height: 8,
                                        decoration: const BoxDecoration(
                                          color: Color(0xFFEF4444),
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        GlassCapsule(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _CapsuleIconButton(
                                icon: Icons.search_rounded,
                                color: LevityColors.textPrimary,
                                tooltip: '搜索全部会话',
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute(builder: (_) => const SearchScreen()),
                                ),
                              ),
                              const SizedBox(width: 4),
                              _CapsuleIconButton(
                                icon: Icons.add_comment_rounded,
                                color: LevityColors.textPrimary,
                                tooltip: '新建 Antigravity 会话',
                                onTap: () => _showNewSessionSheet(context, ref),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Collapsible Host + 5h/7d Quota Dashboard Card
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: QuotaDashboardCard(
                      onTapHost: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const PairingScreen()),
                      ),
                    ),
                  ),
                ),

                // Segmented view toggle: [桌面顺序] | [按项目]
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: LevityColors.capsuleFill,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: LevityColors.cardBorder),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _ModeChip(
                                label: '桌面顺序',
                                selected: sessions.mode == 'desktop',
                                onTap: () => ref.read(sessionsStateProvider.notifier).setMode('desktop'),
                              ),
                              _ModeChip(
                                label: '按项目',
                                selected: sessions.mode == 'project',
                                onTap: () => ref.read(sessionsStateProvider.notifier).setMode('project'),
                              ),
                            ],
                          ),
                        ),
                        if (host.isPaired && !host.desktopOnline) ...[
                          const SizedBox(width: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0x33F59E0B),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: const Text(
                              '桌面端只读模式',
                              style: TextStyle(fontSize: 11, color: LevityColors.orangeWarning),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                if (!host.isPaired)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: GlassCard(
                          padding: const EdgeInsets.all(24),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const PairingScreen()),
                          ),
                          child: const Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.qr_code_scanner_rounded, size: 42, color: LevityColors.purpleSubagent),
                              SizedBox(height: 12),
                              Text('扫码连接 Mac 端 agy-bridge', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                              SizedBox(height: 6),
                              Text(
                                '在 Mac 终端运行 agy-bridge serve 后扫描二维码，即可通过局域网或 Tailscale 直连同步会话、配额与产物。',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 13, color: LevityColors.textSecondary),
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

                const SliverToBoxAdapter(child: SizedBox(height: 36)),
              ],
            ),
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
            padding: const EdgeInsets.fromLTRB(18, 6, 18, 8),
            child: Row(
              children: [
                const Icon(Icons.push_pin_rounded, size: 15, color: LevityColors.purpleSubagent),
                const SizedBox(width: 6),
                const Text('已置顶', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: LevityColors.textPrimary)),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
                  decoration: BoxDecoration(
                    color: LevityColors.capsuleFill,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text('${sessions.pinned.length}', style: const TextStyle(fontSize: 11, color: LevityColors.textSecondary)),
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
            separatorBuilder: (_, __) => const SizedBox(height: 10),
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
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
            child: Text(
              sessions.pinned.isEmpty ? '最近对话' : '全部对话',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: LevityColors.textSecondary),
            ),
          ),
        ),
      );
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverList.separated(
            itemCount: sessions.regular.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
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
              child: Text('暂无 Antigravity 会话记录', style: TextStyle(color: LevityColors.textMuted)),
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
              child: Text('暂无 Antigravity 会话记录', style: TextStyle(color: LevityColors.textMuted)),
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
            padding: EdgeInsets.fromLTRB(16, 6, 16, expanded ? 8 : 4),
            child: GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              borderRadius: 14,
              onTap: () => ref.read(sessionsStateProvider.notifier).toggleProjectExpanded(group),
              child: Row(
                children: [
                  Icon(
                    group.workspace.isGlobal ? Icons.public_rounded : Icons.folder_outlined,
                    size: 16,
                    color: LevityColors.purpleSubagent,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      group.workspace.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: LevityColors.textPrimary),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('${group.sessions.length}', style: const TextStyle(fontSize: 12, color: LevityColors.textMuted)),
                  const SizedBox(width: 6),
                  Icon(
                    expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    size: 18,
                    color: LevityColors.textMuted,
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
              separatorBuilder: (_, __) => const SizedBox(height: 10),
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

  Future<void> _showNewSessionSheet(BuildContext context, WidgetRef ref) async {
    final host = ref.read(hostConnectionProvider);
    final carrier = ref.read(hostConnectionProvider.notifier).carrier;
    if (carrier == null) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PairingScreen()));
      return;
    }

    final promptCtrl = TextEditingController();
    final titleCtrl = TextEditingController();
    String? selectedWorkspacePath;
    String selectedModel = 'pro';

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF17192C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Padding(
              padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('发起新的 Antigravity 对话', style: Theme.of(ctx).textTheme.titleMedium),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String?>(
                    initialValue: selectedWorkspacePath,
                    dropdownColor: const Color(0xFF1F2238),
                    decoration: const InputDecoration(
                      labelText: '目标工作区',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('🌐 通用对话（无代码库）')),
                      for (final ws in host.workspaces)
                        DropdownMenuItem<String?>(value: ws.rootPath, child: Text('📁 ${ws.label}')),
                    ],
                    onChanged: (v) => setModalState(() => selectedWorkspacePath = v),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: selectedModel,
                    dropdownColor: const Color(0xFF1F2238),
                    decoration: const InputDecoration(
                      labelText: '模型档位',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'pro', child: Text('Pro（复杂任务推荐）')),
                      DropdownMenuItem(value: 'flash', child: Text('Flash（快速响应）')),
                      DropdownMenuItem(value: 'flash_lite', child: Text('Flash Lite（轻量）')),
                    ],
                    onChanged: (v) => setModalState(() => selectedModel = v ?? 'pro'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: titleCtrl,
                    decoration: const InputDecoration(
                      labelText: '标题（可选）',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: promptCtrl,
                    minLines: 2,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      labelText: '输入指令或需求',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () async {
                        final text = promptCtrl.text.trim();
                        if (text.isEmpty) return;
                        Navigator.of(ctx).pop();
                        try {
                          final newId = await carrier.createSession(
                            prompt: text,
                            title: titleCtrl.text.trim(),
                            model: selectedModel,
                            workspacePath: selectedWorkspacePath,
                          );
                          await ref.read(hostConnectionProvider.notifier).refreshAll();
                          if (newId != null && newId.isNotEmpty && context.mounted) {
                            _openChat(context, newId);
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('新建失败：$e')),
                            );
                          }
                        }
                      },
                      child: const Text('发送到 Mac 执行'),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
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

  @override
  Widget build(BuildContext context) {
    final showBlueDot = card.unread || card.running || card.needsConfirm;

    return GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 13),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (showBlueDot)
                Container(
                  width: 7,
                  height: 7,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: card.needsConfirm ? LevityColors.orangeWarning : LevityColors.blueUnread,
                    shape: BoxShape.circle,
                  ),
                )
              else if (card.pinned)
                const Padding(
                  padding: EdgeInsets.only(right: 6),
                  child: Icon(Icons.push_pin_rounded, size: 14, color: LevityColors.purpleSubagent),
                ),
              Expanded(
                child: Text(
                  card.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    color: LevityColors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                formatSessionTime(card.lastModifiedUnix),
                style: const TextStyle(fontSize: 12, color: LevityColors.textMuted),
              ),
            ],
          ),
          if (card.preview.isNotEmpty) ...[
            const SizedBox(height: 7),
            Text(
              card.preview,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13.2,
                height: 1.42,
                color: LevityColors.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: 11),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _MetaChip(
                icon: card.workspace.isGlobal ? Icons.public_rounded : Icons.folder_outlined,
                label: card.workspace.label,
                color: LevityColors.textMuted,
              ),
              if ((card.modelDisplay ?? '').isNotEmpty)
                Text(
                  card.modelDisplay!,
                  style: const TextStyle(fontSize: 12, color: LevityColors.textMuted),
                ),
              if (card.subagentCount > 0)
                _MetaChip(
                  icon: Icons.account_tree_outlined,
                  label: '${card.subagentCount} 子代理',
                  color: LevityColors.purpleSubagent,
                ),
              if (card.artifactCount > 0)
                _MetaChip(
                  icon: Icons.description_outlined,
                  label: '${card.artifactCount} 产物',
                  color: LevityColors.slateArtifact,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13.5, color: color),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 12, color: color)),
      ],
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? LevityColors.capsuleActive : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? LevityColors.textPrimary : LevityColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _CapsuleIconButton extends StatelessWidget {
  const _CapsuleIconButton({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, size: 20, color: color),
    );
  }
}
