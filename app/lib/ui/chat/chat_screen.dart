import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../theme/agy_theme.dart';
import '../artifacts/artifact_viewer.dart';
import '../pairing/pairing_screen.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.conversationId});

  final String conversationId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  bool _showScrollToBottom = false;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    _inputCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!mounted || !_scrollCtrl.hasClients) return;
    final shouldShow = _scrollCtrl.position.pixels > 260;
    if (shouldShow != _showScrollToBottom) {
      setState(() => _showScrollToBottom = shouldShow);
    }
  }

  void _scrollToBottom() {
    if (!mounted || !_scrollCtrl.hasClients) return;
    _scrollCtrl.animateTo(
      0,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  void _openLocalFile(String rawHref, String fallbackLabel) {
    final cleanPath = Uri.decodeFull(rawHref.replaceFirst('file://', '').split('#').first);
    final name = fallbackLabel.isNotEmpty ? fallbackLabel : cleanPath.split('/').last;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ArtifactViewerPage(
          conversationId: widget.conversationId,
          path: cleanPath,
          displayName: name,
        ),
      ),
    );
  }

  Future<void> _send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _inputCtrl.clear();
    await ref.read(chatSessionProvider(widget.conversationId).notifier).sendMessage(trimmed);
    Future.delayed(const Duration(milliseconds: 120), _scrollToBottom);
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatSessionProvider(widget.conversationId));
    final desktopOnline = ref.watch(hostConnectionProvider.select((h) => h.desktopOnline));
    final session = chat.session;
    final hasPendingInteraction = chat.pendingInteractions.isNotEmpty;
    final needsConfirm = !hasPendingInteraction && session?.needsConfirm == true;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              session?.title ?? '加载会话中...',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
            ),
            if (session != null)
              Text(
                [
                  session.workspace.label,
                  if ((session.modelDisplay ?? '').isNotEmpty) session.modelDisplay!,
                  if (session.subagentCount > 0) '${session.subagentCount} 子代理',
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, color: AgyColors.textMuted),
              ),
          ],
        ),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: AgyColors.borderHairline),
        ),
        actions: [
          if (chat.artifacts.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => showArtifactsDrawer(
                  context,
                  conversationId: widget.conversationId,
                  artifacts: chat.artifacts,
                ),
                child: AgyTag(
                  icon: Icons.description_outlined,
                  label: '${chat.artifacts.length} 产物',
                  color: AgyColors.accentBright,
                  backgroundColor: AgyColors.accentTint,
                  borderColor: AgyColors.borderAccent,
                ),
              ),
            ),
        ],
      ),
      body: AgyCanvas(
        child: Stack(
          children: [
            Column(
              children: [
                if (chat.error != null && chat.rows.isNotEmpty)
                  Container(
                    width: double.infinity,
                    decoration: const BoxDecoration(
                      color: AgyColors.warningTint,
                      border: Border(bottom: BorderSide(color: Color(0x44F59E0B))),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            chat.error!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12.5, color: AgyColors.warning),
                          ),
                        ),
                        TextButton(
                          onPressed: () => ref.read(chatSessionProvider(widget.conversationId).notifier).reload(),
                          child: const Text('重试', style: TextStyle(fontSize: 12.5, color: AgyColors.warning)),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: chat.loading
                      ? const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircularProgressIndicator(color: AgyColors.accentBright, strokeWidth: 2.2),
                              SizedBox(height: 12),
                              Text('正在同步会话记录...', style: TextStyle(fontSize: 12.5, color: AgyColors.textMuted)),
                            ],
                          ),
                        )
                      : chat.rows.isEmpty
                          ? (chat.error != null
                              ? Center(
                                  child: Padding(
                                    padding: const EdgeInsets.all(24),
                                    child: ConsolePanel(
                                      padding: const EdgeInsets.all(20),
                                      accentStripeColor: AgyColors.warning,
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(Icons.wifi_off_rounded, size: 32, color: AgyColors.warning),
                                          const SizedBox(height: 10),
                                          const Text(
                                            '会话内容加载失败',
                                            style: TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.w700,
                                              color: AgyColors.textPrimary,
                                            ),
                                          ),
                                          const SizedBox(height: 6),
                                          Text(
                                            chat.error!,
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(fontSize: 12.5, color: AgyColors.textSecondary),
                                          ),
                                          const SizedBox(height: 14),
                                          Wrap(
                                            spacing: 10,
                                            runSpacing: 8,
                                            alignment: WrapAlignment.center,
                                            children: [
                                              FilledButton(
                                                onPressed: () => ref
                                                    .read(chatSessionProvider(widget.conversationId).notifier)
                                                    .reload(),
                                                child: const Text('重新加载'),
                                              ),
                                              OutlinedButton(
                                                onPressed: () => Navigator.of(context).push(
                                                  MaterialPageRoute(builder: (_) => const PairingScreen()),
                                                ),
                                                child: const Text('检查主机连接'),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                )
                              : const Center(
                                  child: Text('暂无聊天步骤记录', style: TextStyle(color: AgyColors.textMuted)),
                                ))
                          : ListView.builder(
                              controller: _scrollCtrl,
                              reverse: true,
                              padding: const EdgeInsets.fromLTRB(14, 12, 14, 96),
                              itemCount: chat.rows.length,
                              itemBuilder: (ctx, idx) {
                                final row = chat.rows[chat.rows.length - 1 - idx];
                                return Padding(
                                  key: ValueKey(row.keyId),
                                  padding: const EdgeInsets.only(bottom: 10),
                                  child: _buildRow(row),
                                );
                              },
                            ),
                ),
                if (hasPendingInteraction)
                  _PendingInteractionDock(
                    interactions: chat.pendingInteractions,
                    submitting: chat.respondingInteraction,
                    desktopOnline: desktopOnline,
                    onRespondPermission: (interaction, {required bool allow, required String scope, String? feedback}) =>
                        ref.read(chatSessionProvider(widget.conversationId).notifier).respondPermission(
                              interaction,
                              allow: allow,
                              scope: scope,
                              feedback: feedback,
                            ),
                    onRespondAskQuestion: (interaction, selectedOptionIds) => ref
                        .read(chatSessionProvider(widget.conversationId).notifier)
                        .respondAskQuestion(interaction, selectedOptionIds),
                  ),
                _buildComposer(desktopOnline, chat.sending),
              ],
            ),

            // One-hand floating action dock (scroll to bottom or one-tap confirm)
            if (_showScrollToBottom || needsConfirm)
              Positioned(
                right: 16,
                bottom: 84,
                child: _OneHandFloatingDock(
                  needsConfirm: needsConfirm,
                  showScrollDown: _showScrollToBottom,
                  onQuickConfirm: () => _send('确认方案，直接开工'),
                  onScrollBottom: _scrollToBottom,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(ChatRow row) {
    return switch (row) {
      UserMessageRow() => _UserMessageBubble(row: row),
      ProcessGroupRow() => _ProcessAccordionRow(row: row),
      AssistantMessageRow() => _AssistantMessageCard(
          row: row,
          onOpenLocalFile: _openLocalFile,
        ),
      DecisionPromptRow() => ConsolePanel(
          padding: const EdgeInsets.all(14),
          borderRadius: 12,
          accentStripeColor: AgyColors.warning,
          borderColor: AgyColors.warning.withValues(alpha: 0.4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.bolt_rounded, size: 16, color: AgyColors.warning),
                  SizedBox(width: 6),
                  Text(
                    'Agent 等待你拍板确认',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AgyColors.warning),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              for (final q in row.questions) ...[
                Text(
                  q.question,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AgyColors.textPrimary),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final opt in q.options)
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          backgroundColor: AgyColors.bgSubtle,
                          side: const BorderSide(color: AgyColors.borderAccent),
                          foregroundColor: AgyColors.accentBright,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                        onPressed: () => _send(opt.replaceFirst('(Recommended) ', '')),
                        child: Text(opt, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ],
          ),
        ),
    };
  }

  Widget _buildComposer(bool desktopOnline, bool sending) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        decoration: const BoxDecoration(
          color: AgyColors.bgDock,
          border: Border(top: BorderSide(color: AgyColors.borderHairline)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _inputCtrl,
                minLines: 1,
                maxLines: 4,
                style: const TextStyle(fontSize: 14.5, color: AgyColors.textPrimary),
                decoration: InputDecoration(
                  hintText: desktopOnline ? '回复 Agent 指令或确认决策...' : '桌面端未启动（只读浏览模式）',
                  hintStyle: const TextStyle(color: AgyColors.textMuted, fontSize: 13.5),
                  filled: true,
                  fillColor: AgyColors.bgSubtle,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: AgyColors.borderHairline),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: AgyColors.accent, width: 1.2),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 42,
              height: 42,
              child: FilledButton(
                onPressed: sending ? null : () => _send(_inputCtrl.text),
                style: FilledButton.styleFrom(
                  padding: EdgeInsets.zero,
                  backgroundColor: AgyColors.accent,
                  foregroundColor: AgyColors.textOnAccent,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AgyColors.textOnAccent),
                      )
                    : const Icon(Icons.arrow_upward_rounded, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AssistantMessageCard extends StatefulWidget {
  const _AssistantMessageCard({
    required this.row,
    required this.onOpenLocalFile,
  });

  final AssistantMessageRow row;
  final void Function(String rawHref, String fallbackLabel) onOpenLocalFile;

  @override
  State<_AssistantMessageCard> createState() => _AssistantMessageCardState();
}

class _AssistantMessageCardState extends State<_AssistantMessageCard> {
  bool _showSpeedDetail = false;

  String _speedBadgeText() {
    if (widget.row.streamTps > 0) {
      return '${widget.row.streamTps.toStringAsFixed(0)} tok/s';
    }
    return 'E2E ${widget.row.e2eTps.toStringAsFixed(0)}';
  }

  String _speedDetailLine() {
    final parts = <String>[];
    if (widget.row.streamTps > 0) {
      parts.add('流式 ${widget.row.streamTps.toStringAsFixed(1)} tok/s');
    }
    if (widget.row.e2eTps > 0) {
      parts.add('E2E ${widget.row.e2eTps.toStringAsFixed(1)} tok/s');
    }
    if (widget.row.ttftMs > 0) {
      final ttft = widget.row.ttftMs < 1000
          ? '${widget.row.ttftMs}ms'
          : '${(widget.row.ttftMs / 1000.0).toStringAsFixed(1)}s';
      parts.add('TTFT $ttft');
    }
    if (widget.row.outputTokens > 0) {
      parts.add('${widget.row.outputTokens} tok');
    }
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final hasHeader = row.modelDisplay.isNotEmpty || row.hasSpeedTelemetry || row.createdAtUnix > 0;

    return ConsolePanel(
      padding: const EdgeInsets.all(14),
      borderRadius: 12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasHeader)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  if (row.modelDisplay.isNotEmpty)
                    Expanded(
                      child: Row(
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: AgyColors.accentBright,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              row.modelDisplay,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                fontFamily: 'monospace',
                                color: AgyColors.accentBright,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    const Spacer(),
                  if (row.hasSpeedTelemetry) ...[
                    const SizedBox(width: 6),
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => setState(() => _showSpeedDetail = !_showSpeedDetail),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AgyColors.onlineTint,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: AgyColors.online.withValues(alpha: 0.3)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.bolt_rounded, size: 11.5, color: AgyColors.online),
                            const SizedBox(width: 2),
                            Text(
                              _speedBadgeText(),
                              style: const TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                fontFamily: 'monospace',
                                fontFeatures: kTabularFigures,
                                color: AgyColors.online,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  if (row.createdAtUnix > 0) ...[
                    const SizedBox(width: 8),
                    Text(
                      formatMessageTime(row.createdAtUnix),
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        fontFeatures: kTabularFigures,
                        color: AgyColors.textMuted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          if (_showSpeedDetail && row.hasSpeedTelemetry)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: AgyColors.bgSubtle,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: AgyColors.borderHairline),
                ),
                child: Text(
                  _speedDetailLine(),
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    fontFeatures: kTabularFigures,
                    color: AgyColors.textSecondary,
                  ),
                ),
              ),
            ),
          MarkdownBody(
            data: row.content,
            selectable: true,
            onTapLink: (text, href, _) {
              if (href != null && href.startsWith('file://')) {
                widget.onOpenLocalFile(href, text);
              }
            },
            styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
              p: const TextStyle(fontSize: 14.2, height: 1.54, color: AgyColors.textPrimary),
              a: const TextStyle(color: AgyColors.info, decoration: TextDecoration.underline),
              code: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.5,
                color: AgyColors.accentBright,
                backgroundColor: AgyColors.bgSubtle,
              ),
              codeblockDecoration: BoxDecoration(
                color: AgyColors.bgCodeBlock,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AgyColors.borderHairline),
              ),
              blockquoteDecoration: const BoxDecoration(
                color: AgyColors.bgSubtle,
                border: Border(left: BorderSide(color: AgyColors.accent, width: 3)),
              ),
            ),
          ),
          if (row.fileLinks.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final link in row.fileLinks)
                  InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => widget.onOpenLocalFile('file://${link.path}', link.label),
                    child: AgyTag(
                      icon: Icons.article_outlined,
                      label: link.label,
                      color: AgyColors.info,
                      backgroundColor: AgyColors.infoTint,
                      borderColor: AgyColors.info.withValues(alpha: 0.3),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _UserMessageBubble extends StatefulWidget {
  const _UserMessageBubble({required this.row});

  final UserMessageRow row;

  @override
  State<_UserMessageBubble> createState() => _UserMessageBubbleState();
}

class _UserMessageBubbleState extends State<_UserMessageBubble> {
  bool _showMetadata = false;

  @override
  Widget build(BuildContext context) {
    final timeLabel = formatMessageTime(widget.row.createdAtUnix);
    final hasMeta = widget.row.metadata.isNotEmpty;

    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.84),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
        decoration: BoxDecoration(
          color: AgyColors.accentBubbleFill,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(14),
            topRight: Radius.circular(14),
            bottomLeft: Radius.circular(14),
            bottomRight: Radius.circular(4),
          ),
          border: Border.all(color: AgyColors.accentBubbleBorder, width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              widget.row.content,
              style: const TextStyle(fontSize: 14.2, height: 1.48, color: AgyColors.textPrimary),
            ),
            if (timeLabel.isNotEmpty || hasMeta) ...[
              const SizedBox(height: 6),
              Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (timeLabel.isNotEmpty)
                    Text(
                      timeLabel,
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        fontFeatures: kTabularFigures,
                        color: AgyColors.accentBright,
                      ),
                    ),
                  if (hasMeta) ...[
                    if (timeLabel.isNotEmpty) const SizedBox(width: 8),
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => setState(() => _showMetadata = !_showMetadata),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _showMetadata ? Icons.expand_less_rounded : Icons.info_outline_rounded,
                              size: 13.5,
                              color: AgyColors.textSecondary,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              _showMetadata ? '收起元信息' : '元信息',
                              style: const TextStyle(fontSize: 10.5, color: AgyColors.textSecondary),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
            if (_showMetadata && hasMeta) ...[
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AgyColors.bgCodeBlock,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AgyColors.borderHairline),
                ),
                child: SelectableText(
                  widget.row.metadata,
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    height: 1.4,
                    color: AgyColors.textSecondary,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProcessAccordionRow extends StatefulWidget {
  const _ProcessAccordionRow({required this.row});

  final ProcessGroupRow row;

  @override
  State<_ProcessAccordionRow> createState() => _ProcessAccordionRowState();
}

class _ProcessAccordionRowState extends State<_ProcessAccordionRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AgyColors.bgSubtle,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AgyColors.borderHairline),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
              child: Row(
                children: [
                  const Icon(Icons.terminal_rounded, size: 15, color: AgyColors.textMuted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.row.summaryLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: AgyColors.textSecondary,
                      ),
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    size: 18,
                    color: AgyColors.textMuted,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Divider(height: 12, color: AgyColors.borderHairline),
                  for (final item in widget.row.items) ...[
                    if (item.toolNames.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          '>_ ${item.toolNames.join(" -> ")}',
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontFamily: 'monospace',
                            color: AgyColors.accentBright,
                          ),
                        ),
                      ),
                    if (item.thinking.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Container(
                          padding: const EdgeInsets.only(left: 8),
                          decoration: const BoxDecoration(
                            border: Border(left: BorderSide(color: AgyColors.borderStrong, width: 2)),
                          ),
                          child: Text(
                            item.thinking,
                            style: const TextStyle(fontSize: 12, height: 1.45, color: AgyColors.textMuted),
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _OneHandFloatingDock extends StatelessWidget {
  const _OneHandFloatingDock({
    required this.needsConfirm,
    required this.showScrollDown,
    required this.onQuickConfirm,
    required this.onScrollBottom,
  });

  final bool needsConfirm;
  final bool showScrollDown;
  final VoidCallback onQuickConfirm;
  final VoidCallback onScrollBottom;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: AgyColors.bgDock,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AgyColors.borderStrong, width: 1),
        boxShadow: const [
          BoxShadow(color: Color(0x66000000), blurRadius: 12, offset: Offset(0, 4)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (needsConfirm)
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onQuickConfirm,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle_rounded, size: 17, color: AgyColors.online),
                    SizedBox(width: 5),
                    Text(
                      '一键确认开工',
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AgyColors.textPrimary),
                    ),
                  ],
                ),
              ),
            ),
          if (needsConfirm && showScrollDown)
            Container(
              width: 1,
              height: 16,
              margin: const EdgeInsets.symmetric(horizontal: 6),
              color: AgyColors.borderHairline,
            ),
          if (showScrollDown)
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onScrollBottom,
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.keyboard_double_arrow_down_rounded, size: 19, color: AgyColors.accentBright),
              ),
            ),
        ],
      ),
    );
  }
}

class _PendingInteractionDock extends StatefulWidget {
  const _PendingInteractionDock({
    required this.interactions,
    required this.submitting,
    required this.desktopOnline,
    required this.onRespondPermission,
    required this.onRespondAskQuestion,
  });

  final List<PendingInteraction> interactions;
  final bool submitting;
  final bool desktopOnline;
  final Future<void> Function(
    PendingInteraction interaction, {
    required bool allow,
    required String scope,
    String? feedback,
  }) onRespondPermission;
  final Future<void> Function(
    PendingInteraction interaction,
    List<List<String>> selectedOptionIds,
  ) onRespondAskQuestion;

  @override
  State<_PendingInteractionDock> createState() => _PendingInteractionDockState();
}

class _PendingInteractionDockState extends State<_PendingInteractionDock> {
  bool _showDenyReason = false;
  final TextEditingController _denyCtrl = TextEditingController();
  int _lastStepIndex = -1;

  @override
  void dispose() {
    _denyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.interactions.first;
    if (_lastStepIndex != current.stepIndex) {
      _lastStepIndex = current.stepIndex;
      _showDenyReason = false;
      _denyCtrl.clear();
    }

    final total = widget.interactions.length;
    return Container(
      key: const Key('pending_interaction_dock'),
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 380),
      decoration: BoxDecoration(
        color: AgyColors.bgDock,
        border: Border(
          top: BorderSide(color: AgyColors.warning.withValues(alpha: 0.6), width: 1.2),
        ),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: current.isPermission
            ? _buildPermissionCard(current, total)
            : current.isAskQuestion
                ? _buildAskQuestionCard(current, total)
                : const SizedBox.shrink(),
      ),
    );
  }

  Widget _buildPermissionCard(PendingInteraction interaction, int total) {
    final perm = interaction.permission!;
    final title = perm.actionDescription.isNotEmpty
        ? '允许 ${perm.actionDescription}?'
        : '允许执行 ${perm.actionLabel}?';
    final pattern = perm.persistPattern;
    final canPersist = perm.allowPersist && pattern.isNotEmpty;
    final disabled = widget.submitting || !widget.desktopOnline;

    return ConsolePanel(
      padding: const EdgeInsets.all(12),
      borderRadius: 12,
      accentStripeColor: AgyColors.warning,
      borderColor: AgyColors.warning.withValues(alpha: 0.45),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.verified_user_outlined, size: 16, color: AgyColors.warning),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.8,
                    fontWeight: FontWeight.w700,
                    color: AgyColors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              AgyTag(
                label: perm.actionLabel,
                color: AgyColors.warning,
                backgroundColor: AgyColors.warningTint,
                borderColor: AgyColors.warning.withValues(alpha: 0.35),
              ),
              if (total > 1) ...[
                const SizedBox(width: 6),
                AgyTag(
                  label: '1/$total',
                  monospace: true,
                  color: AgyColors.accentBright,
                  backgroundColor: AgyColors.accentTint,
                  borderColor: AgyColors.borderAccent,
                ),
              ],
            ],
          ),
          if (perm.target.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: AgyColors.bgCodeBlock,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AgyColors.borderHairline),
              ),
              child: SelectableText(
                perm.target,
                style: const TextStyle(
                  fontSize: 12.2,
                  height: 1.4,
                  fontFamily: 'monospace',
                  color: AgyColors.accentBright,
                ),
              ),
            ),
          ],
          if (perm.reason.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              perm.reason,
              style: const TextStyle(fontSize: 12, height: 1.4, color: AgyColors.textSecondary),
            ),
          ],
          if (!widget.desktopOnline) ...[
            const SizedBox(height: 6),
            const Text(
              '桌面端当前离线，暂无法提交授权',
              style: TextStyle(fontSize: 11.5, color: AgyColors.warning),
            ),
          ],
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const Key('perm_allow_once_btn'),
              onPressed: disabled
                  ? null
                  : () => widget.onRespondPermission(
                        interaction,
                        allow: true,
                        scope: 'once',
                      ),
              style: FilledButton.styleFrom(
                backgroundColor: AgyColors.online,
                foregroundColor: AgyColors.bgCanvas,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              icon: widget.submitting
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AgyColors.bgCanvas),
                    )
                  : const Icon(Icons.check_rounded, size: 17),
              label: const Text(
                '允许这一次',
                style: TextStyle(fontSize: 13.2, fontWeight: FontWeight.w700),
              ),
            ),
          ),
          if (canPersist) ...[
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                key: const Key('perm_allow_conversation_btn'),
                onPressed: disabled
                    ? null
                    : () => widget.onRespondPermission(
                          interaction,
                          allow: true,
                          scope: 'conversation',
                        ),
                style: OutlinedButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  backgroundColor: AgyColors.bgSubtle,
                  side: const BorderSide(color: AgyColors.borderAccent),
                  foregroundColor: AgyColors.textPrimary,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: Text(
                  "本次会话始终允许 '$pattern'",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                key: const Key('perm_allow_global_btn'),
                onPressed: disabled
                    ? null
                    : () => widget.onRespondPermission(
                          interaction,
                          allow: true,
                          scope: 'global',
                        ),
                style: OutlinedButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  backgroundColor: AgyColors.bgSubtle,
                  side: const BorderSide(color: AgyColors.borderHairline),
                  foregroundColor: AgyColors.textSecondary,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: Text(
                  "始终允许 '$pattern'",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('perm_deny_btn'),
                  onPressed: disabled
                      ? null
                      : () => widget.onRespondPermission(
                            interaction,
                            allow: false,
                            scope: 'once',
                          ),
                  style: OutlinedButton.styleFrom(
                    backgroundColor: AgyColors.dangerTint,
                    side: BorderSide(color: AgyColors.danger.withValues(alpha: 0.4)),
                    foregroundColor: AgyColors.danger,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.close_rounded, size: 15),
                  label: const Text('拒绝', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: OutlinedButton.icon(
                  key: const Key('perm_deny_with_reason_toggle'),
                  onPressed: disabled
                      ? null
                      : () => setState(() => _showDenyReason = !_showDenyReason),
                  style: OutlinedButton.styleFrom(
                    backgroundColor: AgyColors.bgSubtle,
                    side: const BorderSide(color: AgyColors.borderHairline),
                    foregroundColor: AgyColors.textSecondary,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: Icon(
                    _showDenyReason ? Icons.expand_less_rounded : Icons.edit_note_rounded,
                    size: 16,
                  ),
                  label: const Text(
                    '否，告诉 Agent 改做什么',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
          if (_showDenyReason) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('perm_deny_reason_input'),
                    controller: _denyCtrl,
                    style: const TextStyle(fontSize: 13, color: AgyColors.textPrimary),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '输入替代指令（将先拒绝再发送给 Agent）...',
                      hintStyle: const TextStyle(fontSize: 12, color: AgyColors.textMuted),
                      filled: true,
                      fillColor: AgyColors.bgSubtle,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: AgyColors.borderHairline),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: AgyColors.danger),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  key: const Key('perm_deny_reason_submit'),
                  onPressed: disabled
                      ? null
                      : () => widget.onRespondPermission(
                            interaction,
                            allow: false,
                            scope: 'once',
                            feedback: _denyCtrl.text.trim(),
                          ),
                  style: FilledButton.styleFrom(
                    backgroundColor: AgyColors.danger,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('提交', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAskQuestionCard(PendingInteraction interaction, int total) {
    final first = interaction.questions.first;
    final disabled = widget.submitting || !widget.desktopOnline;
    return ConsolePanel(
      padding: const EdgeInsets.all(12),
      borderRadius: 12,
      accentStripeColor: AgyColors.warning,
      borderColor: AgyColors.warning.withValues(alpha: 0.45),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.help_outline_rounded, size: 16, color: AgyColors.warning),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'Agent 等待你选择方案',
                  style: TextStyle(fontSize: 13.2, fontWeight: FontWeight.w700, color: AgyColors.warning),
                ),
              ),
              if (total > 1)
                AgyTag(
                  label: '1/$total',
                  monospace: true,
                  color: AgyColors.accentBright,
                  backgroundColor: AgyColors.accentTint,
                  borderColor: AgyColors.borderAccent,
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            first.question,
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: AgyColors.textPrimary),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final opt in first.options)
                OutlinedButton(
                  onPressed: disabled
                      ? null
                      : () => widget.onRespondAskQuestion(
                            interaction,
                            [
                              [opt.id],
                            ],
                          ),
                  style: OutlinedButton.styleFrom(
                    backgroundColor: AgyColors.bgSubtle,
                    side: const BorderSide(color: AgyColors.borderAccent),
                    foregroundColor: AgyColors.accentBright,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  child: Text(opt.text, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
