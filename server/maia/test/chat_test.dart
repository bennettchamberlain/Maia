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

    test('OpenRouter /api/v1 base does not double the version', () {
      final base = Uri.parse('https://openrouter.ai/api/v1');
      expect(
        AgentClient.completionsUri(base).toString(),
        'https://openrouter.ai/api/v1/chat/completions',
      );
      expect(
        AgentClient.modelsUri(base).toString(),
        'https://openrouter.ai/api/v1/models',
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
      final alias = Config.fromEnv({
        'MAIA_SESSION_SECRET': 'a-very-long-secret-at-least-32-chars!!',
        'YOU_API_KEY': 'you-alias',
      });
      expect(alias.youApiKey, 'you-alias');
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

    test('reads OpenRouter key, model, and provider', () {
      final c = Config.fromEnv({
        'MAIA_SESSION_SECRET': 'a-very-long-secret-at-least-32-chars!!',
        'OPENROUTER_API_KEY': 'sk-or-v1-test',
        'OPENROUTER_MODEL': 'anthropic/claude-sonnet-4.5',
        'MAIA_CHAT_PROVIDER': 'openrouter',
      });
      expect(c.openrouterApiKey, 'sk-or-v1-test');
      expect(c.openrouterChatModel, 'anthropic/claude-sonnet-4.5');
      expect(c.chatProvider, 'openrouter');
      expect(c.openrouterBaseUrl, 'https://openrouter.ai/api/v1');
      expect(c.openrouterMaxTokens, 2048);
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

    test('a 503 is tried once more', () async {
      const sse = '''
data: {"choices":[{"delta":{"content":"pong"}}]}

data: {"choices":[{"finish_reason":"stop"}]}

data: [DONE]
''';
      _Flaky.sends = 0;
      final client = AgentClient(
        baseUrl: Uri.parse('https://openrouter.ai/api/v1'),
        model: 'google/gemini-2.5-flash-lite',
        httpClient: _Flaky(sse),
      );
      final events = await client.stream(const [
        {'role': 'user', 'content': 'hi'},
      ]).toList();
      expect(events.whereType<AgentText>().single.text, 'pong');
      expect(_Flaky.sends, 2);
    });
  });

  test('OpenRouter citations become link cards without a You.com key', () {
    final links = linksFromOpenRouter({
      'choices': [
        {
          'message': {
            'content': 'Lisbon is sunny.',
            'annotations': [
              {
                'type': 'url_citation',
                'url_citation': {
                  'url': 'https://example.com/lisbon',
                  'title': 'Lisbon weather',
                  'content': 'Sunny and 22 C.',
                },
              },
            ],
          },
        },
      ],
    });
    expect(links, [
      {
        'type': 'link',
        'title': 'Lisbon weather',
        'url': 'https://example.com/lisbon',
        'snippet': 'Sunny and 22 C.',
      },
    ]);
    expect(
      youWebHits({
        'results': {
          'web': [
            {
              'url': 'https://example.com/a',
              'title': 'A',
              'snippets': ['from the page'],
            },
          ],
        },
      }),
      [
        {
          'type': 'link',
          'title': 'A',
          'url': 'https://example.com/a',
          'snippet': 'from the page',
        },
      ],
    );
    final box = ChatToolbox(
      searchMemory: (c, query, limit) async => [],
      recentMemory: (c, limit) async => [],
      getMemory: (c, id) async => null,
      remember: (c, title, body) async => '',
      lifeGraph: (c) async => null,
      openRouterApiKey: 'sk-or-test',
    );
    expect(box.webAvailable, isTrue);
    expect(
      box.definitions.any((tool) => tool['function']['name'] == 'web_search'),
      isTrue,
    );
    expect(
      box.definitions.any((tool) => tool['function']['name'] == 'connector'),
      isFalse,
    );
    final wired = ChatToolbox(
      searchMemory: (c, query, limit) async => [],
      recentMemory: (c, limit) async => [],
      getMemory: (c, id) async => null,
      remember: (c, title, body) async => '',
      lifeGraph: (c) async => null,
      connector: (args) async => '{"ok":true,"platform":"${args['platform']}"}',
    );
    expect(
      wired.definitions.any((tool) => tool['function']['name'] == 'connector'),
      isTrue,
    );
  });
}

class _Flaky extends http.BaseClient {
  _Flaky(this.payload);
  final String payload;
  static var sends = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sends++;
    if (sends == 1) {
      return http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode('no')),
        503,
      );
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(payload)),
      200,
    );
  }
}

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
