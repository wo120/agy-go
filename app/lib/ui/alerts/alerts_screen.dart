import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../theme/agy_theme.dart';
import '../chat/chat_screen.dart';

class AlertsScreen extends ConsumerWidget {
  const AlertsScreen({super.key, this.embedded = false});

  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alerts = ref.watch(alertsStateProvider).alerts;

    final body = Column(
      children: [
        if (embedded)
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            decoration: const BoxDecoration(
              color: AgyColors.bgDock,
              border: Border(bottom: BorderSide(color: AgyColors.borderHairline)),
            ),
            child: Row(
              children: [
                const Icon(Icons.notifications_active_outlined, size: 19, color: AgyColors.accentBright),
                const SizedBox(width: 8),
                const Text(
                  '提醒中心',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: AgyColors.textPrimary,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(width: 8),
                AgyTag(
                  label: '${alerts.length}',
                  color: alerts.isEmpty ? AgyColors.textMuted : AgyColors.accentBright,
                  backgroundColor: alerts.isEmpty ? AgyColors.bgSubtle : AgyColors.accentTint,
                  borderColor: alerts.isEmpty ? AgyColors.borderHairline : AgyColors.borderAccent,
                ),
              ],
            ),
          ),
        Expanded(
          child: alerts.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: ConsolePanel(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: AgyColors.bgSubtle,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: AgyColors.borderHairline),
                            ),
                            child: const Icon(Icons.check_circle_outline_rounded, size: 22, color: AgyColors.textMuted),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            '暂无待确认或已完成提醒',
                            style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: AgyColors.textPrimary),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            '当 Mac 端 Agent 完成任务或等待决策时，会在此即时汇总',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 12.5, color: AgyColors.textMuted),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                  itemCount: alerts.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (ctx, idx) {
                    final al = alerts[idx];
                    final isConfirm = al.kind == 'NEED_CONFIRM';
                    final semanticColor = isConfirm ? AgyColors.warning : AgyColors.online;

                    return ConsolePanel(
                      accentStripeColor: semanticColor,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => ChatScreen(conversationId: al.conversationId)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              AgyTag(
                                label: isConfirm ? '待确认' : '已完成',
                                icon: isConfirm ? Icons.bolt_rounded : Icons.check_rounded,
                                color: semanticColor,
                                backgroundColor: isConfirm ? AgyColors.warningTint : AgyColors.onlineTint,
                                borderColor: semanticColor.withValues(alpha: 0.35),
                              ),
                              const Spacer(),
                              Text(
                                formatSessionTime(al.createdAt),
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  fontFamily: 'monospace',
                                  fontFeatures: kTabularFigures,
                                  color: AgyColors.textMuted,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            al.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700,
                              color: AgyColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            al.body,
                            style: const TextStyle(fontSize: 13, height: 1.45, color: AgyColors.textSecondary),
                          ),
                          if (al.quickReplies.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final qr in al.quickReplies)
                                  OutlinedButton(
                                    style: OutlinedButton.styleFrom(
                                      visualDensity: VisualDensity.compact,
                                      backgroundColor: AgyColors.bgSubtle,
                                      side: const BorderSide(color: AgyColors.borderAccent),
                                      foregroundColor: AgyColors.accentBright,
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    ),
                                    onPressed: () async {
                                      final c = ref.read(hostConnectionProvider.notifier).carrier;
                                      if (c != null) {
                                        await c.sendMessage(al.conversationId, qr);
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(content: Text('已回复「$qr」')),
                                          );
                                        }
                                      }
                                    },
                                    child: Text(qr, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                                  ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );

    if (embedded) {
      return AgyCanvas(child: SafeArea(bottom: false, child: body));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('提醒中心'),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: AgyColors.borderHairline),
        ),
      ),
      body: AgyCanvas(child: body),
    );
  }
}
