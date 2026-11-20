import 'package:maie_api/src/harness/harness.dart';
import 'package:test/test.dart';

void main() {
  test('promotion waits for recalls from more than one search', () {
    expect(promotionGate(recalls: 3, queries: 1), isFalse);
    expect(promotionGate(recalls: 2, queries: 2), isFalse);
    expect(promotionGate(recalls: 3, queries: 2), isTrue);
  });

  test('long chats keep a tail and fold the rest', () {
    final messages = [
      for (var i = 0; i < 30; i++)
        {
          'role': i.isEven ? 'user' : 'assistant',
          'content': 'turn $i',
          'seq': i,
        },
    ];
    final split = splitForCompaction(messages);
    expect(split.kept, hasLength(16));
    expect(split.older, hasLength(14));
    expect(split.kept.first['content'], 'turn 14');
    expect(extractiveCompaction(split.older), contains('turn 0'));
  });

  test('a folded chat keeps what was found', () {
    final messages = [
      for (var i = 0; i < 30; i++)
        {
          'role': i.isEven ? 'user' : 'assistant',
          'content': 'turn $i',
          'seq': i,
        },
    ];
    final split = splitForCompaction(messages);
    final text = extractiveCompaction(split.older);
    expect(text, contains('turn 0'));
    expect(text, contains('Already found'));
    expect(text, contains('turn 1'));
  });

  test('old tool results clip and a long frame keeps the task', () {
    final messages = [
      {'role': 'system', 'content': 'You are Maie'},
      {'role': 'user', 'content': 'What is in my GitHub account?'},
      for (var i = 0; i < 8; i++)
        {
          'role': 'tool',
          'tool_name': 'connector',
          'content': 'row $i ${'x' * 800}',
        },
      {'role': 'assistant', 'content': 'still looking'},
    ];
    final pruned = pruneToolResults(messages, keep: 4, clip: 80);
    final tools = [
      for (final m in pruned)
        if (m['role'] == 'tool') m,
    ];
    expect('${tools.first['content']}', contains('clipped'));
    expect('${tools.first['content']}'.length, lessThan(200));
    expect('${tools.last['content']}', contains('row 7'));
    expect('${tools.last['content']}', isNot(contains('clipped')));

    final folded = foldWorkingSet(messages);
    final blob = folded.map((m) => '${m['content']}').join('\n');
    expect(folded.first['content'], 'You are Maie');
    expect(blob, contains('GitHub'));
    expect(blob, contains('row 0'));
    expect(blob, contains('still looking'));
    expect(folded.length, lessThan(messages.length));
    expect(modelFrame(messages).length, messages.length);
  });

  test('a short chat is left whole', () {
    final messages = [
      {'role': 'user', 'content': 'hi', 'seq': 1},
    ];
    final split = splitForCompaction(messages);
    expect(split.older, isEmpty);
    expect(split.kept, hasLength(1));
  });

  test('an intent matches the phrase and ignores the rest', () {
    final hit = matchingIntents([
      {'phrase': 'launch', 'instruction': 'ask about rollback'},
      {'phrase': 'dentist', 'instruction': 'bring the card'},
    ], 'The launch candidate is up.');
    expect(hit, hasLength(1));
    expect(hit.single['phrase'], 'launch');
  });

  test('work does not see the life graph', () {
    expect(toolsetAllows('work', 'life_graph'), isFalse);
    expect(toolsetAllows('work', 'web_search'), isTrue);
    expect(toolsetAllows('memory', 'intent_create'), isTrue);
    expect(toolsetAllows('memory', 'skill_propose'), isFalse);
    expect(toolsetAllows('memory', 'library_read'), isTrue);
    expect(toolsetAllows('work', 'library_read'), isTrue);
    expect(toolsetAllows('memory', 'computer'), isTrue);
    expect(toolsetAllows('memory', 'file_read'), isTrue);
    expect(toolsetAllows('work', 'video_describe'), isTrue);
    expect(toolsetAllows('work', 'life_graph'), isFalse);
  });

  test('night research follows named interests and stops at three', () {
    final topics = researchTopics(
      intents: [
        {'phrase': 'PersonaPlex'},
        {'phrase': 'personaplex'},
      ],
      curated: [
        {'title': 'Gel migrations'},
      ],
      goals: [
        {'name': 'Ship the glasses'},
        {'name': 'Learn the Hammerklavier'},
      ],
    );
    expect(topics, ['PersonaPlex', 'Gel migrations', 'Ship the glasses']);
  });

  test('a research note keeps the link and stays short', () {
    final note = researchBrief('PersonaPlex', [
      {
        'title': 'PolarGrid voice',
        'snippet': 'a' * 400,
        'url': 'https://polargrid.ai/voice',
      },
    ]);
    expect(note, contains('PolarGrid voice'));
    expect(note, contains('https://polargrid.ai/voice'));
    expect(note.length, lessThan(400));
  });

  test('the dream sends once in the three o clock hour', () {
    final night = DateTime(2026, 11, 18, 3, 10);
    final morning = DateTime(2026, 11, 18, 8);
    expect(dreamDue(night), isTrue);
    expect(dreamDue(night, lastDay: dreamDay(night)), isFalse);
    expect(dreamDue(morning, lastDay: dreamDay(night)), isFalse);
  });

  test('the voice stays put when the clock moves', () {
    final voice = stableVoice(name: 'Bennett', handle: 'bennett');
    expect(stableVoice(name: 'Bennett', handle: 'bennett'), voice);
    expect(voice, isNot(contains('Current local time')));
    expect(voice, contains('library_read'));
    final prompt = chatPrompt(
      name: 'Bennett',
      handle: 'bennett',
      now: DateTime(2026, 11, 18, 3),
      connectors: const ['gmail'],
      extra: 'Standing intents:\n- launch',
    );
    expect(prompt.indexOf('You are Maie'), 0);
    expect(
      prompt.indexOf('Current local time'),
      greaterThan(prompt.indexOf('You are Maie')),
    );
    expect(
      prompt.indexOf('Standing intents'),
      greaterThan(prompt.indexOf('Current local time')),
    );
    expect(prompt, contains('gmail'));
    expect(prompt, contains('copied into memory'));
    expect(prompt, contains('sync'));
    expect(prompt, contains('still queued'));
    expect(prompt, contains('Memory first'));
    expect(prompt, contains('computer'));
    expect(prompt, contains('cred_'));
    expect(prompt, contains('did not return'));
    expect(prompt, contains('Do not describe the tool'));
    expect(prompt, isNot(contains('able to return')));
  });

  test('a printed tool call is not a sentence', () {
    expect(
      looksLikePrintedToolCall(
        '<tool_call>{"name":"memory_search","arguments":{}}</tool_call>',
      ),
      isTrue,
    );
    expect(
      looksLikePrintedToolCall(
        '{"name":"web_search","arguments":{"query":"Lisbon"}}',
      ),
      isTrue,
    );
    expect(
      looksLikePrintedToolCall(
        'Lisbon is the capital. The tool would be {"name":"web_search","arguments":{}} if I needed it, but I do not.',
      ),
      isFalse,
    );
  });

  test('a steer waits until the running turn takes it', () {
    final lane = TurnLane();
    Map<String, dynamic>? shown;
    lane.onStored = (message) => shown = message;
    expect(lane.take(), isNull);
    lane.offer('stop');
    lane.offer('look at Lisbon', stored: {'id': 'm2'});
    expect(lane.take(), 'stop\nlook at Lisbon');
    expect(lane.take(), isNull);
    expect(shown?['id'], 'm2');
  });

  test('review notes stay out of the frame', () {
    final text = harnessContext(
      compaction: 'Earlier: Lisbon.',
      intents: [
        {'phrase': 'launch', 'instruction': 'ask about rollback'},
      ],
      skills: [
        {'name': 'ship', 'body': 'Run the checks.', 'status': 'active'},
        {'name': 'draft', 'body': 'Not yet.', 'status': 'proposed'},
      ],
    );
    expect(text, contains('Lisbon'));
    expect(text, contains('rollback'));
    expect(text, contains('ship'));
    expect(text, isNot(contains('Not yet')));
  });

  test('a library index replaces the skill bodies', () {
    final text = harnessContext(
      skills: [
        {'name': 'ship', 'body': 'Run the checks.', 'status': 'active'},
      ],
      library: 'Skills:\n- ship: Run the checks.',
    );
    expect(text, contains('Skills:'));
    expect(text, isNot(contains('Confirmed procedures')));
  });

  test('a proposal score counts memory hits and skips a miss', () {
    expect(
      proposalScore([
        {'name': 'memory_search', 'result': 'Lisbon'},
        {'name': 'library_read', 'result': 'not in the library'},
        {'name': 'web_search', 'result': 'a page'},
        {'name': 'life_graph', 'result': 'one goal'},
      ]),
      2,
    );
  });

  test('the answer cue talks about the person, not a step', () {
    expect(answerCue, contains('latest message'));
    expect(answerCue, isNot(contains('Step ')));
    expect(answerCue, contains('do not have it'));
  });

  test('a harness line is the title and the topics', () {
    expect(
      harnessWording('Shipped the build', ['rollback', '']),
      'Shipped the build. rollback',
    );
  });
}
