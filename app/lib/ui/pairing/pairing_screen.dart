import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../state/app_state.dart';
import '../../state/native_bridge.dart';
import '../../theme/levity_theme.dart';

class PairingScreen extends ConsumerStatefulWidget {
  const PairingScreen({super.key});

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(hostConnectionProvider.notifier).verifyConnection();
      }
    });
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
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已配对主机 ${payload.hostName}')),
      );
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final host = ref.watch(hostConnectionProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('主机连接与配对')),
      body: LevityBackground(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (host.isPaired) ...[
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(host.connectionBanner, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Text(
                      host.status == MuxConnectionStatus.connected
                          ? '当前节点：${host.activeEndpoint ?? "-"}'
                          : '目标节点：${host.activeEndpoint ?? "-"}',
                      style: const TextStyle(fontSize: 12.5, color: LevityColors.textSecondary),
                    ),
                    Text(
                      host.status == MuxConnectionStatus.connected
                          ? '桌面 Antigravity 状态：${host.desktopOnline ? "在线可发送指令" : "未运行（仅历史只读）"}'
                          : '桥接连接状态：未连接宿主机（请确认局域网或开启 5G 公网隧道）',
                      style: const TextStyle(fontSize: 12.5, color: LevityColors.textSecondary),
                    ),
                    if ((host.pairing?.endpoints ?? const []).length > 1) ...[
                      const SizedBox(height: 6),
                      Text(
                        '候选节点 (${host.pairing!.endpoints.length})：${host.pairing!.endpoints.join(" · ")}',
                        style: const TextStyle(fontSize: 11.5, color: LevityColors.textMuted),
                      ),
                    ] else if ((host.pairing?.endpoints ?? const []).length == 1 &&
                        isDirectEndpointUrl(host.pairing!.endpoints.first)) ...[
                      const SizedBox(height: 6),
                      const Text(
                        '提示：当前配对仅含局域网地址；若需 5G 访问，请先在电脑端开启 Tailscale Funnel 后重新扫码。',
                        style: TextStyle(fontSize: 11.5, color: LevityColors.orangeWarning),
                      ),
                    ],
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('后台常驻前台服务保活', style: TextStyle(fontSize: 14)),
                      subtitle: const Text('保持锁屏后仍能实时接收 Agent 提醒与快捷回复', style: TextStyle(fontSize: 12, color: LevityColors.textMuted)),
                      value: host.alwaysOnEnabled,
                      onChanged: (v) => ref.read(hostConnectionProvider.notifier).setAlwaysOn(v),
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.tonal(
                          onPressed: () => ref.read(hostConnectionProvider.notifier).reconnect(),
                          child: const Text('重新探测直连'),
                        ),
                        OutlinedButton(
                          onPressed: () => NativeBridge.instance.openBatteryOptimizationSettings(),
                          child: const Text('系统防杀后台 / 电池设置'),
                        ),
                        TextButton(
                          onPressed: () => ref.read(hostConnectionProvider.notifier).disconnectAndClear(),
                          child: const Text('解除配对', style: TextStyle(color: Color(0xFFF87171))),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('方式一：扫码一键配对', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  const Text('扫描 Mac 端 agy-bridge pair 输出的二维码，自动录入局域网与 Tailscale 双地址。', style: TextStyle(fontSize: 12.5, color: LevityColors.textSecondary)),
                  const SizedBox(height: 12),
                  if (_scanning)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: SizedBox(
                        height: 240,
                        child: MobileScanner(
                          errorBuilder: (ctx, error, _) => Container(
                            color: const Color(0xFF141626),
                            padding: const EdgeInsets.all(16),
                            alignment: Alignment.center,
                            child: Text(
                              '相机不可用（${error.errorCode.name}），请使用下方「粘贴配对 JSON」或手动输入连接。',
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 12.5, color: LevityColors.textSecondary),
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
                      child: FilledButton.icon(
                        onPressed: () => setState(() => _scanning = true),
                        icon: const Icon(Icons.qr_code_scanner_rounded),
                        label: const Text('打开相机扫描二维码'),
                      ),
                    ),
                ],
              ),
            ),

            const SizedBox(height: 14),
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('方式二：粘贴配对 JSON 或手动输入', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _jsonCtrl,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: '直接粘贴终端输出的配对 JSON',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.tonal(
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
                  const Divider(height: 24, color: LevityColors.cardBorder),
                  TextField(
                    controller: _hostCtrl,
                    decoration: const InputDecoration(labelText: '主机名', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _endpointCtrl,
                    decoration: const InputDecoration(
                      labelText: '地址列表（逗号分隔，如 http://192.168.31.152:8765,http://100.x.y.z:8765）',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _tokenCtrl,
                    decoration: const InputDecoration(labelText: 'Bearer Token (agy_live_...)', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
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
    );
  }
}
