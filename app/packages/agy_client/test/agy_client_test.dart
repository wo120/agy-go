import 'package:agy_client/agy_client.dart';
import 'package:test/test.dart';

void main() {
  group('TranscriptReducer', () {
    test('collapses consecutive thinking/tool calls and extracts file:// links', () {
      const steps = [
        TranscriptStep(
          stepIndex: 0,
          source: 'USER_EXPLICIT',
          type: 'USER_INPUT',
          status: 'DONE',
          createdAtUnix: 1000,
          content: '帮我分析一下架构',
        ),
        TranscriptStep(
          stepIndex: 1,
          source: 'MODEL',
          type: 'PLANNER_RESPONSE',
          status: 'DONE',
          createdAtUnix: 1001,
          thinking: '先读一下规范文档',
          toolCalls: [ToolCallItem(name: 'read_file')],
        ),
        TranscriptStep(
          stepIndex: 2,
          source: 'MODEL',
          type: 'PLANNER_RESPONSE',
          status: 'DONE',
          createdAtUnix: 1002,
          thinking: '再检查测试目录',
          toolCalls: [ToolCallItem(name: 'batch_search')],
        ),
        TranscriptStep(
          stepIndex: 3,
          source: 'MODEL',
          type: 'PLANNER_RESPONSE',
          status: 'DONE',
          createdAtUnix: 1003,
          modelDisplay: 'Neon · XHigh',
          content: '已整理完成，请查看 [design.md](file:///Users/apple/design.md#L1-L20)。',
        ),
        TranscriptStep(
          stepIndex: 4,
          source: 'MODEL',
          type: 'PLANNER_RESPONSE',
          status: 'DONE',
          createdAtUnix: 1004,
          toolCalls: [
            ToolCallItem(
              name: 'ask_question',
              args: {
                'questions': [
                  {
                    'question': '确认直接开工吗？',
                    'options': ['(Recommended) 直接开工', '再讨论一下'],
                  }
                ],
              },
            ),
          ],
        ),
      ];

      final rows = TranscriptReducer.reduce(steps);
      expect(rows.length, 4);
      expect(rows[0], isA<UserMessageRow>());
      final proc = rows[1] as ProcessGroupRow;
      expect(proc.thinkingCount, 2);
      expect(proc.toolNames, ['read_file', 'batch_search']);

      final asst = rows[2] as AssistantMessageRow;
      expect(asst.fileLinks.length, 1);
      expect(asst.fileLinks.first.path, '/Users/apple/design.md');

      final dec = rows[3] as DecisionPromptRow;
      expect(dec.questions.first.options.length, 2);
    });
  });

  group('MuxSeqTracker & Direct IP classification', () {
    test('detects out-of-order seq drops for resync', () {
      final tracker = MuxSeqTracker();
      expect(tracker.acceptSnapshot('gen_1', 1), isTrue);
      expect(tracker.acceptEvent('gen_1', 2), isTrue);
      expect(tracker.acceptEvent('gen_1', 4), isFalse); // gap -> trigger resync
      expect(tracker.acceptEvent('gen_2', 3), isFalse); // generation mismatch
    });

    test('identifies LAN and Tailscale direct endpoints', () {
      expect(isDirectEndpointUrl('http://192.168.1.20:8765'), isTrue);
      expect(isDirectEndpointUrl('http://100.100.10.5:8765'), isTrue);
      expect(isDirectEndpointUrl('https://bridge.example.com'), isFalse);
    });
  });
}
