import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../state/app_state.dart';
import '../../state/native_bridge.dart';
import '../../theme/agy_theme.dart';

class PairingScreen extends ConsumerStatefulWidget {
  const PairingScreen({super.key, this.embedded = false, this.onPaired});

  final bool embedded;
  final VoidCallback? onPaired;

  @override
  ConsumerState<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends ConsumerState<PairingScreen> {
  final TextEditingController _jsonCtrl = TextEditingController();
  final TextEditingController _endpointCtrl = TextEditingController();
  final TextEditingController _tokenCtrl = TextEditingController();
  final TextEditingController _hostCtrl = TextEditingController(text: 'ClawStation');
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    if (!widget.embedded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(hostConnectionProvider.notifier).verifyConnection();
        }
      });
    }
  }

  @override
  void dispose() {
    _jsonCtrl.dispose();
    _endpointCtrl.dispose();
    _tokenCtrl.dispose();
    _hostCtrl.dispose();
    super.dispose();
  }

  Future<void> _applyPayload(PairingPayload payload) async {
    await ref.read(hostConnectionProvider.notifier).connectWithPairing(payload);
    await NativeBridge.instance.requestPermissions();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已配对主机 ${payload.hostName}')),
    );
    if (widget.embedded) {
      widget.onPaired?.call();
    } else if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  InputDecoration _consoleInput(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(fontSize: 12.5, color: AgyColors.textSecondary),
      filled: true,
      fillColor: AgyColors.bgSubtle,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AgyColors.borderHairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AgyColors.accent, width: 1.2),
      ),
    );
  }

  Color _statusColor(HostConnectionState host) {
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
    final stColor = _statusColor(host);

    final content = Column(
      children: [
        if (widget.embedded)
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            decoration: const BoxDecoration(
              color: AgyColors.bgDock,
              border: Border(bottom: BorderSide(color: AgyColors.borderHairline)),
            ),
            child: Row(
              children: [
                const Icon(Icons.dns_rounded, size: 19, color: AgyColors.accentBright),
                const SizedBox(width: 8),
                const Text(
                  '主机与连接',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: AgyColors.textPrimary,
                    letterSpacing: -0.2,
                  ),
                ),
                const Spacer(),
                if (host.isPaired)
                  AgyTag(
                    label: host.status == MuxConnectionStatus.connected
                        ? (host.isDirect ? 'LAN 直连' : '5G 隧道')
                        : '未连接',
                    color: stColor,
                    backgroundColor: stColor.withValues(alpha: 0.14),
                    borderColor: stColor.withValues(alpha: 0.35),
                  ),
              ],
            ),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
            children: [
              if (host.isPaired) ...[
                ConsolePanel(
                  accentStripeColor: stColor,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          AgyStatusDot(color: stColor, size: 8),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              host.connectionBanner,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                fontFeatures: kTabularFigures,
                                color: AgyColors.textPrimary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: AgyColors.bgSubtle,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AgyColors.borderHairline),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              host.status == MuxConnectionStatus.connected
                                  ? '当前节点：${host.activeEndpoint ?? "-"}'
                                  : '目标节点：${host.activeEndpoint ?? "-"}',
                              style: const TextStyle(
                                fontSize: 12,
                                fontFamily: 'monospace',
                                color: AgyColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              host.status == MuxConnectionStatus.connected
                                  ? '桌面 Antigravity 状态：${host.desktopOnline ? "在线可发送指令" : "未运行（仅历史只读）"}'
                                  : '桥接连接状态：未连接宿主机（请确认局域网或开启 5G 公网隧道）',
                              style: const TextStyle(fontSize: 12, color: AgyColors.textSecondary),
                            ),
                          ],
                        ),
                      ),
                      if ((host.pairing?.endpoints ?? const []).length > 1) ...[
                        const SizedBox(height: 8),
                        Text(
                          '候选节点 (${host.pairing!.endpoints.length})：${host.pairing!.endpoints.join(" · ")}',
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontFamily: 'monospace',
                            color: AgyColors.textMuted,
                          ),
                        ),
                      ] else if ((host.pairing?.endpoints ?? const []).length == 1 &&
                          isDirectEndpointUrl(host.pairing!.endpoints.first)) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                          decoration: BoxDecoration(
                            color: AgyColors.warningTint,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AgyColors.warning.withValues(alpha: 0.35)),
                          ),
                          child: const Text(
                            '提示：当前配对仅含局域网地址；若需 5G 访问，请先在电脑端开启 Tailscale Funnel 后重新扫码。',
                            style: TextStyle(fontSize: 11.5, color: AgyColors.warning),
                          ),
                        ),
                      ],
                      const SizedBox(height: 10),
                      const Divider(height: 1, color: AgyColors.borderHairline),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('后台常驻前台服务保活', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500)),
                        subtitle: const Text(
                          '保持锁屏后仍能实时接收 Agent 提醒与快捷回复',
                          style: TextStyle(fontSize: 11.5, color: AgyColors.textMuted),
                        ),
                        value: host.alwaysOnEnabled,
                        onChanged: (v) => ref.read(hostConnectionProvider.notifier).setAlwaysOn(v),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton(
                            onPressed: () => ref.read(hostConnectionProvider.notifier).reconnect(),
                            child: const Text('重新探测直连'),
                          ),
                          OutlinedButton(
                            onPressed: () => NativeBridge.instance.openBatteryOptimizationSettings(),
                            child: const Text('系统防杀后台 / 电池设置'),
                          ),
                          TextButton(
                            onPressed: () => ref.read(hostConnectionProvider.notifier).disconnectAndClear(),
                            child: const Text('解除配对', style: TextStyle(color: AgyColors.danger)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],

              ConsolePanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.qr_code_scanner_rounded, size: 17, color: AgyColors.accentBright),
                        SizedBox(width: 8),
                        Text(
                          '方式一：扫码一键配对',
                          style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: AgyColors.textPrimary),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      '扫描 Mac 端 agy-bridge pair 输出的二维码，自动录入局域网与 Tailscale 双地址。',
                      style: TextStyle(fontSize: 12.5, color: AgyColors.textSecondary),
                    ),
                    const SizedBox(height: 12),
                    if (_scanning)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox(
                          height: 240,
                          child: MobileScanner(
                            errorBuilder: (ctx, error, _) => Container(
                              color: AgyColors.bgSubtle,
                              padding: const EdgeInsets.all(16),
                              alignment: Alignment.center,
                              child: Text(
                                '相机不可用（${error.errorCode.name}），请使用下方「粘贴配对 JSON」或手动输入连接。',
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 12.5, color: AgyColors.textSecondary),
                              ),
                            ),
                            onDetect: (capture) {
                              for (final barcode in capture.barcodes) {
                                final raw = barcode.rawValue;
                                if (raw == null || raw.isEmpty) continue;
                                try {
                                  final payload = PairingPayload.parseQr(raw);
                                  setState(() => _scanning = false);
                                  _applyPayload(payload);
                                  break;
                                } catch (_) {}
                              }
                            },
                          ),
                        ),
                      )
                    else
                      SizedBox(
                        width: double.infinity,
                        height: 44,
                        child: FilledButton.icon(
                          onPressed: () => setState(() => _scanning = true),
                          icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                          label: const Text('打开相机扫描二维码'),
                        ),
                      ),
                  ],
                ),
              ),

              const SizedBox(height: 12),
              ConsolePanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.code_rounded, size: 17, color: AgyColors.info),
                        SizedBox(width: 8),
                        Text(
                          '方式二：粘贴配对 JSON 或手动输入',
                          style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: AgyColors.textPrimary),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _jsonCtrl,
                      minLines: 2,
                      maxLines: 4,
                      style: const TextStyle(fontSize: 13, fontFamily: 'monospace', color: AgyColors.textPrimary),
                      decoration: _consoleInput('直接粘贴终端输出的配对 JSON'),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: OutlinedButton(
                        onPressed: () {
                          try {
                            final payload = PairingPayload.parseQr(_jsonCtrl.text);
                            _applyPayload(payload);
                          } catch (e) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('JSON 格式无效：$e')));
                          }
                        },
                        child: const Text('导入 JSON'),
                      ),
                    ),
                    const Divider(height: 24, color: AgyColors.borderHairline),
                    TextField(
                      controller: _hostCtrl,
                      style: const TextStyle(fontSize: 13.5, color: AgyColors.textPrimary),
                      decoration: _consoleInput('主机名'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _endpointCtrl,
                      style: const TextStyle(fontSize: 13, fontFamily: 'monospace', color: AgyColors.textPrimary),
                      decoration: _consoleInput('地址列表（逗号分隔，如 http://192.168.31.152:8765,https://...）'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _tokenCtrl,
                      style: const TextStyle(fontSize: 13, fontFamily: 'monospace', color: AgyColors.textPrimary),
                      decoration: _consoleInput('Bearer Token (agy_live_...)'),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      height: 44,
                      child: FilledButton(
                        onPressed: () {
                          final eps = _endpointCtrl.text
                              .split(',')
                              .map((s) => s.trim())
                              .where((s) => s.isNotEmpty)
                              .toList();
                          final tok = _tokenCtrl.text.trim();
                          if (eps.isEmpty || tok.isEmpty) return;
                          _applyPayload(PairingPayload(
                            version: 1,
                            hostName: _hostCtrl.text.trim().isEmpty ? 'AntigravityHost' : _hostCtrl.text.trim(),
                            endpoints: eps,
                            token: tok,
                          ));
                        },
                        child: const Text('保存并连接'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );

    if (widget.embedded) {
      return AgyCanvas(child: SafeArea(bottom: false, child: content));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('主机连接与配对'),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: AgyColors.borderHairline),
        ),
      ),
      body: AgyCanvas(child: content),
    );
  }
}
