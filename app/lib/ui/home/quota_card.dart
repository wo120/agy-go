import 'dart:async';

import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../theme/levity_theme.dart';

class QuotaDashboardCard extends ConsumerStatefulWidget {
  const QuotaDashboardCard({super.key, required this.onTapHost});

  final VoidCallback onTapHost;

  @override
  ConsumerState<QuotaDashboardCard> createState() => _QuotaDashboardCardState();
}

class _QuotaDashboardCardState extends ConsumerState<QuotaDashboardCard> {
  Timer? _tickTimer;

  @override
  void initState() {
    super.initState();
    _tickTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    super.dispose();
  }

  Color _statusDotColor(HostConnectionState host) {
    if (!host.isPaired) return LevityColors.textMuted;
    switch (host.status) {
      case MuxConnectionStatus.connected:
        return LevityColors.greenDirect;
      case MuxConnectionStatus.connecting:
      case MuxConnectionStatus.reconnecting:
        return LevityColors.orangeWarning;
      case MuxConnectionStatus.disconnected:
        return const Color(0xFFF87171);
    }
  }

  @override
  Widget build(BuildContext context) {
    final host = ref.watch(hostConnectionProvider);
    final quotaUi = ref.watch(quotaStateProvider);
    final snap = quotaUi.snapshot;

    final pools = snap?.pools ??
        const [
          PoolQuota(
            poolId: 'gemini',
            displayName: 'Gemini',
            remaining5hPct: 100,
            reset5hAt: null,
            remaining7dPct: 100,
            reset7dAt: null,
            level: 'full',
            source: 'ledger',
          ),
          PoolQuota(
            poolId: 'claude_gpt',
            displayName: 'Claude · GPT',
            remaining5hPct: 100,
            reset5hAt: null,
            remaining7dPct: 100,
            reset7dAt: null,
            level: 'full',
            source: 'ledger',
          ),
        ];

    return GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: widget.onTapHost,
                  behavior: HitTestBehavior.opaque,
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: _statusDotColor(host),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: _statusDotColor(host).withValues(alpha: 0.6),
                              blurRadius: 6,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          host.connectionBanner,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: LevityColors.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => ref.read(quotaStateProvider.notifier).toggleCollapsed(),
                behavior: HitTestBehavior.opaque,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      snap?.subscriptionTier ?? 'Google AI Ultra',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: LevityColors.textSecondary,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      quotaUi.collapsed ? Icons.keyboard_arrow_down_rounded : Icons.keyboard_arrow_up_rounded,
                      size: 18,
                      color: LevityColors.textSecondary,
                    ),
                  ],
                ),
              ),
            ],
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 220),
            crossFadeState: quotaUi.collapsed ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            secondChild: const SizedBox.shrink(),
            firstChild: Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Column(
                children: [
                  for (var i = 0; i < pools.length; i++) ...[
                    if (i > 0) const SizedBox(height: 14),
                    _PoolQuotaSection(
                      pool: pools[i],
                      onLongPress: host.isPaired ? () => _showCalibrateSheet(context, pools[i]) : null,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showCalibrateSheet(BuildContext context, PoolQuota pool) async {
    double rem5 = pool.remaining5hPct.toDouble();
    double rem7 = pool.remaining7dPct.toDouble();

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF17192C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('校准 ${pool.displayName} 配额基准', style: Theme.of(ctx).textTheme.titleMedium),
                  const SizedBox(height: 6),
                  const Text(
                    '对照桌面端当前剩余百分比微调，桥接端会自动反推窗口容量并持续滑动计算。',
                    style: TextStyle(fontSize: 12, color: LevityColors.textSecondary),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('5h 剩余额度', style: TextStyle(color: LevityColors.textPrimary)),
                      Text('${rem5.round()}%', style: const TextStyle(fontWeight: FontWeight.w600)),
                    ],
                  ),
                  Slider(
                    value: rem5,
                    min: 0,
                    max: 100,
                    divisions: 100,
                    onChanged: (v) => setModalState(() => rem5 = v),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('7d 剩余额度', style: TextStyle(color: LevityColors.textPrimary)),
                      Text('${rem7.round()}%', style: const TextStyle(fontWeight: FontWeight.w600)),
                    ],
                  ),
                  Slider(
                    value: rem7,
                    min: 0,
                    max: 100,
                    divisions: 100,
                    onChanged: (v) => setModalState(() => rem7 = v),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () async {
                        Navigator.of(ctx).pop();
                        await ref.read(quotaStateProvider.notifier).calibrate(
                              poolId: pool.poolId,
                              remaining5hPct: rem5,
                              remaining7dPct: rem7,
                            );
                      },
                      child: const Text('保存校准'),
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

class _PoolQuotaSection extends StatelessWidget {
  const _PoolQuotaSection({required this.pool, this.onLongPress});

  final PoolQuota pool;
  final VoidCallback? onLongPress;

  Color get _dotColor {
    switch (pool.level) {
      case 'full':
        return LevityColors.greenDirect;
      case 'warning':
        return LevityColors.orangeWarning;
      default:
        return LevityColors.textPrimary;
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: _dotColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(
                pool.displayName,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: LevityColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _QuotaBarRow(
            label: '5h',
            pct: pool.remaining5hPct,
            resetLabel: formatResetCountdown(pool.reset5hAt, pool.remaining5hPct),
          ),
          const SizedBox(height: 7),
          _QuotaBarRow(
            label: '7d',
            pct: pool.remaining7dPct,
            resetLabel: formatResetCountdown(pool.reset7dAt, pool.remaining7dPct),
          ),
        ],
      ),
    );
  }
}

class _QuotaBarRow extends StatelessWidget {
  const _QuotaBarRow({
    required this.label,
    required this.pct,
    required this.resetLabel,
  });

  final String label;
  final int pct;
  final String resetLabel;

  @override
  Widget build(BuildContext context) {
    final isWarning = pct < 40;
    final barColor = isWarning ? LevityColors.orangeWarning : const Color(0xFFE5E7F0);
    final pctColor = isWarning ? LevityColors.orangeWarning : LevityColors.textPrimary;

    return Row(
      children: [
        SizedBox(
          width: 24,
          child: Text(label, style: const TextStyle(fontSize: 12, color: LevityColors.textMuted)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: (pct.clamp(0, 100)) / 100.0,
              minHeight: 4.5,
              backgroundColor: LevityColors.barTrack,
              valueColor: AlwaysStoppedAnimation<Color>(barColor),
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 38,
          child: Text(
            '$pct%',
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: pctColor),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 86,
          child: Text(
            resetLabel,
            textAlign: TextAlign.right,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5, color: LevityColors.textMuted),
          ),
        ),
      ],
    );
  }
}
