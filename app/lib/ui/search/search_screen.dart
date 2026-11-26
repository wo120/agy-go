import 'dart:async';

import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../theme/agy_theme.dart';
import '../chat/chat_screen.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final TextEditingController _ctrl = TextEditingController();
  Timer? _debounce;
  List<SearchHit> _hits = const [];
  bool _searching = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 280), () => _runSearch(q));
  }

  Future<void> _runSearch(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      setState(() => _hits = const []);
      return;
    }
    final carrier = ref.read(hostConnectionProvider.notifier).carrier;
    if (carrier == null) return;
    setState(() => _searching = true);
    try {
      final res = await carrier.searchSessions(trimmed);
      if (mounted) setState(() => _hits = res);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.only(right: 12),
          child: TextField(
            controller: _ctrl,
            autofocus: true,
            onChanged: _onChanged,
            style: const TextStyle(fontSize: 14.5, color: AgyColors.textPrimary),
            decoration: InputDecoration(
              hintText: '全文检索历史会话、项目与回复...',
              hintStyle: const TextStyle(color: AgyColors.textMuted, fontSize: 14),
              filled: true,
              fillColor: AgyColors.bgSubtle,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              suffixIcon: _ctrl.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.close_rounded, size: 17, color: AgyColors.textMuted),
                      onPressed: () {
                        _ctrl.clear();
                        _onChanged('');
                      },
                    )
                  : null,
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AgyColors.borderHairline),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AgyColors.accent, width: 1.2),
              ),
            ),
          ),
        ),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: AgyColors.borderHairline),
        ),
      ),
      body: AgyCanvas(
        child: _searching
            ? const Center(child: CircularProgressIndicator(color: AgyColors.accentBright, strokeWidth: 2.2))
            : _hits.isEmpty
                ? Center(
                    child: Text(
                      _ctrl.text.trim().isEmpty ? '输入关键词，直查 Antigravity 原生 FTS5 索引' : '未找到匹配会话',
                      style: const TextStyle(color: AgyColors.textMuted),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: _hits.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (ctx, idx) {
                      final h = _hits[idx];
                      return ConsolePanel(
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => ChatScreen(conversationId: h.conversationId)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    h.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      color: AgyColors.textPrimary,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  formatSessionTime(h.lastModifiedUnix),
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    fontFamily: 'monospace',
                                    fontFeatures: kTabularFigures,
                                    color: AgyColors.textMuted,
                                  ),
                                ),
                              ],
                            ),
                            if (h.snippet.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(
                                h.snippet,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13, height: 1.42, color: AgyColors.textSecondary),
                              ),
                            ],
                            if (h.workspace.isNotEmpty) ...[
                              const SizedBox(height: 9),
                              AgyTag(
                                icon: Icons.folder_outlined,
                                label: h.workspace,
                                color: AgyColors.textSecondary,
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
