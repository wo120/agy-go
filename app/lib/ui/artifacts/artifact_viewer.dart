import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../theme/agy_theme.dart';

/// Opens a modal bottom sheet listing all artifacts in the conversation's brain directory.
Future<void> showArtifactsDrawer(
  BuildContext context, {
  required String conversationId,
  required List<ArtifactItem> artifacts,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AgyColors.bgDock,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      side: BorderSide(color: AgyColors.borderStrong),
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
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AgyColors.borderStrong,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
                child: Row(
                  children: [
                    const Icon(Icons.description_outlined, size: 18, color: AgyColors.accentBright),
                    const SizedBox(width: 8),
                    Text('会话产物 (${artifacts.length})', style: Theme.of(ctx).textTheme.titleMedium),
                  ],
                ),
              ),
              const Divider(height: 1, color: AgyColors.borderHairline),
              Expanded(
                child: artifacts.isEmpty
                    ? const Center(child: Text('该会话暂无产物文件', style: TextStyle(color: AgyColors.textMuted)))
                    : ListView.separated(
                        controller: scrollCtrl,
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                        itemCount: artifacts.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (ctx, idx) {
                          final item = artifacts[idx];
                          return ConsolePanel(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                            borderRadius: 10,
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
                                Container(
                                  width: 34,
                                  height: 34,
                                  decoration: BoxDecoration(
                                    color: AgyColors.bgSubtle,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: AgyColors.borderHairline),
                                  ),
                                  child: Icon(_iconForKind(item.kind), size: 18, color: AgyColors.accentBright),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        item.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: AgyColors.textPrimary,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        '${item.relPath} · ${_formatSize(item.sizeBytes)}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 11.5,
                                          fontFamily: 'monospace',
                                          fontFeatures: kTabularFigures,
                                          color: AgyColors.textMuted,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const Icon(Icons.chevron_right_rounded, color: AgyColors.textMuted),
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
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.displayName, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
            Text(
              widget.path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: AgyColors.textMuted),
            ),
          ],
        ),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: AgyColors.borderHairline),
        ),
        actions: [
          if (!_isImageHint && _accumulated.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: AgyIconAction(
                tooltip: '复制内容',
                icon: Icons.copy_rounded,
                size: 34,
                onTap: () {
                  Clipboard.setData(ClipboardData(text: _accumulated));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已复制文件内容')),
                  );
                },
              ),
            ),
        ],
      ),
      body: AgyCanvas(
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
                      return const CircularProgressIndicator(color: AgyColors.accentBright);
                    },
                    errorBuilder: (ctx, err, _) => Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('图片加载失败：$err', style: const TextStyle(color: AgyColors.warning)),
                    ),
                  ),
                ),
              )
            : _loading
                ? const Center(child: CircularProgressIndicator(color: AgyColors.accentBright, strokeWidth: 2.2))
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: ConsolePanel(
                            accentStripeColor: AgyColors.warning,
                            child: Text(_error!, style: const TextStyle(color: AgyColors.warning)),
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
                    p: const TextStyle(fontSize: 14.5, height: 1.56, color: AgyColors.textPrimary),
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
                        color: AgyColors.textPrimary,
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
