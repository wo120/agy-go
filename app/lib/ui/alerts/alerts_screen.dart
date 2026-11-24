import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../theme/levity_theme.dart';
import '../chat/chat_screen.dart';

class AlertsScreen extends ConsumerWidget {
  const AlertsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alerts = ref.watch(alertsStateProvider).alerts;

    return Scaffold(
      appBar: AppBar(title: const Text('通知中心')),
      body: LevityBackground(
        child: alerts.isEmpty
            ? const Center(
                child: Text('暂无待确认或已完成提醒', style: TextStyle(color: LevityColors.textMuted)),
              )
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: alerts.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (ctx, idx) {
                  final al = alerts[idx];
                  final isConfirm = al.kind == 'NEED_CONFIRM';
                  return GlassCard(
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => ChatScreen(conversationId: al.conversationId)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              isConfirm ? Icons.bolt_rounded : Icons.check_circle_outline_rounded,
                              size: 16,
                              color: isConfirm ? LevityColors.orangeWarning : LevityColors.greenDirect,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                al.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: LevityColors.textPrimary),
                              ),
                            ),
                            Text(formatSessionTime(al.createdAt), style: const TextStyle(fontSize: 11.5, color: LevityColors.textMuted)),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(al.body, style: const TextStyle(fontSize: 13, color: LevityColors.textSecondary)),
                        if (al.quickReplies.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            children: [
                              for (final qr in al.quickReplies)
                                FilledButton.tonal(
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
                                  child: Text(qr, style: const TextStyle(fontSize: 12)),
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
    );
  }
}
