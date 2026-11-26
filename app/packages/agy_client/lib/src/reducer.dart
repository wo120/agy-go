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
    this.metadata = '',
  }) : super(keyId);

  final int stepIndex;
  final String content;
  final int createdAtUnix;
  final String metadata;
}

class ProcessStepSummary {
  const ProcessStepSummary({
    required this.stepIndex,
    this.thinking = '',
    this.toolNames = const [],
    this.outputTokens = 0,
    this.ttftMs = 0,
    this.streamTps = 0,
    this.e2eTps = 0,
  });

  final int stepIndex;
  final String thinking;
  final List<String> toolNames;
  final int outputTokens;
  final int ttftMs;
  final double streamTps;
  final double e2eTps;
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
    this.outputTokens = 0,
    this.ttftMs = 0,
    this.streamingMs = 0,
    this.streamTps = 0,
    this.e2eTps = 0,
    this.fileLinks = const [],
  }) : super(keyId);

  final int stepIndex;
  final String content;
  final int createdAtUnix;
  final String modelDisplay;
  final int outputTokens;
  final int ttftMs;
  final int streamingMs;
  final double streamTps;
  final double e2eTps;
  final List<LocalFileLink> fileLinks;

  bool get hasSpeedTelemetry => streamTps > 0 || e2eTps > 0;
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
        final parsed = parseUserInputContent(step.content);
        final meta = step.userMetadata.trim().isNotEmpty ? step.userMetadata.trim() : parsed.metadata;
        final ts = step.createdAtUnix > 0 ? step.createdAtUnix : (parsed.localTimeUnix ?? 0);
        if (parsed.text.isNotEmpty) {
          rows.add(
            UserMessageRow(
              keyId: 'user_${step.stepIndex}',
              stepIndex: step.stepIndex,
              content: parsed.text,
              createdAtUnix: ts,
              metadata: meta,
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
              outputTokens: step.outputTokens,
              ttftMs: step.ttftMs,
              streamTps: step.streamTps,
              e2eTps: step.e2eTps,
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
              outputTokens: step.outputTokens,
              ttftMs: step.ttftMs,
              streamingMs: step.streamingMs,
              streamTps: step.streamTps,
              e2eTps: step.e2eTps,
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

  static const List<String> _userInputTrailingTags = [
    'ADDITIONAL_METADATA',
    'USER_SETTINGS_CHANGE',
  ];

  /// Extracts clean user message, preserved metadata blocks, and local timestamp
  /// from Antigravity's wrapped USER_INPUT content while preserving nested tags.
  static ({String text, String metadata, int? localTimeUnix}) parseUserInputContent(String content) {
    final s = content.trim();
    if (!s.startsWith('<USER_REQUEST>')) {
      return (text: s, metadata: '', localTimeUnix: null);
    }
    var rest = s.substring('<USER_REQUEST>'.length);
    final blocksReversed = <String>[];
    int? localTimeUnix;

    while (true) {
      final trimmed = rest.trim();
      var stripped = false;
      for (final tag in _userInputTrailingTags) {
        final closeTag = '</$tag>';
        if (trimmed.endsWith(closeTag)) {
          final openTag = '<$tag>';
          final idx = trimmed.lastIndexOf(openTag);
          if (idx >= 0) {
            final inner = trimmed.substring(idx + openTag.length, trimmed.length - closeTag.length).trim();
            if (inner.isNotEmpty) {
              blocksReversed.add(inner);
              localTimeUnix ??= _parseAdditionalMetadataTime(inner);
            }
            rest = trimmed.substring(0, idx);
            stripped = true;
            break;
          }
        }
      }
      if (!stripped) {
        rest = trimmed;
        break;
      }
    }
    if (rest.endsWith('</USER_REQUEST>')) {
      rest = rest.substring(0, rest.length - '</USER_REQUEST>'.length);
    }
    return (
      text: rest.trim(),
      metadata: blocksReversed.reversed.join('\n\n'),
      localTimeUnix: localTimeUnix,
    );
  }

  static int? _parseAdditionalMetadataTime(String meta) {
    const prefix = 'The current local time is:';
    for (final rawLine in meta.split('\n')) {
      final line = rawLine.trim();
      if (!line.startsWith(prefix)) continue;
      var value = line.substring(prefix.length).trim();
      if (value.endsWith('.')) {
        value = value.substring(0, value.length - 1);
      }
      final dt = DateTime.tryParse(value);
      if (dt != null) {
        return dt.millisecondsSinceEpoch ~/ 1000;
      }
    }
    return null;
  }

  /// Strips Antigravity's outer <USER_REQUEST> wrapper and trailing metadata tags
  /// while preserving any nested tags pasted inside the user's actual message.
  static String cleanUserInputContent(String content) => parseUserInputContent(content).text;

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
