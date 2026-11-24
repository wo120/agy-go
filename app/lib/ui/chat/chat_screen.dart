import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../theme/levity_theme.dart';
import '../artifacts/artifact_viewer.dart';

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
      duration: const Duration(milliseconds: 260),
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
    final needsConfirm = session?.needsConfirm == true;

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
                style: const TextStyle(fontSize: 11.5, color: LevityColors.textMuted),
              ),
          ],
        ),
        actions: [
          if (chat.artifacts.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: TextButton.icon(
                onPressed: () => showArtifactsDrawer(
                  context,
                  conversationId: widget.conversationId,
                  artifacts: chat.artifacts,
                ),
                icon: const Icon(Icons.description_outlined, size: 17, color: LevityColors.purpleSubagent),
                label: Text('${chat.artifacts.length} 产物', style: const TextStyle(color: LevityColors.textPrimary)),
              ),
            ),
        ],
      ),
      body: LevityBackground(
        child: Stack(
          children: [
            Column(
              children: [
                if (chat.error != null)
                  Container(
                    width: double.infinity,
                    color: const Color(0x33F59E0B),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text(chat.error!, style: const TextStyle(fontSize: 12.5, color: LevityColors.orangeWarning)),
                  ),
                Expanded(
                  child: chat.loading
                      ? const Center(child: CircularProgressIndicator())
                      : chat.rows.isEmpty
                          ? const Center(
                              child: Text('暂无聊天步骤记录', style: TextStyle(color: LevityColors.textMuted)),
                            )
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
                _buildComposer(desktopOnline, chat.sending),
              ],
            ),

            // One-hand thumb floating bubble (scroll to bottom or one-tap confirm)
            if (_showScrollToBottom || needsConfirm)
              Positioned(
                right: 16,
                bottom: 84,
                child: _OneHandFloatingBubble(
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
      UserMessageRow() => Align(
          alignment: Alignment.centerRight,
          child: Container(
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF4F46E5), Color(0xFF6D28D9)],
              ),
              borderRadius: BorderRadius.circular(18),
            ),
            child: SelectableText(
              row.content,
              style: const TextStyle(fontSize: 14.2, height: 1.45, color: Colors.white),
            ),
          ),
        ),
      ProcessGroupRow() => _ProcessAccordionRow(row: row),
      AssistantMessageRow() => GlassCard(
          padding: const EdgeInsets.all(14),
          borderRadius: 18,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (row.modelDisplay.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    row.modelDisplay,
                    style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: LevityColors.purpleSubagent),
                  ),
                ),
              MarkdownBody(
                data: row.content,
                selectable: true,
                onTapLink: (text, href, _) {
                  if (href != null && href.startsWith('file://')) {
                    _openLocalFile(href, text);
                  }
                },
                styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                  p: const TextStyle(fontSize: 14.2, height: 1.52, color: LevityColors.textPrimary),
                  a: const TextStyle(color: LevityColors.blueUnread, decoration: TextDecoration.underline),
                  code: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12.5,
                    color: Color(0xFFC4B5FD),
                    backgroundColor: Color(0x332D2F4A),
                  ),
                  codeblockDecoration: BoxDecoration(
                    color: const Color(0xCC0E101D),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: LevityColors.cardBorder),
                  ),
                ),
              ),
              if (row.fileLinks.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final link in row.fileLinks)
                      ActionChip(
                        avatar: const Icon(Icons.article_outlined, size: 15, color: LevityColors.blueUnread),
                        label: Text(link.label, style: const TextStyle(fontSize: 12)),
                        backgroundColor: const Color(0x3360A5FA),
                        side: BorderSide.none,
                        onPressed: () => _openLocalFile('file://${link.path}', link.label),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      DecisionPromptRow() => GlassCard(
          padding: const EdgeInsets.all(14),
          borderRadius: 18,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.bolt_rounded, size: 16, color: LevityColors.orangeWarning),
                  SizedBox(width: 6),
                  Text('Agent 等待你拍板确认', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: LevityColors.orangeWarning)),
                ],
              ),
              const SizedBox(height: 10),
              for (final q in row.questions) ...[
                Text(q.question, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: LevityColors.textPrimary)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final opt in q.options)
                      FilledButton.tonal(
                        onPressed: () => _send(opt.replaceFirst('(Recommended) ', '')),
                        child: Text(opt, style: const TextStyle(fontSize: 12.5)),
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
          color: Color(0xDD101222),
          border: Border(top: BorderSide(color: LevityColors.cardBorder)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _inputCtrl,
                minLines: 1,
                maxLines: 4,
                style: const TextStyle(fontSize: 14.5, color: LevityColors.textPrimary),
                decoration: InputDecoration(
                  hintText: desktopOnline ? '回复 Agent 指令或确认决策...' : '桌面端未启动（只读浏览模式）',
                  hintStyle: const TextStyle(color: LevityColors.textMuted),
                  filled: true,
                  fillColor: const Color(0xFF1A1D32),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: sending ? null : () => _send(_inputCtrl.text),
              style: IconButton.styleFrom(backgroundColor: LevityColors.purpleSubagent),
              icon: sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.arrow_upward_rounded, color: Colors.white),
            ),
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
        color: const Color(0x661C1F33),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: LevityColors.cardBorder),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                children: [
                  const Icon(Icons.psychology_alt_outlined, size: 16, color: LevityColors.textMuted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.row.summaryLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, color: LevityColors.textSecondary),
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    size: 18,
                    color: LevityColors.textMuted,
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
                  const Divider(height: 12, color: LevityColors.cardBorder),
                  for (final item in widget.row.items) ...[
                    if (item.toolNames.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          '🔧 ${item.toolNames.join(" → ")}',
                          style: const TextStyle(fontSize: 12, color: LevityColors.purpleSubagent),
                        ),
                      ),
                    if (item.thinking.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          item.thinking,
                          style: const TextStyle(fontSize: 12, height: 1.45, color: LevityColors.textMuted),
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

class _OneHandFloatingBubble extends StatelessWidget {
  const _OneHandFloatingBubble({
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
    return GlassCapsule(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (needsConfirm)
            InkWell(
              onTap: onQuickConfirm,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle_rounded, size: 17, color: LevityColors.greenDirect),
                    SizedBox(width: 5),
                    Text('一键确认开工', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: LevityColors.textPrimary)),
                  ],
                ),
              ),
            ),
          if (needsConfirm && showScrollDown) const SizedBox(width: 6),
          if (showScrollDown)
            InkWell(
              onTap: onScrollBottom,
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.keyboard_double_arrow_down_rounded, size: 19, color: LevityColors.textPrimary),
              ),
            ),
        ],
      ),
    );
  }
}
