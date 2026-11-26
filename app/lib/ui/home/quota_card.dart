import 'dart:async';

import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../theme/agy_theme.dart';

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
    if (!host.isPaired) return AgyColors.textMuted;
    switch (host.status) {
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
    final host = ref.watch(hostConnectionProvider);
    final quotaUi = ref.watch(quotaStateProvider);
    final tpsSnap = ref.watch(tpsStateProvider).snapshot;
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

    return ConsolePanel(
      padding: const EdgeInsets.all(12),
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
                      AgyStatusDot(color: _statusDotColor(host), size: 7),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          host.connectionBanner,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            fontFeatures: kTabularFigures,
                            color: AgyColors.textPrimary,
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
                    AgyTag(
                      label: snap?.subscriptionTier ?? '同步订阅中...',
                      color: AgyColors.accentBright,
                      backgroundColor: AgyColors.accentTint,
                      borderColor: AgyColors.borderAccent,
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      quotaUi.collapsed ? Icons.keyboard_arrow_down_rounded : Icons.keyboard_arrow_up_rounded,
                      size: 18,
                      color: AgyColors.textSecondary,
                    ),
                  ],
                ),
              ),
            ],
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 200),
            crossFadeState: quotaUi.collapsed ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            secondChild: const SizedBox.shrink(),
            firstChild: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Column(
                children: [
                  _buildDualPoolGrid(context, host, pools),
                  if (tpsSnap != null && tpsSnap.hasData) ...[
                    const SizedBox(height: 8),
                    _TpsTelemetryStrip(
                      snapshot: tpsSnap,
                      onTap: () => _showTpsDetailSheet(context, tpsSnap),
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

  Widget _buildDualPoolGrid(BuildContext context, HostConnectionState host, List<PoolQuota> pools) {
    final rows = <Widget>[];
    for (var i = 0; i < pools.length; i += 2) {
      if (i > 0) rows.add(const SizedBox(height: 8));
      final left = pools[i];
      final right = i + 1 < pools.length ? pools[i + 1] : null;
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _PoolTelemetryTile(
                  pool: left,
                  onLongPress: host.isPaired ? () => _showCalibrateSheet(context, left) : null,
                ),
              ),
              if (right != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: _PoolTelemetryTile(
                    pool: right,
                    onLongPress: host.isPaired ? () => _showCalibrateSheet(context, right) : null,
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return Column(children: rows);
  }

  Future<void> _showCalibrateSheet(BuildContext context, PoolQuota pool) async {
    double rem5 = pool.remaining5hPct.toDouble();
    double rem7 = pool.remaining7dPct.toDouble();

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AgyColors.bgDock,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: AgyColors.borderStrong),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 14),
                      decoration: BoxDecoration(
                        color: AgyColors.borderStrong,
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                  Text('校准 ${pool.displayName} 配额基准', style: Theme.of(ctx).textTheme.titleMedium),
                  const SizedBox(height: 6),
                  const Text(
                    '对照桌面端当前剩余百分比微调，桥接端会自动反推窗口容量并持续滑动计算。',
                    style: TextStyle(fontSize: 12, color: AgyColors.textSecondary),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('5h 剩余额度', style: TextStyle(color: AgyColors.textPrimary)),
                      Text(
                        '${rem5.round()}%',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontFeatures: kTabularFigures,
                          color: AgyColors.accentBright,
                        ),
                      ),
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
                      const Text('7d 剩余额度', style: TextStyle(color: AgyColors.textPrimary)),
                      Text(
                        '${rem7.round()}%',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontFeatures: kTabularFigures,
                          color: AgyColors.accentBright,
                        ),
                      ),
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
                    height: 44,
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

  Future<void> _showTpsDetailSheet(BuildContext context, TpsSnapshot snap) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AgyColors.bgDock,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: AgyColors.borderStrong),
      ),
      builder: (ctx) {
        final maxRate = snap.models.fold<double>(1.0, (acc, m) {
          final v = m.streamTps > 0 ? m.streamTps : m.e2eTps;
          return v > acc ? v : acc;
        });
        return SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: AgyColors.borderStrong,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                Row(
                  children: [
                    const Icon(Icons.bolt_rounded, size: 18, color: AgyColors.online),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '输出速度监控 (TPS · 5h)',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(ctx).textTheme.titleMedium,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      flex: 0,
                      child: AgyTag(
                        label: '${snap.sampleCount} 轮 · ${_fmtCompactTokens(snap.outputTokens)} tok',
                        monospace: true,
                        color: AgyColors.textSecondary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _TpsKpiBox(
                        label: '流式 TPS',
                        value: snap.streamTps > 0 ? snap.streamTps.toStringAsFixed(1) : '--',
                        unit: 'tok/s',
                        accent: AgyColors.online,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _TpsKpiBox(
                        label: '端到端 E2E',
                        value: snap.e2eTps > 0 ? snap.e2eTps.toStringAsFixed(1) : '--',
                        unit: 'tok/s',
                        accent: AgyColors.info,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _TpsKpiBox(
                        label: '平均 TTFT',
                        value: _fmtTtft(snap.avgTtftMs),
                        unit: '',
                        accent: AgyColors.textPrimary,
                      ),
                    ),
                  ],
                ),
                if (snap.latest != null) ...[
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: AgyColors.onlineTint,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: AgyColors.online.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '最近一轮 · ${snap.latest!.modelDisplay}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AgyColors.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          flex: 0,
                          child: Text(
                            '${_fmtTurnRate(snap.latest!)} · TTFT ${_fmtTtft(snap.latest!.ttftMs)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w700,
                              fontFeatures: kTabularFigures,
                              color: AgyColors.online,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (snap.models.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  const Text(
                    '近 5h 分模型速度',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AgyColors.textSecondary),
                  ),
                  const SizedBox(height: 8),
                  for (final m in snap.models.take(6)) ...[
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  m.modelDisplay,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    color: AgyColors.textPrimary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                m.streamTps > 0
                                    ? '${m.streamTps.toStringAsFixed(1)} tok/s'
                                    : 'E2E ${m.e2eTps.toStringAsFixed(1)} tok/s',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.w700,
                                  fontFeatures: kTabularFigures,
                                  color: AgyColors.accentBright,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          _MicroGaugeBar(
                            pct: (((m.streamTps > 0 ? m.streamTps : m.e2eTps) / maxRate) * 100).round().clamp(6, 100),
                            fillColor: m.poolId == 'gemini' ? AgyColors.info : AgyColors.accentBright,
                            height: 4,
                          ),
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'E2E ${m.e2eTps.toStringAsFixed(1)} · TTFT ${_fmtTtft(m.avgTtftMs)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                    fontFeatures: kTabularFigures,
                                    color: AgyColors.textMuted,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '${_fmtCompactTokens(m.outputTokens)} tok · ${m.sampleCount} 轮',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontFamily: 'monospace',
                                  fontFeatures: kTabularFigures,
                                  color: AgyColors.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _PoolTelemetryTile extends StatelessWidget {
  const _PoolTelemetryTile({required this.pool, this.onLongPress});

  final PoolQuota pool;
  final VoidCallback? onLongPress;

  Color get _poolColor {
    if (pool.level == 'warning') return AgyColors.warning;
    if (pool.poolId == 'gemini') return AgyColors.info;
    return AgyColors.accentBright;
  }

  @override
  Widget build(BuildContext context) {
    final warn5h = pool.remaining5hPct < 40;
    final warn7d = pool.remaining7dPct < 40;
    final color5h = warn5h ? AgyColors.warning : _poolColor;
    final color7d = warn7d ? AgyColors.warning : AgyColors.textSecondary;

    final reset5h = formatResetCountdown(pool.reset5hAt, pool.remaining5hPct);
    final reset7d = formatResetCountdown(pool.reset7dAt, pool.remaining7dPct);

    return GestureDetector(
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AgyColors.bgSubtle,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: warn5h ? AgyColors.warning.withValues(alpha: 0.35) : AgyColors.borderHairline,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Pool title + indicator square
            Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: _poolColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    pool.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AgyColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // 5h primary readout
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  '${pool.remaining5hPct}%',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    fontFeatures: kTabularFigures,
                    color: warn5h ? AgyColors.warning : AgyColors.textPrimary,
                    letterSpacing: -0.4,
                  ),
                ),
                const SizedBox(width: 5),
                const Text(
                  '5h',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'monospace',
                    color: AgyColors.textMuted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            _MicroGaugeBar(pct: pool.remaining5hPct, fillColor: color5h, height: 4),
            const SizedBox(height: 4),
            Text(
              reset5h,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 10.5,
                fontFeatures: kTabularFigures,
                color: AgyColors.textMuted,
              ),
            ),
            const SizedBox(height: 8),

            // 7d secondary row
            Row(
              children: [
                const Text(
                  '7d',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontFamily: 'monospace',
                    color: AgyColors.textMuted,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _MicroGaugeBar(pct: pool.remaining7dPct, fillColor: color7d, height: 3),
                ),
                const SizedBox(width: 6),
                Text(
                  '${pool.remaining7dPct}%',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    fontFeatures: kTabularFigures,
                    color: warn7d ? AgyColors.warning : AgyColors.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              reset7d,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 10.5,
                fontFeatures: kTabularFigures,
                color: AgyColors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MicroGaugeBar extends StatelessWidget {
  const _MicroGaugeBar({
    required this.pct,
    required this.fillColor,
    this.height = 4,
  });

  final int pct;
  final Color fillColor;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: LinearProgressIndicator(
        value: pct.clamp(0, 100) / 100.0,
        minHeight: height,
        backgroundColor: AgyColors.barTrack,
        valueColor: AlwaysStoppedAnimation<Color>(fillColor),
      ),
    );
  }
}

class _TpsTelemetryStrip extends StatelessWidget {
  const _TpsTelemetryStrip({
    required this.snapshot,
    required this.onTap,
  });

  final TpsSnapshot snapshot;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final primaryValue = snapshot.streamTps > 0
        ? '${snapshot.streamTps.toStringAsFixed(1)} tok/s'
        : snapshot.e2eTps > 0
            ? 'E2E ${snapshot.e2eTps.toStringAsFixed(1)} tok/s'
            : (snapshot.latest != null ? _fmtTurnRate(snapshot.latest!) : '--');
    final latest = snapshot.latest;
    final subRight = snapshot.sampleCount > 0
        ? 'E2E ${snapshot.e2eTps.toStringAsFixed(1)} · TTFT ${_fmtTtft(snapshot.avgTtftMs)}'
        : (latest != null ? 'TTFT ${_fmtTtft(latest.ttftMs)}' : '');

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        key: const Key('quota_tps_strip'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        splashColor: AgyColors.accentTint,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: AgyColors.bgSubtle,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AgyColors.borderHairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.bolt_rounded, size: 14, color: AgyColors.online),
                  const SizedBox(width: 4),
                  const Text(
                    '5h 均速',
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AgyColors.textSecondary),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    primaryValue,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'monospace',
                      fontFeatures: kTabularFigures,
                      color: AgyColors.online,
                    ),
                  ),
                  const Spacer(),
                  if (subRight.isNotEmpty)
                    Flexible(
                      child: Text(
                        subRight,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10.5,
                          fontFamily: 'monospace',
                          fontFeatures: kTabularFigures,
                          color: AgyColors.textMuted,
                        ),
                      ),
                    ),
                  const SizedBox(width: 2),
                  const Icon(Icons.chevron_right_rounded, size: 15, color: AgyColors.textMuted),
                ],
              ),
              if (latest != null) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '最近：${latest.modelDisplay}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10.5, color: AgyColors.textMuted),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _fmtTurnRate(latest),
                      style: const TextStyle(
                        fontSize: 10.5,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600,
                        fontFeatures: kTabularFigures,
                        color: AgyColors.accentBright,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TpsKpiBox extends StatelessWidget {
  const _TpsKpiBox({
    required this.label,
    required this.value,
    required this.unit,
    required this.accent,
  });

  final String label;
  final String value;
  final String unit;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: AgyColors.bgSubtle,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AgyColors.borderHairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: AgyColors.textMuted)),
          const SizedBox(height: 3),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'monospace',
                    fontFeatures: kTabularFigures,
                    color: accent,
                  ),
                ),
              ),
              if (unit.isNotEmpty) ...[
                const SizedBox(width: 2),
                Text(unit, style: const TextStyle(fontSize: 10, color: AgyColors.textMuted)),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

String _fmtTtft(int ms) {
  if (ms <= 0) return '--';
  if (ms < 1000) return '${ms}ms';
  return '${(ms / 1000.0).toStringAsFixed(1)}s';
}

String _fmtCompactTokens(int n) {
  if (n <= 0) return '0';
  if (n >= 1000000) return '${(n / 1000000.0).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000.0).toStringAsFixed(1)}k';
  return '$n';
}

String _fmtTurnRate(TpsTurn turn) {
  if (turn.streamTps > 0) return '${turn.streamTps.toStringAsFixed(1)} tok/s';
  if (turn.e2eTps > 0) return 'E2E ${turn.e2eTps.toStringAsFixed(1)} tok/s';
  return '--';
}
