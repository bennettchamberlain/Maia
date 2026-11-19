import 'package:flutter_test/flutter_test.dart';
import 'package:maia_app/chat/chat_turn_bench.dart';

void main() {
  test('checkpoint case', () {
    final c = chatTurnBenchCases.firstWhere((c) => c.id == 'checkpoint');
    expect(c.checkReply('checkpoint'), isNull);
    expect(c.checkReply('Checkpoint '), isNotNull);
  });

  test('a github read must call the account and not describe the tool', () {
    final c = chatTurnBenchCases.firstWhere((c) => c.id == 'github-login');
    expect(
      c.checkReply(
        'Your login is bennettchamberlain. One repository is maia.',
        toolNames: ['memory_search', 'connector'],
      ),
      isNull,
    );
    expect(
      c.checkReply(
        'I do not have the GitHub account.',
        toolNames: ['memory_search', 'connector'],
      ),
      isNull,
    );
    expect(
      c.checkReply(
        'The connector can return a login. I do not have the account.',
        toolNames: ['memory_search', 'connector'],
      ),
      isNotNull,
    );
    expect(
      c.checkReply('I do not have the account.', toolNames: ['memory_search']),
      isNotNull,
    );
  });

  test('quorinth memory must not be the nearest mailbox', () {
    final c = chatTurnBenchCases.firstWhere((c) => c.id == 'quorinth');
    expect(
      c.checkReply(
        'I do not have any memories of the word quorinth.',
        toolNames: ['memory_search'],
        toolText: '{"type":"text","text":"no memories"}',
      ),
      isNull,
    );
    expect(
      c.checkReply(
        'I do not have any memories of the word quorinth.',
        toolNames: ['memory_search'],
        toolText: 'OAuth Application Approval from Supabase',
      ),
      isNotNull,
    );
  });

  test('two apps need both connector calls after memory', () {
    final c = chatTurnBenchCases.firstWhere((c) => c.id == 'two-apps');
    expect(
      c.checkReply(
        'Your GitHub login is ada. The latest Gmail is from Lin.',
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
