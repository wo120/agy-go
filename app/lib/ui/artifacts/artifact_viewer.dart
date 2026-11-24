import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../theme/levity_theme.dart';

/// Opens a modal bottom sheet listing all artifacts in the conversation's brain directory.
Future<void> showArtifactsDrawer(
  BuildContext context, {
  required String conversationId,
  required List<ArtifactItem> artifacts,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF15172A),
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) {
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.55,
        minChildSize: 0.35,
        maxChildSize: 0.9,
        builder: (ctx, scrollCtrl) {
          return Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0x44FFFFFF),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
                child: Row(
                  children: [
                    const Icon(Icons.description_outlined, size: 18, color: LevityColors.purpleSubagent),
                    const SizedBox(width: 8),
                    Text('会话产物 (${artifacts.length})', style: Theme.of(ctx).textTheme.titleMedium),
                  ],
                ),
              ),
              Expanded(
                child: artifacts.isEmpty
                    ? const Center(child: Text('该会话暂无产物文件', style: TextStyle(color: LevityColors.textMuted)))
                    : ListView.separated(
                        controller: scrollCtrl,
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                        itemCount: artifacts.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (ctx, idx) {
                          final item = artifacts[idx];
                          return GlassCard(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            borderRadius: 16,
                            onTap: () {
                              Navigator.of(ctx).pop();
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => ArtifactViewerPage(
                                    conversationId: conversationId,
                                    path: item.fullPath,
                                    displayName: item.name,
                                    kindHint: item.kind,
                                  ),
                                ),
                              );
                            },
                            child: Row(
                              children: [
                                Icon(_iconForKind(item.kind), size: 20, color: LevityColors.purpleSubagent),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        item.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: LevityColors.textPrimary),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        '${item.relPath} · ${_formatSize(item.sizeBytes)}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 11.5, color: LevityColors.textMuted),
                                      ),
                                    ],
                                  ),
                                ),
                                const Icon(Icons.chevron_right_rounded, color: LevityColors.textMuted),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      );
    },
  );
}

IconData _iconForKind(String kind) {
  switch (kind) {
    case 'markdown':
      return Icons.article_outlined;
    case 'image':
      return Icons.image_outlined;
    case 'code':
      return Icons.code_rounded;
    case 'pdf':
      return Icons.picture_as_pdf_outlined;
    default:
      return Icons.insert_drive_file_outlined;
  }
}

String _formatSize(int bytes) {
  if (bytes < 1024) return '${bytes}B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
}

/// Native viewer for Brain artifacts and workspace file:// references.
class ArtifactViewerPage extends ConsumerStatefulWidget {
  const ArtifactViewerPage({
    super.key,
    required this.conversationId,
    required this.path,
    required this.displayName,
    this.kindHint,
  });

  final String conversationId;
  final String path;
  final String displayName;
  final String? kindHint;

  @override
  ConsumerState<ArtifactViewerPage> createState() => _ArtifactViewerPageState();
}

class _ArtifactViewerPageState extends ConsumerState<ArtifactViewerPage> {
  TextContentPage? _page;
  String _accumulated = '';
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  bool get _isImageHint {
    if (widget.kindHint == 'image') return true;
    final lower = widget.path.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif');
  }

  @override
  void initState() {
    super.initState();
    if (_isImageHint) {
      _loading = false;
    } else {
      _loadChunk(0);
    }
  }

  Future<void> _loadChunk(int offset) async {
    final carrier = ref.read(hostConnectionProvider.notifier).carrier;
    if (carrier == null) {
      setState(() {
        _loading = false;
        _error = '主机未连接';
      });
      return;
    }
    try {
      final p = await carrier.fetchFileContent(widget.conversationId, widget.path, offset: offset);
      if (!mounted) return;
      setState(() {
        _page = p;
        _accumulated = offset == 0 ? p.content : (_accumulated + p.content);
        _loading = false;
        _loadingMore = false;
        _error = null;
      });
    } on BridgeRemoteException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final carrier = ref.read(hostConnectionProvider.notifier).carrier;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.displayName, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
            Text(
              widget.path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: LevityColors.textMuted),
            ),
          ],
        ),
        actions: [
          if (!_isImageHint && _accumulated.isNotEmpty)
            IconButton(
              tooltip: '复制内容',
              icon: const Icon(Icons.copy_rounded, size: 20),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _accumulated));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已复制文件内容')),
                );
              },
            ),
        ],
      ),
      body: LevityBackground(
        child: _isImageHint && carrier != null
            ? Center(
                child: InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 5.0,
                  child: Image.network(
                    carrier.buildRawFileUri(widget.conversationId, widget.path).toString(),
                    headers: {'Authorization': 'Bearer ${carrier.token}'},
                    loadingBuilder: (ctx, child, progress) {
                      if (progress == null) return child;
                      return const CircularProgressIndicator();
                    },
                    errorBuilder: (ctx, err, _) => Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('图片加载失败：$err', style: const TextStyle(color: LevityColors.orangeWarning)),
                    ),
                  ),
                ),
              )
            : _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: GlassCard(
                            child: Text(_error!, style: const TextStyle(color: LevityColors.orangeWarning)),
                          ),
                        ),
                      )
                    : _buildTextBody(),
      ),
    );
  }

  Widget _buildTextBody() {
    final isMarkdown = _page?.kind == 'markdown';
    return Column(
      children: [
        Expanded(
          child: isMarkdown
              ? Markdown(
                  data: _accumulated,
                  selectable: true,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                  styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                    p: const TextStyle(fontSize: 14.5, height: 1.55, color: LevityColors.textPrimary),
                    code: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12.5,
                      color: Color(0xFFC4B5FD),
                      backgroundColor: Color(0x332D2F4A),
                    ),
                    codeblockDecoration: BoxDecoration(
                      color: const Color(0xCC111322),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: LevityColors.cardBorder),
                    ),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SelectableText(
                      _accumulated,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12.5,
                        height: 1.5,
                        color: LevityColors.textPrimary,
                      ),
                    ),
                  ),
                ),
        ),
        if (_page?.truncated == true)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: _loadingMore
                      ? null
                      : () {
                          setState(() => _loadingMore = true);
                          _loadChunk(_accumulated.length);
                        },
                  child: Text(
                    _loadingMore
                        ? '正在加载下一段...'
                        : '加载更多（已显示 ${_formatSize(_accumulated.length)} / ${_formatSize(_page!.totalBytes)}）',
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
