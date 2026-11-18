import 'package:flutter_test/flutter_test.dart';
import 'package:maia_app/chat/chat_turn_bench.dart';

void main() {
  test('checkpoint case', () {
    final c = chatTurnBenchCases.firstWhere((c) => c.id == 'checkpoint');
    expect(c.checkReply('checkpoint'), isNull);
    expect(c.checkReply('Checkpoint '), isNotNull);
  });

  test('a failed github read must stay inside the graph', () {
    final c = chatTurnBenchCases.firstWhere((c) => c.id == 'capability');
    expect(
      c.checkReply(
        'GitHub is able to return a login. I do not have the account.',
        toolNames: ['memory_search', 'connector'],
      ),
      isNull,
    );
    expect(
      c.checkReply(
        'GitHub is able to return a login. I do not have the account.',
        toolNames: ['web_search'],
      ),
      isNotNull,
    );
    expect(
      c.checkReply(
        'Call connector for action_id conn_mod. I do not have it.',
        toolNames: ['memory_search', 'connector'],
      ),
      isNotNull,
    );
  });

  test('two apps need both connector calls after memory', () {
    final c = chatTurnBenchCases.firstWhere((c) => c.id == 'two-apps');
    expect(
      c.checkReply(
        'I do not have GitHub or Gmail.',
        toolNames: ['memory_search', 'connector', 'connector'],
      ),
      isNull,
    );
    expect(
      c.checkReply(
        'I do not have GitHub or Gmail.',
        toolNames: ['memory_search', 'connector'],
      ),
      isNotNull,
    );
  });
}
