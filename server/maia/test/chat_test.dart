import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:maia_api/maia_api.dart';
import 'package:test/test.dart';

void main() {
  group('AgentClient URIs', () {
    test('Parasail /v1 base does not double the version', () {
      final base = Uri.parse('https://api.parasail.io/v1');
      expect(
        AgentClient.completionsUri(base).toString(),
        'https://api.parasail.io/v1/chat/completions',
      );
      expect(
        AgentClient.modelsUri(base).toString(),
        'https://api.parasail.io/v1/models',
      );
    });

    test('Ollama host gets /v1 prefixed', () {
      final base = Uri.parse('http://127.0.0.1:11434');
      expect(
        AgentClient.completionsUri(base).toString(),
        'http://127.0.0.1:11434/v1/chat/completions',
      );
    });

    test('Gemini OpenAI-compat base keeps /v1beta/openai', () {
      final base = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/openai',
      );
      expect(
        AgentClient.completionsUri(base).toString(),
        'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions',
      );
      expect(
        AgentClient.modelsUri(base).toString(),
        'https://generativelanguage.googleapis.com/v1beta/openai/models',
      );
    });
  });

  group('ChatToolbox formatting', () {
    test('memories and graph collapse to GenUI JSON', () {
      expect(ChatToolbox.formatMemories(const []), contains('no memories'));
      expect(
        ChatToolbox.formatMemoryRow({
          'id': 'abc',
          'title': 'Friday standup',
          'body': 'Alex and the team',
          'occurred_at': '2026-10-28',
        }),
        allOf(contains('"type":"memory"'), contains('Friday standup')),
      );
      expect(
        ChatToolbox.formatMemories(const [
          {
            'id': 'abc',
            'title': 'Friday standup',
            'place': {
              'name': 'Cafe',
              'city': 'Oakland',
              'lat': 37.8,
              'lng': -122.27,
            },
          },
        ]),
        allOf(contains('"type":"map"'), contains('Cafe'), contains('37.8')),
      );
      expect(
        ChatToolbox.formatGraph({
          'goals': [
            {'name': 'ship chat', 'why': 'the phone'},
          ],
          'edges': [
            {
              'kind': 'knows',
              'status': 'verified',
              'source': {'name': 'Alex'},
              'target': {'name': 'standup'},
            },
          ],
        }),
        allOf(
          contains('"type":"graph"'),
          contains('ship chat'),
          contains('Alex'),
        ),
      );
    });
  });

  group('ToolPrefsStore', () {
    test('round-trips a You.com key and disabled tools', () async {
      final dir = await Directory.systemTemp.createTemp('maia-secrets');
      addTearDown(() => dir.delete(recursive: true));
      final store = ToolPrefsStore(dir);
      await store.write(
        'person-1',
        const ToolPrefs(youKey: 'secret-you', disabled: {'web_search'}),
      );
      final got = await store.read('person-1');
      expect(got.youKey, 'secret-you');
      expect(got.enabled('web_search'), isFalse);
      expect(got.enabled('now'), isTrue);
      await store.write('person-1', got.copyWith(clearYouKey: true));
      expect((await store.read('person-1')).youKey, isNull);
    });
  });

  group('Config chat provider', () {
    test('reads Parasail chat model and You.com key', () {
      final c = Config.fromEnv({
        'MAIA_SESSION_SECRET': 'a-very-long-secret-at-least-32-chars!!',
        'PARASAIL_API_KEY': 'k',
        'PARASAIL_MODEL': 'parasail-glm-53-flash',
        'YDC_API_KEY': 'you',
        'OLLAMA_URL': 'http://127.0.0.1:11434',
        'MAIA_CHAT_PROVIDER': 'auto',
      });
      expect(c.parasailChatModel, 'parasail-glm-53-flash');
      expect(c.youApiKey, 'you');
      expect(c.chatProvider, 'auto');
      expect(c.ollamaChatModel, 'llama3.2');
    });

    test('reads Gemini key, model, and provider', () {
      final c = Config.fromEnv({
        'MAIA_SESSION_SECRET': 'a-very-long-secret-at-least-32-chars!!',
        'GOOGLE_GEMINI_API_KEY': 'gemini-key',
        'GEMINI_MODEL': 'gemini-3-flash-preview',
        'MAIA_CHAT_PROVIDER': 'gemini',
      });
      expect(c.geminiApiKey, 'gemini-key');
      expect(c.geminiChatModel, 'gemini-3-flash-preview');
      expect(c.chatProvider, 'gemini');
      expect(
        c.geminiBaseUrl,
        'https://generativelanguage.googleapis.com/v1beta/openai',
      );
    });
  });

  group('Gemini tool signatures', () {
    test('a streamed signature is kept on the tool call', () async {
      const sse = '''
data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","extra_content":{"google":{"thought_signature":"sig-a"}},"function":{"name":"web_search","arguments":"{\\"q\\":"}}]}}]}

data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"lisbon\\"}"}}]}}]}

data: {"choices":[{"finish_reason":"tool_calls"}]}

data: [DONE]
''';
      final client = AgentClient(
        baseUrl: Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/openai',
        ),
        model: 'gemini-3-flash-preview',
        token: 'test-key',
        httpClient: _SseClient(sse),
      );
      final events = await client.stream(const [
        {'role': 'user', 'content': 'weather'},
      ]).toList();
      final call = events.whereType<AgentToolCall>().single;
      expect(call.name, 'web_search');
      expect(call.arguments, '{"q":"lisbon"}');
      expect(call.toWire()['extra_content'], {
        'google': {'thought_signature': 'sig-a'},
      });
      final auth = (_SseClient.lastRequest?.headers['authorization']);
      expect(auth, 'Bearer test-key');
    });

    test('a signature beside tool_calls is kept on the call', () async {
      // Gemini sometimes sends the signature on the delta, not inside
      // the tool-call object. Dropping it is the follow-up 400.
      const sse = '''
data: {"choices":[{"delta":{"role":"assistant","extra_content":{"google":{"thought_signature":"sig-sibling"}},"tool_calls":[{"id":"call_9","type":"function","function":{"name":"web_search","arguments":"{\\"query\\":\\"lisbon\\"}"}}]},"index":0}]}

data: {"choices":[{"finish_reason":"tool_calls","index":0}]}

data: [DONE]
''';
      final client = AgentClient(
        baseUrl: Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/openai',
        ),
        model: 'gemini-3-flash-preview',
        token: 'test-key',
        httpClient: _SseClient(sse),
      );
      final events = await client
          .stream(
            const [
              {'role': 'user', 'content': 'weather'},
            ],
            tools: const [
              {
                'type': 'function',
                'function': {'name': 'web_search'},
              },
            ],
          )
          .toList();
      final call = events.whereType<AgentToolCall>().single;
      expect(call.toWire()['extra_content'], {
        'google': {'thought_signature': 'sig-sibling'},
      });
    });

    test('a signature on the following chunk is kept on the call', () async {
      const sse = '''
data: {"choices":[{"delta":{"role":"assistant","tool_calls":[{"id":"call_2","type":"function","function":{"name":"web_search","arguments":"{\\"query\\":\\"lisbon\\"}"}}]},"index":0}]}

data: {"choices":[{"delta":{"extra_content":{"google":{"thought_signature":"sig-later"}},"role":"assistant"},"finish_reason":"tool_calls","index":0}]}

data: [DONE]
''';
      final client = _gemini(sse);
      final events = await client.stream(const [
        {'role': 'user', 'content': 'weather'},
      ]).toList();
      final call = events.whereType<AgentToolCall>().single;
      expect(call.toWire()['extra_content'], {
        'google': {'thought_signature': 'sig-later'},
      });
    });

    test('a signature inside function is echoed there', () async {
      const sse = '''
data: {"choices":[{"delta":{"tool_calls":[{"id":"call_3","type":"function","function":{"name":"web_search","arguments":"{}","thought_signature":"sig-fn"}}]}}]}

data: [DONE]
''';
      final client = _gemini(sse);
      final call = (await client.stream(const [
        {'role': 'user', 'content': 'weather'},
      ]).toList()).whereType<AgentToolCall>().single;
      expect(call.toWire()['function'], {
        'name': 'web_search',
        'arguments': '{}',
        'thought_signature': 'sig-fn',
      });
    });

    test('parallel calls without index stay separate', () async {
      const sse = '''
data: {"choices":[{"delta":{"role":"assistant","tool_calls":[{"extra_content":{"google":{"thought_signature":"sig-first"}},"function":{"arguments":"{\\"city\\":\\"Taipei\\"}","name":"get_weather"},"id":"call_a","type":"function"}]},"index":0}]}

data: {"choices":[{"delta":{"role":"assistant","tool_calls":[{"function":{"arguments":"{\\"city\\":\\"Kaohsiung\\"}","name":"get_weather"},"id":"call_b","type":"function"}]},"index":0}]}

data: [DONE]
''';
      final client = _gemini(sse);
      final calls = (await client.stream(const [
        {'role': 'user', 'content': 'both'},
      ]).toList()).whereType<AgentToolCall>().toList();
      expect(calls, hasLength(2));
      expect(calls[0].id, 'call_a');
      expect(calls[0].arguments, '{"city":"Taipei"}');
      expect(calls[0].toWire()['extra_content'], {
        'google': {'thought_signature': 'sig-first'},
      });
      expect(calls[1].id, 'call_b');
      expect(calls[1].arguments, '{"city":"Kaohsiung"}');
      expect(calls[1].toWire().containsKey('extra_content'), isFalse);
    });
  });

  group('replayChatHistory', () {
    test('a signed tool call is sent back on the next turn', () {
      final frame = replayChatHistory([
        {
          'role': 'user',
          'content': 'Search the web for the weather in Lisbon tomorrow',
        },
        {
          'role': 'assistant',
          'content': 'Tomorrow is mild.',
          'tool_calls': [
            {
              'name': 'web_search',
              'arguments': '{"query":"lisbon"}',
              'result': '{"type":"text","text":"18C"}',
              'call_id': 'call_a',
              'extra': {
                'extra_content': {
                  'google': {'thought_signature': 'sig-a'},
                },
              },
            },
          ],
        },
        {'role': 'user', 'content': 'And the day after?'},
      ]);
      expect(frame[1]['content'], isNull);
      expect(frame[1]['tool_calls'], [
        {
          'id': 'call_a',
          'type': 'function',
          'function': {'name': 'web_search', 'arguments': '{"query":"lisbon"}'},
          'extra_content': {
            'google': {'thought_signature': 'sig-a'},
          },
        },
      ]);
      expect(frame[2], {
        'role': 'tool',
        'tool_call_id': 'call_a',
        'content': '{"type":"text","text":"18C"}',
      });
      expect(frame[3], {'role': 'assistant', 'content': 'Tomorrow is mild.'});
      expect(frame[4]['content'], 'And the day after?');
    });

    test('an old tool row without a signature stays text', () {
      final frame = replayChatHistory([
        {
          'role': 'assistant',
          'content': 'done',
          'tool_calls': [
            {'name': 'web_search', 'arguments': '{}', 'result': 'ok'},
          ],
        },
      ]);
      expect(frame.single.containsKey('tool_calls'), isFalse);
    });
  });
}

AgentClient _gemini(String sse) => AgentClient(
  baseUrl: Uri.parse('https://generativelanguage.googleapis.com/v1beta/openai'),
  model: 'gemini-3-flash-preview',
  token: 'test-key',
  httpClient: _SseClient(sse),
);

class _SseClient extends http.BaseClient {
  _SseClient(this.payload);
  final String payload;
  static http.BaseRequest? lastRequest;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastRequest = request;
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(payload)),
      200,
    );
  }
}
