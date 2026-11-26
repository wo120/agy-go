import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';

import '../../theme/agy_theme.dart';

typedef CreateSessionSubmit = Future<void> Function({
  required String prompt,
  required String title,
  required String model,
  String? workspacePath,
});

class ModelFamilyGroup {
  const ModelFamilyGroup({
    required this.familyName,
    required this.poolId,
    required this.tag,
    required this.variants,
  });

  final String familyName;
  final String poolId;
  final String tag;
  final List<ModelOption> variants;
}

class NewSessionSheet extends StatefulWidget {
  const NewSessionSheet({
    super.key,
    required this.workspaces,
    required this.models,
    required this.onSubmit,
  });

  final List<WorkspaceInfo> workspaces;
  final List<ModelOption> models;
  final CreateSessionSubmit onSubmit;

  static const List<ModelOption> fallbackModels = [
    ModelOption(modelId: 'pro', label: 'Pro（复杂任务推荐）', poolId: 'gemini', isDefault: true),
    ModelOption(modelId: 'flash', label: 'Flash（快速响应）', poolId: 'gemini'),
    ModelOption(modelId: 'flash_lite', label: 'Flash Lite（轻量）', poolId: 'gemini'),
  ];

  static int _effortRank(String variant) {
    switch (variant.trim().toLowerCase()) {
      case 'low':
        return 0;
      case 'medium':
        return 1;
      case 'high':
        return 2;
      case 'xhigh':
      case 'extra high':
        return 3;
      default:
        return -1;
    }
  }

  /// Groups concrete Antigravity models by family name while preserving desktop order.
  static List<ModelFamilyGroup> groupModels(List<ModelOption> source) {
    final orderedFamilies = <String>[];
    final byFamily = <String, List<ModelOption>>{};
    for (final m in source) {
      if (m.modelId.isEmpty) continue;
      final fam = m.familyName;
      if (!byFamily.containsKey(fam)) {
        orderedFamilies.add(fam);
        byFamily[fam] = [];
      }
      byFamily[fam]!.add(m);
    }

    return orderedFamilies.map((fam) {
      final list = List<ModelOption>.from(byFamily[fam]!);
      final allRanked = list.length > 1 && list.every((m) => _effortRank(m.variantName) >= 0);
      if (allRanked) {
        list.sort((a, b) => _effortRank(a.variantName).compareTo(_effortRank(b.variantName)));
      }
      final first = list.first;
      return ModelFamilyGroup(
        familyName: fam,
        poolId: first.poolId,
        tag: first.tag,
        variants: list,
      );
    }).toList();
  }

  @override
  State<NewSessionSheet> createState() => _NewSessionSheetState();
}

class _NewSessionSheetState extends State<NewSessionSheet> {
  final _promptCtrl = TextEditingController();
  final _titleCtrl = TextEditingController();

  String? _selectedWorkspacePath;
  late List<ModelFamilyGroup> _families;
  late String _selectedFamilyName;
  late String _selectedModelId;
  bool _userPickedModel = false;
  bool _showTitleField = false;
  bool _submitting = false;
  String? _errorText;

  bool get _usingFallback => widget.models.isEmpty;

  @override
  void initState() {
    super.initState();
    _syncModelGroups(resetSelection: true);
  }

  @override
  void didUpdateWidget(covariant NewSessionSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.models != widget.models) {
      _syncModelGroups(resetSelection: !_userPickedModel);
    }
  }

  @override
  void dispose() {
    _promptCtrl.dispose();
    _titleCtrl.dispose();
    super.dispose();
  }

  void _syncModelGroups({required bool resetSelection}) {
    final effective = widget.models.isNotEmpty ? widget.models : NewSessionSheet.fallbackModels;
    _families = NewSessionSheet.groupModels(effective);

    if (!resetSelection && _families.any((f) => f.variants.any((v) => v.modelId == _selectedModelId))) {
      return;
    }

    final chosen = effective.firstWhere(
      (m) => m.isDefault,
      orElse: () => effective.first,
    );
    _selectedFamilyName = chosen.familyName;
    _selectedModelId = chosen.modelId;
  }

  ModelFamilyGroup get _currentFamily {
    return _families.firstWhere(
      (f) => f.familyName == _selectedFamilyName,
      orElse: () => _families.first,
    );
  }

  void _selectFamily(String familyName) {
    final fam = _families.firstWhere(
      (f) => f.familyName == familyName,
      orElse: () => _families.first,
    );
    final preferred = fam.variants.firstWhere(
      (v) => v.isDefault,
      orElse: () => fam.variants.firstWhere(
        (v) => v.variantName.toLowerCase() == 'high',
        orElse: () => fam.variants.firstWhere(
          (v) => v.variantName.toLowerCase() == 'medium',
          orElse: () => fam.variants.first,
        ),
      ),
    );
    setState(() {
      _userPickedModel = true;
      _selectedFamilyName = fam.familyName;
      _selectedModelId = preferred.modelId;
    });
  }

  Future<void> _handleSubmit() async {
    final text = _promptCtrl.text.trim();
    if (text.isEmpty || _submitting) return;
    setState(() {
      _submitting = true;
      _errorText = null;
    });
    try {
      await widget.onSubmit(
        prompt: text,
        title: _showTitleField ? _titleCtrl.text.trim() : '',
        model: _selectedModelId,
        workspacePath: _selectedWorkspacePath,
      );
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      } else if (mounted) {
        setState(() => _submitting = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _errorText = '新建失败：$e';
        });
      }
    }
  }

  List<WorkspaceInfo> get _uniqueWorkspaces {
    final seen = <String>{};
    final out = <WorkspaceInfo>[];
    for (final ws in widget.workspaces) {
      final path = ws.rootPath;
      if (path == null || path.isEmpty || !seen.add(path)) continue;
      out.add(ws);
    }
    return out;
  }

  String _workspaceDisplayName(WorkspaceInfo ws, Map<String, int> labelCounts) {
    if ((labelCounts[ws.label] ?? 0) <= 1 || ws.rootPath == null) {
      return ws.label;
    }
    final segs = ws.rootPath!.split('/').where((s) => s.isNotEmpty).toList();
    if (segs.length >= 2) {
      return '${ws.label} · ${segs[segs.length - 2]}';
    }
    return ws.label;
  }

  InputDecoration _consoleInputDecoration({required String hintText, EdgeInsetsGeometry? contentPadding}) {
    return InputDecoration(
      hintText: hintText,
      hintStyle: const TextStyle(color: AgyColors.textMuted, fontSize: 14),
      filled: true,
      fillColor: AgyColors.bgSubtle,
      contentPadding: contentPadding ?? const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AgyColors.borderHairline, width: 1),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AgyColors.borderHairline, width: 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AgyColors.accent, width: 1.2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final family = _currentFamily;
    final workspaces = _uniqueWorkspaces;
    final labelCounts = <String, int>{};
    for (final ws in workspaces) {
      labelCounts[ws.label] = (labelCounts[ws.label] ?? 0) + 1;
    }
    final activeWorkspace = workspaces.any((w) => w.rootPath == _selectedWorkspacePath)
        ? _selectedWorkspacePath
        : null;
    final canSubmit = !_submitting && _promptCtrl.text.trim().isNotEmpty;
    final hasVariants = family.variants.any((v) => v.variantName.isNotEmpty);

    return Container(
      decoration: const BoxDecoration(
        color: AgyColors.bgDock,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(top: BorderSide(color: AgyColors.borderStrong, width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, 10, 20, MediaQuery.of(context).viewInsets.bottom + 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Drag handle
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

              // Header
              Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: AgyColors.accentTint,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AgyColors.borderAccent, width: 1),
                    ),
                    child: const Icon(
                      Icons.terminal_rounded,
                      size: 18,
                      color: AgyColors.accentBright,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '发起新的 Antigravity 对话',
                          style: TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w700,
                            color: AgyColors.textPrimary,
                            letterSpacing: -0.2,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          '选择工作区与模型，直接发送至 Mac 执行',
                          style: TextStyle(fontSize: 11.5, color: AgyColors.textMuted),
                        ),
                      ],
                    ),
                  ),
                  if (Navigator.of(context).canPop())
                    AgyIconAction(
                      icon: Icons.close_rounded,
                      tooltip: '关闭',
                      size: 32,
                      color: AgyColors.textSecondary,
                      onTap: () {
                        if (!_submitting) Navigator.of(context).pop();
                      },
                    ),
                ],
              ),
              const SizedBox(height: 16),

              // Section 1: Workspace
              const _SectionLabel(text: '目标工作区'),
              const SizedBox(height: 6),
              _ConsoleFieldBox(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String?>(
                    value: activeWorkspace,
                    isExpanded: true,
                    dropdownColor: AgyColors.bgElevated,
                    borderRadius: BorderRadius.circular(12),
                    icon: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: AgyColors.textSecondary,
                      size: 20,
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Row(
                          children: [
                            Icon(Icons.public_rounded, size: 16, color: AgyColors.info),
                            SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                '通用对话（无代码库）',
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 14, color: AgyColors.textPrimary),
                              ),
                            ),
                          ],
                        ),
                      ),
                      for (final ws in workspaces)
                        DropdownMenuItem<String?>(
                          value: ws.rootPath,
                          child: Row(
                            children: [
                              const Icon(Icons.folder_outlined, size: 16, color: AgyColors.accentBright),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _workspaceDisplayName(ws, labelCounts),
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 14, color: AgyColors.textPrimary),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                    onChanged: _submitting ? null : (v) => setState(() => _selectedWorkspacePath = v),
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // Section 2: Model + Effort selector
              Row(
                children: [
                  const _SectionLabel(text: '模型与档位'),
                  const Spacer(),
                  Flexible(
                    child: AgyTag(
                      label: _selectedModelId,
                      monospace: true,
                      color: AgyColors.textSecondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              _ConsoleFieldBox(
                padding: EdgeInsets.zero,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          key: ValueKey('${family.familyName}_${_families.length}'),
                          value: family.familyName,
                          isExpanded: true,
                          dropdownColor: AgyColors.bgElevated,
                          borderRadius: BorderRadius.circular(12),
                          icon: const Icon(
                            Icons.keyboard_arrow_down_rounded,
                            color: AgyColors.textSecondary,
                            size: 20,
                          ),
                          items: [
                            for (final fam in _families)
                              DropdownMenuItem<String>(
                                value: fam.familyName,
                                child: Row(
                                  children: [
                                    Container(
                                      width: 7,
                                      height: 7,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(2),
                                        color: fam.poolId == 'claude_gpt'
                                            ? AgyColors.accentBright
                                            : AgyColors.info,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        fam.familyName,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500,
                                          color: AgyColors.textPrimary,
                                        ),
                                      ),
                                    ),
                                    if (fam.tag.isNotEmpty) ...[
                                      const SizedBox(width: 6),
                                      _ModelTagBadge(tag: fam.tag),
                                    ],
                                  ],
                                ),
                              ),
                          ],
                          onChanged: _submitting
                              ? null
                              : (v) {
                                  if (v != null) _selectFamily(v);
                                },
                        ),
                      ),
                    ),
                    if (hasVariants) ...[
                      const Divider(height: 1, thickness: 1, color: AgyColors.borderHairline),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final v in family.variants)
                              _EffortPill(
                                label: v.variantName.isNotEmpty ? v.variantName : v.label,
                                selected: v.modelId == _selectedModelId,
                                onTap: _submitting
                                    ? null
                                    : () => setState(() {
                                          _userPickedModel = true;
                                          _selectedModelId = v.modelId;
                                        }),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (_usingFallback) ...[
                const SizedBox(height: 6),
                const Text(
                  '未拉取到桌面端模型列表，已回退为基础档位',
                  style: TextStyle(fontSize: 11, color: AgyColors.textMuted),
                ),
              ],
              const SizedBox(height: 14),

              // Section 3: Prompt + Optional Title
              Row(
                children: [
                  const _SectionLabel(text: '指令或需求'),
                  const Spacer(),
                  InkWell(
                    onTap: _submitting
                        ? null
                        : () => setState(() => _showTitleField = !_showTitleField),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _showTitleField ? Icons.remove_rounded : Icons.add_rounded,
                            size: 14,
                            color: AgyColors.accentBright,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            _showTitleField ? '收起标题' : '自定义标题',
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: AgyColors.accentBright,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                child: _showTitleField
                    ? Padding(
                        padding: const EdgeInsets.only(top: 6, bottom: 8),
                        child: TextField(
                          key: const Key('new_session_title_field'),
                          controller: _titleCtrl,
                          enabled: !_submitting,
                          style: const TextStyle(fontSize: 14, color: AgyColors.textPrimary),
                          decoration: _consoleInputDecoration(
                            hintText: '对话标题（可选，留空自动生成）',
                            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                          ),
                        ),
                      )
                    : const SizedBox(height: 6),
              ),
              TextField(
                key: const Key('new_session_prompt_field'),
                controller: _promptCtrl,
                enabled: !_submitting,
                minLines: 3,
                maxLines: 6,
                style: const TextStyle(fontSize: 14, height: 1.45, color: AgyColors.textPrimary),
                onChanged: (_) => setState(() {}),
                decoration: _consoleInputDecoration(
                  hintText: '输入指令或需求，交由 Mac 端执行…',
                ),
              ),
              if (_errorText != null) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: AgyColors.dangerTint,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AgyColors.danger.withValues(alpha: 0.45)),
                  ),
                  child: Text(
                    _errorText!,
                    style: const TextStyle(fontSize: 12, color: Color(0xFFFCA5A5)),
                  ),
                ),
              ],
              const SizedBox(height: 16),

              // Primary CTA button (crisp solid emerald-teal)
              SizedBox(
                width: double.infinity,
                height: 46,
                child: FilledButton(
                  onPressed: canSubmit ? _handleSubmit : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: AgyColors.accent,
                    foregroundColor: AgyColors.textOnAccent,
                    disabledBackgroundColor: AgyColors.bgSubtle,
                    disabledForegroundColor: AgyColors.textMuted,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _submitting
                      ? const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: AgyColors.textOnAccent),
                            ),
                            SizedBox(width: 8),
                            Text('正在发送到 Mac…', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
                          ],
                        )
                      : const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.arrow_upward_rounded, size: 18),
                            SizedBox(width: 6),
                            Text('发送到 Mac 执行', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: AgyColors.textSecondary,
        letterSpacing: 0.1,
      ),
    );
  }
}

class _ConsoleFieldBox extends StatelessWidget {
  const _ConsoleFieldBox({
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: AgyColors.bgSubtle,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AgyColors.borderHairline, width: 1),
      ),
      child: child,
    );
  }
}

class _EffortPill extends StatelessWidget {
  const _EffortPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? AgyColors.accentTint : AgyColors.bgElevated,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? AgyColors.accentBright : AgyColors.borderHairline,
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? AgyColors.accentBright : AgyColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _ModelTagBadge extends StatelessWidget {
  const _ModelTagBadge({required this.tag});

  final String tag;

  @override
  Widget build(BuildContext context) {
    final lower = tag.toLowerCase();
    final Color fg;
    final Color bg;
    if (lower.contains('leaving')) {
      fg = AgyColors.warning;
      bg = AgyColors.warningTint;
    } else if (lower == 'new') {
      fg = AgyColors.online;
      bg = AgyColors.onlineTint;
    } else {
      fg = AgyColors.textSecondary;
      bg = AgyColors.bgActive;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        tag,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: fg),
      ),
    );
  }
}
