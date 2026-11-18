import 'dart:convert';

import 'package:gel/gel.dart' as gel;
import 'package:http/http.dart' as http;
import 'package:maia_api/src/agent.dart';
import 'package:maia_api/src/chat/tools.dart';
import 'package:maia_api/src/chat/turn.dart';
import 'package:maia_api/src/harness/harness.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

void main() {
  test('fifty turns each read the tools for that step', () async {
    final box = _box();
    final script = _Script((body) {
      final last = (body['messages'] as List).last as Map<String, dynamic>;
      final task = _task(body);
      final ran = _toolMessages(body);
      if (ran == 0) {
        expect('${last['content']}', task);
      } else {
        expect(last['role'], 'system');
        expect('${last['content']}', contains('latest message'));
        expect('${last['content']}', isNot(contains('Step ')));
      }
      if (task.startsWith('clock') && ran == 0) {
        return _call('now', '{}', 'c$task');
      }
      return _say('pong');
    });
    final harness = _harness(script);
    var clocks = 0;
    for (var i = 0; i < 50; i++) {
      final task = i.isOdd ? 'clock $i' : 'say $i';
      final turn = await runChatTurn(
        harness: harness,
        frame: [
          {'role': 'user', 'content': task},
        ],
        toolbox: box,
        db: _Db(),
        emit: (event, data) {
          if (event == 'tool' && (data as Map)['name'] == 'now') clocks++;
        },
      );
      expect(turn.text, 'pong', reason: task);
    }
    expect(clocks, 25);
    expect(script.requests, greaterThanOrEqualTo(50));
  });

  test('the same call does not run again', () async {
    final script = _Script((_) => _call('now', '{}', 'spin'));
    final used = await _run(script, 'spin');
    expect(used.where((call) => call['name'] == 'now'), hasLength(1));
    expect(script.requests, 3);
  });

  test('a turn stops at the step budget', () async {
    final script = _Script((body) {
      final n = _toolMessages(body);
      return _call('now', '{"n":$n}', 'b$n');
    });
    final used = await _run(script, 'keep going');
    expect(used, hasLength(chatStepBudget));
    expect(script.requests, chatStepBudget + 1);
  });

  test('a tool that is off is not run', () async {
    final script = _Script((body) {
      if (_toolMessages(body) == 0) return _call('connector', '{}', 'nope');
      return _say('done');
    });
    final used = await _run(script, 'mail');
    expect(used.single['name'], 'connector');
    expect(used.single['result'], contains('not available'));
    expect(used.single['result'], contains('now'));
  });

  test('the next step sees a tool that was switched off', () async {
    final disabled = <String>{};
    final box = _box(
      disabled: disabled,
      onSearch: () {
        disabled.add('memory_recent');
      },
    );
    final script = _Script((body) {
      final offered = _offered(body);
      if (_toolMessages(body) == 0) {
        expect(offered, contains('memory_recent'));
        return _call('memory_search', '{"query":"lisbon"}', 's');
      }
      expect(offered, isNot(contains('memory_recent')));
      return _say('found');
    });
    final turn = await runChatTurn(
      harness: _harness(script),
      frame: [
        {'role': 'user', 'content': 'lisbon'},
      ],
      toolbox: box,
      db: _Db(),
      emit: (_, _) {},
    );
    expect(turn.text, 'found');
    expect(turn.tools.single['name'], 'memory_search');
  });

  test('extra calls wait for a later step', () async {
    final script = _Script((body) {
      if (_toolMessages(body) == 0) {
        return _calls(const [
          ('now', '{}', 'a'),
          ('memory_search', '{"query":"x"}', 'b'),
        ]);
      }
      return _say('ok');
    });
    final used = await _run(script, 'both');
    expect(used.map((call) => call['name']), ['now', 'memory_search']);
    expect(used.last['result'], heldStepResult);
  });

  test('the web waits until memory has been checked', () async {
    final search = _Json((request) {
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': 'a public headline'},
            },
          ],
        }),
        200,
      );
    });
    final box = ChatToolbox(
      searchMemory: (c, query, limit) async => [],
      recentMemory: (c, limit) async => [],
      getMemory: (c, id) async => null,
      remember: (c, title, body) async => '',
      lifeGraph: (c) async => null,
      openRouterApiKey: 'sk-or-test',
      httpClient: search,
    );
    final script = _Script((body) {
      final ran = _toolMessages(body);
      if (ran == 0) return _call('web_search', '{"query":"news"}', 'w');
      final tools = [
        for (final message in body['messages'] as List)
          if (message is Map && message['role'] == 'tool') message,
      ];
      expect('${tools.first['content']}', contains('Checked memory'));
      if (ran == 1) return _call('web_search', '{"query":"news"}', 'w2');
      return _say('the headline');
    });
    final turn = await runChatTurn(
      harness: _harness(script),
      frame: [
        {'role': 'user', 'content': 'what is new'},
      ],
      toolbox: box,
      db: _Db(),
      emit: (_, _) {},
    );
    expect(turn.tools.map((call) => call['name']), [
      'memory_search',
      'web_search',
      'web_search',
    ]);
    expect(turn.tools[1]['result'], contains('Checked memory'));
    expect(turn.tools.last['result'], contains('a public headline'));
    expect(turn.text, 'the headline');
  });

  test('an empty memory still runs the connector in the same step', () async {
    var connectorCalls = 0;
    final box = ChatToolbox(
      searchMemory: (c, query, limit) async => [],
      recentMemory: (c, limit) async => [],
      getMemory: (c, id) async => null,
      remember: (c, title, body) async => '',
      lifeGraph: (c) async => null,
      connector: (args) async {
        connectorCalls++;
        expect(args['platform'], 'github');
        return jsonEncode({
          'type': 'text',
          'text': 'Copied 1 github rows into memory.\n- maia',
        });
      },
    );
    var sawGraph = false;
    final script = _Script((body) {
      if (_toolMessages(body) == 0) {
        return _call(
          'connector',
          '{"platform":"github","intent":"list repos"}',
          'g',
        );
      }
      sawGraph = true;
      expect(body['tools'], isNull);
      return _say('You have the maia repo.');
    });
    final turn = await runChatTurn(
      harness: _harness(script),
      frame: [
        {'role': 'user', 'content': 'What is in my GitHub account?'},
      ],
      toolbox: box,
      db: _Db(),
      emit: (_, _) {},
    );
    expect(sawGraph, isTrue);
    expect(connectorCalls, 1);
    expect(turn.tools.map((call) => call['name']), [
      'memory_search',
      'connector',
    ]);
    expect(turn.tools.last['result'], contains('Copied 1 github'));
    expect(turn.tools.last['result'], isNot(contains('Call this tool again')));
    expect(turn.text, 'You have the maia repo.');
  });

  test('a sync that is not pulling still reads the account', () async {
    var reads = 0;
    final box = ChatToolbox(
      searchMemory: (c, query, limit) async => [],
      recentMemory: (c, limit) async => [],
      getMemory: (c, id) async => null,
      remember: (c, title, body) async => '',
      lifeGraph: (c) async => null,
      connector: (args) async {
        reads++;
        expect(args['platform'], 'github');
        return jsonEncode({
          'type': 'text',
          'text': 'Read 1 github record.\n- bennettchamberlain/maia. the app',
        });
      },
      sync: (c, args) async => jsonEncode({
        'type': 'text',
        'text':
            'Queued sync for github.\n'
            'Nothing is pulling yet. The jobs are still queued.',
      }),
    );
    final script = _Script((body) {
      if (_toolMessages(body) == 0) {
        return _call('sync', '{"platform":"github"}', 's');
      }
      return _say('Your login is on bennettchamberlain/maia.');
    });
    final turn = await runChatTurn(
      harness: _harness(script),
      frame: [
        {'role': 'user', 'content': 'Sync GitHub now'},
      ],
      toolbox: box,
      db: _Db(),
      emit: (_, _) {},
    );
    expect(reads, 1);
    expect(turn.tools.map((call) => call['name']), [
      'memory_search',
      'connector',
      'sync',
    ]);
    expect(turn.tools.last['result'], contains('bennettchamberlain/maia'));
    expect(turn.text, 'Your login is on bennettchamberlain/maia.');
  });

  test('a failed account read is not called again', () async {
    var reads = 0;
    final box = ChatToolbox(
      searchMemory: (c, query, limit) async => [],
      recentMemory: (c, limit) async => [],
      getMemory: (c, id) async => null,
      remember: (c, title, body) async => '',
      lifeGraph: (c) async => null,
      connector: (args) async {
        reads++;
        return jsonEncode({
          'type': 'text',
          'text': 'One could not read ${args['platform']} (failed).',
        });
      },
    );
    final script = _Script((body) {
      final systems = [
        for (final message in body['messages'] as List)
          if (message is Map && message['role'] == 'system')
            '${message['content']}',
      ];
      expect(systems.join('\n'), contains('did not return'));
      expect(systems.join('\n'), contains('do not have'));
      expect(body['tools'], isNull);
      return _say(
        'GitHub is able to return a login. I do not have the account.',
      );
    });
    final turn = await runChatTurn(
      harness: _harness(script),
      frame: [
        {'role': 'user', 'content': 'What is my GitHub login?'},
      ],
      toolbox: box,
      db: _Db(),
      emit: (_, _) {},
    );
    expect(reads, 1);
    expect(turn.tools.map((call) => call['name']), [
      'memory_search',
      'connector',
    ]);
    expect(turn.text, contains('do not have'));
  });

  test('github and gmail are one superstep after memory', () async {
    final platforms = <String>[];
    final box = ChatToolbox(
      searchMemory: (c, query, limit) async => [],
      recentMemory: (c, limit) async => [],
      getMemory: (c, id) async => null,
      remember: (c, title, body) async => '',
      lifeGraph: (c) async => null,
      connector: (args) async {
        final platform = '${args['platform']}';
        platforms.add(platform);
        return jsonEncode({
          'type': 'text',
          'text': 'One could not read $platform (failed).',
        });
      },
    );
    final script = _Script((_) => _say('I do not have either account.'));
    final turn = await runChatTurn(
      harness: _harness(script),
      frame: [
        {
          'role': 'user',
          'content': 'What is my GitHub login, and who sent my latest Gmail?',
        },
      ],
      toolbox: box,
      db: _Db(),
      emit: (_, _) {},
    );
    expect(platforms, ['github', 'gmail']);
    expect(turn.tools.map((call) => call['name']), [
      'memory_search',
      'connector',
      'connector',
    ]);
    final assistant = [for (final call in turn.tools) call['name']];
    expect(assistant.where((name) => name == 'connector'), hasLength(2));
  });
}

Future<List<Map<String, dynamic>>> _run(_Script script, String task) async {
  final turn = await runChatTurn(
    harness: _harness(script),
    frame: [
      {'role': 'user', 'content': task},
    ],
    toolbox: _box(),
    db: _Db(),
    emit: (_, _) {},
  );
  return turn.tools;
}

ChatToolbox _box({Set<String>? disabled, void Function()? onSearch}) {
  return ChatToolbox(
    searchMemory: (c, query, limit) async {
      onSearch?.call();
      return [];
    },
    recentMemory: (c, limit) async => [],
    getMemory: (c, id) async => null,
    remember: (c, title, body) async => '',
    lifeGraph: (c) async => null,
    disabled: disabled ?? {},
  );
}

AgentClient _harness(_Script script) {
  return AgentClient(
    baseUrl: Uri.parse('https://openrouter.ai/api/v1'),
    model: 'google/gemini-2.5-flash-lite',
    httpClient: script,
  );
}

class _Db extends Mock implements gel.Client {}

class _Script extends http.BaseClient {
  _Script(this.reply);
  final String Function(Map<String, dynamic> body) reply;
  int requests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    final body =
        jsonDecode((request as http.Request).body) as Map<String, dynamic>;
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(reply(body))),
      200,
    );
  }
}

String _task(Map<String, dynamic> body) {
  final messages = body['messages'] as List;
  for (final raw in messages.reversed) {
    final message = raw as Map;
    final content = '${message['content']}';
    if (message['role'] == 'user' && !content.startsWith('Step ')) {
      return content;
    }
  }
  return '';
}

int _toolMessages(Map<String, dynamic> body) {
  final messages = body['messages'] as List;
  return messages.where((raw) => (raw as Map)['role'] == 'tool').length;
}

List<String> _offered(Map<String, dynamic> body) {
  final tools = body['tools'] as List? ?? const [];
  return [for (final tool in tools) '${(tool as Map)['function']['name']}'];
}

String _say(String text) =>
    'data: ${jsonEncode({
      'choices': [
        {
          'delta': {'content': text},
        },
      ],
    })}\n\n'
    'data: ${jsonEncode({
      'choices': [
        {'finish_reason': 'stop'},
      ],
    })}\n\n'
    'data: [DONE]\n';

String _call(String name, String args, String id) => _calls([(name, args, id)]);

String _calls(List<(String, String, String)> calls) {
  final lines = <String>[
    for (var i = 0; i < calls.length; i++)
      'data: ${jsonEncode({
        'choices': [
          {
            'delta': {
              'tool_calls': [
                {
                  'index': i,
                  'id': calls[i].$3,
                  'function': {'name': calls[i].$1, 'arguments': calls[i].$2},
                },
              ],
            },
          },
        ],
      })}',
    'data: ${jsonEncode({
      'choices': [
        {'finish_reason': 'tool_calls'},
      ],
    })}',
    'data: [DONE]',
  ];
  return '${lines.join('\n\n')}\n';
}

class _Json extends http.BaseClient {
  _Json(this.reply);
  final http.Response Function(http.Request request) reply;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = reply(request as http.Request);
    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
    );
  }
}
