import 'package:flutter_test/flutter_test.dart';
import 'package:maia_app/chat/chat_turn_bench.dart';

void main() {
  test('ready case', () {
    final c = chatTurnBenchCases.firstWhere((c) => c.id == 'ready');
    expect(c.checkReply('ready'), isNull);
    expect(c.checkReply('Ready '), isNotNull);
  });

  test('github-access rejects harness leaks', () {
    final c = chatTurnBenchCases.firstWhere((c) => c.id == 'github-access');
    expect(
      c.checkReply(
        'Yes. Call connector again for github action_id: conn_mod_def::x',
      ),
      isNotNull,
    );
    expect(c.checkReply('Yes, your GitHub account is connected.'), isNull);
  });
}