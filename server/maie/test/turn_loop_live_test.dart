import 'dart:io';

import 'package:gel/gel.dart' as gel;
import 'package:maie_api/src/agent.dart';
import 'package:maie_api/src/chat/tools.dart';
import 'package:maie_api/src/chat/turn.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

void main() {
  final turns = int.tryParse(Platform.environment['MAIE_LOOP_N'] ?? '') ?? 50;

  test('$turns live turns take one next step', () async {
    if (Platform.environment['MAIE_LOOP_LIVE'] != '1') {
      markTestSkipped('set MAIE_LOOP_LIVE=1 to run the live loop');
    }
    final key =
        Platform.environment['OPENROUTER_API_KEY'] ??
        Platform.environment['OPEN_ROUTER_API_KEY'];
    if (key == null || key.isEmpty) {
      markTestSkipped('OPENROUTER_API_KEY is not set');
    }
    final model =
        Platform.environment['OPENROUTER_MODEL'] ??
        'google/gemini-2.5-flash-lite';
    final harness = AgentClient(
      baseUrl: Uri.parse(
        Platform.environment['OPENROUTER_BASE_URL'] ??
            'https://openrouter.ai/api/v1',
      ),
      model: model,
      token: key,
      cheapFallbacks: true,
      maxTokens: 300,
      extraHeaders: const {
        'HTTP-Referer': 'http://127.0.0.1:8090',
        'X-Title': 'Maie',
      },
    );
    final box = ChatToolbox(
      searchMemory: (c, query, limit) async => [],
      recentMemory: (c, limit) async => [],
      getMemory: (c, id) async => null,
      remember: (c, title, body) async => '',
      lifeGraph: (c) async => null,
    );
    final misses = <String>[];
    var pongTools = 0;
    var clockMiss = 0;
    var errors = 0;
    for (var i = 0; i < turns; i++) {
      final clock = i.isOdd;
      final task = clock
          ? 'Call the now tool once, then give the time in one short sentence.'
          : 'Reply with the single word pong. Do not call a tool.';
      try {
        final turn = await _once(
          () => runChatTurn(
            harness: harness,
            frame: [
              {'role': 'user', 'content': task},
            ],
            toolbox: box,
            db: _Db(),
            emit: (_, _) {},
          ),
        );
        final nows = turn.tools.where((call) => call['name'] == 'now').length;
        if (!clock && turn.tools.isNotEmpty) {
          pongTools++;
          misses.add('pong $i called ${turn.tools.length}');
        }
        if (clock && (nows != 1 || turn.text.trim().isEmpty)) {
          clockMiss++;
          misses.add('clock $i nows=$nows chars=${turn.text.trim().length}');
        }
      } on Object catch (error) {
        errors++;
        misses.add('turn $i ${_safe(error)}');
      }
    }
    final report =
        'errors=$errors pongTools=$pongTools clockMiss=$clockMiss '
        'of $turns\n${misses.take(12).join('\n')}';
    expect(errors, 0, reason: report);
    expect(pongTools, lessThan(6), reason: report);
    expect(clockMiss, lessThan(6), reason: report);
  }, timeout: const Timeout(Duration(minutes: 15)));
}

Future<T> _once<T>(Future<T> Function() run) async {
  try {
    return await run();
  } on AgentException catch (error) {
    if (error.status != 429) rethrow;
    await Future<void>.delayed(const Duration(seconds: 3));
    return run();
  }
}

class _Db extends Mock implements gel.Client {}

String _safe(Object error) {
  final text = '$error'
      .replaceAll(RegExp(r'sk-[A-Za-z0-9_-]+'), 'sk-redacted')
      .replaceAll(RegExp(r'Bearer [A-Za-z0-9._-]+'), 'Bearer redacted');
  return text.length <= 220 ? text : text.substring(0, 220);
}
