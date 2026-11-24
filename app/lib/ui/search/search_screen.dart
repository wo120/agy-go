import 'dart:async';

import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../theme/levity_theme.dart';
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
        title: TextField(
          controller: _ctrl,
          autofocus: true,
          onChanged: _onChanged,
          style: const TextStyle(color: LevityColors.textPrimary),
          decoration: const InputDecoration(
            hintText: '全文检索历史会话、项目与回复...',
            hintStyle: TextStyle(color: LevityColors.textMuted),
            border: InputBorder.none,
          ),
        ),
      ),
      body: LevityBackground(
        child: _searching
            ? const Center(child: CircularProgressIndicator())
            : _hits.isEmpty
                ? Center(
                    child: Text(
                      _ctrl.text.trim().isEmpty ? '输入关键词，直查 Antigravity 原生 FTS5 索引' : '未找到匹配会话',
                      style: const TextStyle(color: LevityColors.textMuted),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: _hits.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (ctx, idx) {
                      final h = _hits[idx];
                      return GlassCard(
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
                                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: LevityColors.textPrimary),
                                  ),
                                ),
                                Text(
                                  formatSessionTime(h.lastModifiedUnix),
                                  style: const TextStyle(fontSize: 11.5, color: LevityColors.textMuted),
                                ),
                              ],
                            ),
                            if (h.snippet.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(
                                h.snippet,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13, color: LevityColors.textSecondary),
                              ),
                            ],
                            if (h.workspace.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text('📁 ${h.workspace}', style: const TextStyle(fontSize: 11.5, color: LevityColors.textMuted)),
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
