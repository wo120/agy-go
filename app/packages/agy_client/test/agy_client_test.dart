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

    test('parses JSON-stringified ask_question.questions without throwing type cast error', () {
      const steps = [
        TranscriptStep(
          stepIndex: 61,
          source: 'MODEL',
          type: 'PLANNER_RESPONSE',
          status: 'DONE',
          createdAtUnix: 1005,
          toolCalls: [
            ToolCallItem(
              name: 'ask_question',
              args: {
                'questions':
                    '[{"is_multi_select":false,"options":["(Recommended) 全部提交","仅提交 README"],"question":"请问希望如何提交？"}]',
              },
            ),
          ],
        ),
        TranscriptStep(
          stepIndex: 62,
          source: 'MODEL',
          type: 'PLANNER_RESPONSE',
          status: 'DONE',
          createdAtUnix: 1006,
          toolCalls: [
            ToolCallItem(
              name: 'ask_question',
              args: {'questions': '[truncated invalid json'},
            ),
          ],
        ),
      ];

      final rows = TranscriptReducer.reduce(steps);
      expect(rows.length, 1);
      final dec = rows.first as DecisionPromptRow;
      expect(dec.questions.length, 1);
      expect(dec.questions.first.question, '请问希望如何提交？');
      expect(dec.questions.first.options, ['(Recommended) 全部提交', '仅提交 README']);
      expect(dec.questions.first.multiSelect, isFalse);
    });

    test('extracts latest update_steps todo list and omits it from process capsules', () {
      const steps = [
        TranscriptStep(
          stepIndex: 0,
          source: 'MODEL',
          type: 'PLANNER_RESPONSE',
          status: 'DONE',
          createdAtUnix: 1000,
          toolCalls: [
            ToolCallItem(
              name: 'update_steps',
              args: {
                'steps': '[{"status":"in_progress","title":"第一步"},{"status":"pending","title":"第二步"}]',
              },
            ),
          ],
        ),
        TranscriptStep(
          stepIndex: 1,
          source: 'MODEL',
          type: 'PLANNER_RESPONSE',
          status: 'DONE',
          createdAtUnix: 1001,
          thinking: '继续推进',
          toolCalls: [
            ToolCallItem(name: 'read_file'),
            ToolCallItem(
              name: 'update_steps',
              args: {
                'steps': [
                  {'status': 'done', 'title': '第一步'},
                  {'status': 'in_progress', 'title': '第二步'},
                ],
              },
            ),
          ],
        ),
      ];

      final rows = TranscriptReducer.reduce(steps);
      expect(rows.length, 1);
      final proc = rows.first as ProcessGroupRow;
      expect(proc.toolNames, ['read_file']);

      final todos = TranscriptReducer.extractLatestTodoSteps(steps);
      expect(todos.length, 2);
      expect(todos[0].title, '第一步');
      expect(todos[0].status, 'done');
      expect(todos[1].title, '第二步');
      expect(todos[1].status, 'in_progress');
    });

    test('strips outer USER_REQUEST while preserving metadata and local send time', () {
      const steps = [
        TranscriptStep(
          stepIndex: 0,
          source: 'USER_EXPLICIT',
          type: 'USER_INPUT',
          status: 'DONE',
          createdAtUnix: 0,
          content: '<USER_REQUEST>\n先优化\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nThe current local time is: 2026-11-25T02:59:10-05:00.\n</ADDITIONAL_METADATA>',
        ),
        TranscriptStep(
          stepIndex: 1,
          source: 'USER_EXPLICIT',
          type: 'USER_INPUT',
          status: 'DONE',
          createdAtUnix: 1001,
          content: '<USER_REQUEST>\n显示：<USER_REQUEST>\n先优化\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\n02:59\n</ADDITIONAL_METADATA>\n修复这两个问题\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\n03:39\n</ADDITIONAL_METADATA>\n<USER_SETTINGS_CHANGE>\nchanged\n</USER_SETTINGS_CHANGE>',
        ),
        TranscriptStep(
          stepIndex: 2,
          source: 'USER_EXPLICIT',
          type: 'USER_INPUT',
          status: 'DONE',
          createdAtUnix: 1795597636,
          content: '服务端已清洗',
          userMetadata: 'The current local time is: 2026-11-25T04:07:16-05:00.',
        ),
      ];

      final rows = TranscriptReducer.reduce(steps);
      expect(rows.length, 3);
      final r0 = rows[0] as UserMessageRow;
      expect(r0.content, '先优化');
      expect(r0.createdAtUnix, 1795593550);
      expect(r0.metadata, 'The current local time is: 2026-11-25T02:59:10-05:00.');

      final r1 = rows[1] as UserMessageRow;
      expect(
        r1.content,
        '显示：<USER_REQUEST>\n先优化\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\n02:59\n</ADDITIONAL_METADATA>\n修复这两个问题',
      );
      expect(r1.metadata, '03:39\n\nchanged');

      final r2 = rows[2] as UserMessageRow;
      expect(r2.content, '服务端已清洗');
      expect(r2.metadata, 'The current local time is: 2026-11-25T04:07:16-05:00.');
    });
    test('ModelOption parses familyName, variantName, and HostInfo models', () {
      final host = HostInfo.fromJson({
        'desktopOnline': true,
        'workspaces': [
          {'kind': 'workspace', 'label': 'antigravity-mobile', 'rootPath': '/tmp/app'},
        ],
        'models': [
          {
            'modelId': 'gemini-4-neon-high',
            'label': 'Gemini 4 Neon (High)',
            'poolId': 'gemini',
            'tag': 'New',
            'isDefault': true,
          },
          {
            'modelId': 'claude-opus-5-5-medium',
            'label': 'Claude Opus 5.5 (Medium)',
            'poolId': 'claude_gpt',
          },
        ],
      });

      expect(host.desktopOnline, isTrue);
      expect(host.workspaces.length, 1);
      expect(host.models.length, 2);
      expect(host.models.first.familyName, 'Gemini 4 Neon');
      expect(host.models.first.variantName, 'High');
      expect(host.models.first.isDefault, isTrue);
      expect(host.models.last.familyName, 'Claude Opus 5.5');
      expect(host.models.last.variantName, 'Medium');
      expect(host.models.last.poolId, 'claude_gpt');
    });

    test('TpsSnapshot parses 5h metrics and TranscriptReducer propagates per-step speed telemetry', () {
      final snap = TpsSnapshot.fromJson({
        'updatedAt': 1795600000,
        'windowSeconds': 18000,
        'sampleCount': 12,
        'streamSamples': 10,
        'outputTokens': 15200,
        'streamTps': 143.5,
        'e2eTps': 78.2,
        'avgTtftMs': 6400,
        'latest': {
          'conversationId': 'c-1',
          'stepIndex': 8,
          'createdAtUnix': 1795599990,
          'poolId': 'gemini',
          'model': 'gemini-4-neon',
          'modelDisplay': 'Gemini 4 Neon (High)',
          'outputTokens': 1600,
          'ttftMs': 6200,
          'streamingMs': 10500,
          'streamTps': 152.4,
          'e2eTps': 95.8,
        },
        'models': [
          {
            'model': 'gemini-4-neon',
            'modelDisplay': 'Gemini 4 Neon (High)',
            'poolId': 'gemini',
            'sampleCount': 10,
            'streamSamples': 8,
            'outputTokens': 12000,
            'streamTps': 148.0,
            'e2eTps': 80.5,
            'avgTtftMs': 6800,
            'lastActiveUnix': 1795599990,
          },
        ],
      });

      expect(snap.hasData, isTrue);
      expect(snap.streamTps, 143.5);
      expect(snap.e2eTps, 78.2);
      expect(snap.avgTtftMs, 6400);
      expect(snap.latest?.modelDisplay, 'Gemini 4 Neon (High)');
      expect(snap.latest?.streamTps, 152.4);
      expect(snap.models.length, 1);
      expect(snap.models.first.streamTps, 148.0);

      final step = TranscriptStep.fromJson({
        'step_index': 8,
        'source': 'MODEL',
        'type': 'PLANNER_RESPONSE',
        'status': 'DONE',
        'created_at_unix': 1795599990,
        'model_display': 'Neon · High',
        'content': '已实现 TPS 监控。',
        'output_tokens': 1600,
        'ttft_ms': 6200,
        'streaming_ms': 10500,
        'stream_tps': 152.4,
        'e2e_tps': 95.8,
      });
      final rows = TranscriptReducer.reduce([step]);
      expect(rows.length, 1);
      final asst = rows.first as AssistantMessageRow;
      expect(asst.hasSpeedTelemetry, isTrue);
      expect(asst.streamTps, 152.4);
      expect(asst.e2eTps, 95.8);
      expect(asst.ttftMs, 6200);
      expect(asst.outputTokens, 1600);
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

    test('PendingInteraction parses permission and ask_question payloads', () {
      final perm = PendingInteraction.fromJson({
        'conversationId': 'conv-1',
        'trajectoryId': 'traj-1',
        'stepIndex': 8,
        'kind': 'permission',
        'toolName': 'run_command',
        'permission': {
          'action': 'command',
          'target': 'ps -eo pid,comm,args',
          'actionDescription': '检查当前运行进程',
          'suggestedPersistPattern': 'ps',
          'allowPersist': true,
          'shellName': 'zsh',
        },
      });
      expect(perm.isPermission, isTrue);
      expect(perm.permission?.actionLabel, '终端命令');
      expect(perm.permission?.persistPattern, 'ps');
      expect(perm.permission?.allowPersist, isTrue);

      final ask = PendingInteraction.fromJson({
        'conversationId': 'conv-2',
        'trajectoryId': 'traj-2',
        'stepIndex': 12,
        'kind': 'ask_question',
        'askQuestion': {
          'questions': [
            {
              'question': '继续执行吗？',
              'options': [
                {'id': '1', 'text': '确认'},
                {'id': '2', 'text': '取消'},
              ],
            },
          ],
        },
      });
      expect(ask.isAskQuestion, isTrue);
      expect(ask.questions.single.options.first.id, '1');
    });
  });
}
