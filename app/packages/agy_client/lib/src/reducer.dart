import 'dart:convert';

import 'models.dart';

class LocalFileLink {
  const LocalFileLink({required this.label, required this.path});

  final String label;
  final String path;
}

sealed class ChatRow {
  const ChatRow(this.keyId);
  final String keyId;
}

class UserMessageRow extends ChatRow {
  const UserMessageRow({
    required String keyId,
    required this.stepIndex,
    required this.content,
    required this.createdAtUnix,
  }) : super(keyId);

  final int stepIndex;
  final String content;
  final int createdAtUnix;
}

class ProcessStepSummary {
  const ProcessStepSummary({
    required this.stepIndex,
    this.thinking = '',
    this.toolNames = const [],
  });

  final int stepIndex;
  final String thinking;
  final List<String> toolNames;
}

/// Collapsed single-line capsule representing consecutive thinking and tool calls.
class ProcessGroupRow extends ChatRow {
  const ProcessGroupRow({
    required String keyId,
    required this.items,
    required this.thinkingCount,
    required this.toolNames,
  }) : super(keyId);

  final List<ProcessStepSummary> items;
  final int thinkingCount;
  final List<String> toolNames;

  String get summaryLine {
    final parts = <String>[];
    if (thinkingCount > 0) {
      parts.add('思考 $thinkingCount 轮');
    }
    if (toolNames.isNotEmpty) {
      final preview = toolNames.take(3).join(', ');
      final extra = toolNames.length > 3 ? ' 等 ${toolNames.length} 次工具' : ' (${toolNames.length})';
      parts.add('调用 $preview$extra');
    }
    return parts.isEmpty ? '执行内部步骤' : parts.join(' · ');
  }
}

class AssistantMessageRow extends ChatRow {
  const AssistantMessageRow({
    required String keyId,
    required this.stepIndex,
    required this.content,
    required this.createdAtUnix,
    this.modelDisplay = '',
    this.fileLinks = const [],
  }) : super(keyId);

  final int stepIndex;
  final String content;
  final int createdAtUnix;
  final String modelDisplay;
  final List<LocalFileLink> fileLinks;
}

class DecisionQuestion {
  const DecisionQuestion({
    required this.question,
    required this.options,
    this.multiSelect = false,
  });

  final String question;
  final List<String> options;
  final bool multiSelect;
}

class DecisionPromptRow extends ChatRow {
  const DecisionPromptRow({
    required String keyId,
    required this.stepIndex,
    required this.questions,
  }) : super(keyId);

  final int stepIndex;
  final List<DecisionQuestion> questions;
}

class TranscriptReducer {
  static final RegExp _fileLinkRegex = RegExp(r'\[([^\]]+)\]\((file://[^)\s]+)\)');

  /// Extracts all markdown [label](file:///...) references from message text.
  static List<LocalFileLink> extractFileLinks(String markdown) {
    final out = <LocalFileLink>[];
    final seen = <String>{};
    for (final m in _fileLinkRegex.allMatches(markdown)) {
      final label = m.group(1) ?? '';
      final rawUri = m.group(2) ?? '';
      final path = Uri.decodeFull(rawUri.replaceFirst('file://', '').split('#').first);
      if (path.isNotEmpty && seen.add(path)) {
        out.add(LocalFileLink(label: label, path: path));
      }
    }
    return out;
  }

  /// Reduces raw JSONL steps into render-ready rows with automatic process collapsing.
  static List<ChatRow> reduce(List<TranscriptStep> steps) {
    final rows = <ChatRow>[];
    final pendingProcess = <ProcessStepSummary>[];

    void flushProcess() {
      if (pendingProcess.isEmpty) return;
      var thinkCount = 0;
      final tools = <String>[];
      for (final p in pendingProcess) {
        if (p.thinking.trim().isNotEmpty) thinkCount++;
        tools.addAll(p.toolNames);
      }
      if (thinkCount > 0 || tools.isNotEmpty) {
        final firstIdx = pendingProcess.first.stepIndex;
        final lastIdx = pendingProcess.last.stepIndex;
        rows.add(
          ProcessGroupRow(
            keyId: 'proc_${firstIdx}_$lastIdx',
            items: List<ProcessStepSummary>.from(pendingProcess),
            thinkingCount: thinkCount,
            toolNames: tools,
          ),
        );
      }
      pendingProcess.clear();
    }

    for (final step in steps) {
      if (step.type == 'USER_INPUT') {
        flushProcess();
        final text = step.content.trim();
        if (text.isNotEmpty) {
          rows.add(
            UserMessageRow(
              keyId: 'user_${step.stepIndex}',
              stepIndex: step.stepIndex,
              content: text,
              createdAtUnix: step.createdAtUnix,
            ),
          );
        }
        continue;
      }

      if (step.type == 'PLANNER_RESPONSE') {
        final nonQuestionTools = <String>[];
        final decisionQuestions = <DecisionQuestion>[];

        for (final tc in step.toolCalls) {
          if (tc.name == 'ask_question') {
            final qs = _decodeJsonList(tc.args['questions']);
            for (final q in qs.whereType<Map<String, dynamic>>()) {
              final qText = q['question'] is String ? q['question'] as String : '';
              final opts = _decodeJsonList(q['options']).map((e) => e.toString()).toList();
              if (qText.isNotEmpty && opts.isNotEmpty) {
                decisionQuestions.add(
                  DecisionQuestion(
                    question: qText,
                    options: opts,
                    multiSelect: q['is_multi_select'] == true || q['is_multi_select'] == 'true',
                  ),
                );
              }
            }
          } else if (tc.name.isNotEmpty) {
            nonQuestionTools.add(tc.name);
          }
        }

        if (step.thinking.trim().isNotEmpty || nonQuestionTools.isNotEmpty) {
          pendingProcess.add(
            ProcessStepSummary(
              stepIndex: step.stepIndex,
              thinking: step.thinking.trim(),
              toolNames: nonQuestionTools,
            ),
          );
        }

        final visibleContent = step.content.trim();
        if (visibleContent.isNotEmpty) {
          flushProcess();
          rows.add(
            AssistantMessageRow(
              keyId: 'asst_${step.stepIndex}',
              stepIndex: step.stepIndex,
              content: visibleContent,
              createdAtUnix: step.createdAtUnix,
              modelDisplay: step.modelDisplay,
              fileLinks: extractFileLinks(visibleContent),
            ),
          );
        }

        if (decisionQuestions.isNotEmpty) {
          flushProcess();
          rows.add(
            DecisionPromptRow(
              keyId: 'dec_${step.stepIndex}',
              stepIndex: step.stepIndex,
              questions: decisionQuestions,
            ),
          );
        }
      }
    }

    flushProcess();
    return rows;
  }

  static List<dynamic> _decodeJsonList(dynamic raw) {
    if (raw is List) return raw;
    if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.startsWith('[')) {
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is List) return decoded;
        } catch (_) {
          // Malformed or truncated JSON string: ignore safely rather than crashing chat view.
        }
      }
    }
    return const [];
  }
}
