import 'package:maie_api/maie_api.dart';
import 'package:test/test.dart';

void main() {
  final early = DateTime.utc(2026, 11, 10, 21, 35);
  final late = DateTime.utc(2026, 11, 10, 22, 8);

  ClosePlan close({
    bool locked = false,
    int through = 0,
    int latest = 2,
    String? model =
        '{"title":"You mapped careers with Mike",'
        '"topics":["AI options","Robotics with Mike"]}',
  }) => planSessionClose(
    titleLocked: locked,
    summarizedThrough: through,
    latestSeq: latest,
    modelText: model,
    times: [early, late],
    toolCalls: const [],
  );

  test('a locked title survives close and topics are replaced', () {
    final plan = close(locked: true);
    expect(plan.apply, isTrue);
    expect(plan.title, isNull);
    expect(plan.topics, ['AI options', 'Robotics with Mike']);
    expect(plan.startedAt, early);
    expect(plan.endedAt, late);
  });

  test('close is skipped when the transcript was already summarized', () {
    expect(close(through: 2).apply, isFalse);
  });

  test('a missing model leaves the session unchanged', () {
    expect(close(model: null).apply, isFalse);
    expect(close(model: 'not json').apply, isFalse);
  });

  test('fork keeps messages through the chosen one', () {
    final messages = [
      {'id': 'a', 'seq': 1, 'role': 'user', 'content': 'hi'},
      {'id': 'b', 'seq': 2, 'role': 'assistant', 'content': 'hello'},
      {'id': 'c', 'seq': 3, 'role': 'user', 'content': 'more'},
    ];
    final through = messagesThrough(messages, 'b');
    expect(through.map((m) => m['id']), ['a', 'b']);
    expect(messagesThrough(messages, 'missing'), isEmpty);
  });

  test('append adds the passage and its citation once', () {
    final body = appendPassage(
      body: 'Notes',
      passage: 'the highlighted line',
      citation: 'From chat s1 message m1 at 2026-11-10T22:08:00.000Z.',
    );
    expect(body, contains('Notes'));
    expect(body, contains('the highlighted line'));
    expect(body, contains('From chat s1'));
    expect(
      appendPassage(body: '', passage: 'only', citation: 'Saved.'),
      'only\n\nSaved.',
    );
  });

  test('a session span covers the first message through the last', () {
    final span = spanOf([late, early]);
    expect(span?.start, early);
    expect(span?.end, late);
    expect(spanOf(const []), isNull);
  });

  test('connector sources become mail, calendar, or a connection', () {
    expect(connectorSpec('one:gmail')?.kind, 'mail');
    expect(
      connectorSpec('one:gmail', account: 'work@me.com')?.account,
      'work@me.com',
    );
    expect(connectorSpec('one:google-calendar')?.kind, 'calendar');
    expect(connectorSpec('one:github')?.kind, 'connector');
    expect(
      connectorSpec('one:github')?.timelineKey,
      'connection:github:github',
    );
    expect(connectorSpec('app'), isNull);
    expect(
      connectionKeys(const [
        {'name': 'memory_search', 'arguments': '{}'},
        {'name': 'gmail', 'arguments': '{"platform":"gmail"}'},
      ]),
      ['gmail'],
    );
  });
}
