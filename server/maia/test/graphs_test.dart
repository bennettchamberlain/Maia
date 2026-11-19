import 'dart:convert';

import 'package:maia_api/src/chat/graphs.dart';
import 'package:test/test.dart';

void main() {
  test('a sync request is not an account graph', () {
    expect(playbookFor('Sync GitHub now'), isNull);
    expect(
      playbookFor('In one sentence, what is a directed acyclic graph?'),
      isNull,
    );
  });

  test('the day, the inbox, and a file are real account slugs', () {
    final day = playbookFor('What is on my calendar tomorrow?');
    expect(readyNodes(day!.nodes, {'memory'}).map((node) => node.id), [
      'read-google-calendar',
    ]);
    expect(playbookFor('Plan my afternoon'), isNotNull);
    expect(
      readyNodes(playbookFor('Plan my afternoon')!.nodes, {
        'memory',
      }).map((node) => node.id),
      ['read-google-calendar'],
    );
    final files = playbookFor('What is in my Google Drive and my Google Docs?');
    expect(readyNodes(files!.nodes, {'memory'}).map((node) => node.id), [
      'read-google-drive',
      'read-google-docs',
    ]);
    expect(playbookFor('What do you remember about github?'), isNull);
    expect(asksToChange('Draft a reply to my latest email'), isTrue);
    expect(asksToChange('Should I reply to the latest email?'), isFalse);
    expect(asksToChange('What is on my schedule tomorrow?'), isFalse);
    expect(
      readyNodes(playbookFor('Check Slack and Notion')!.nodes, {
        'memory',
      }).map((node) => node.id),
      ['read-slack', 'read-notion'],
    );
    expect(
      readyNodes(playbookFor('Show the open issues in Linear')!.nodes, {
        'memory',
      }).map((node) => node.id),
      ['read-linear'],
    );
    expect(playbookFor('What is a linear function?'), isNull);
    expect(
      readyNodes(playbookFor('Show records in microsoft-excel')!.nodes, {
        'memory',
      }).map((node) => node.id),
      ['read-microsoft-excel'],
    );
  });

  test('github and gmail wait on memory and not on each other', () {
    final book = playbookFor(
      'What is my GitHub login, and who sent my latest Gmail?',
    );
    expect(book, isNotNull);
    final memoryDone = readyNodes(book!.nodes, {});
    expect(memoryDone.map((node) => node.id), ['memory']);
    final reads = readyNodes(book.nodes, {'memory'});
    expect(reads.map((node) => node.id), ['read-github', 'read-gmail']);
  });

  test('a failed read stays failed in the checkpoint', () async {
    final book = playbookFor('What is my GitHub login?');
    final checkpoint = await runGraph(
      book: book!,
      ask: 'What is my GitHub login?',
      call: (tool, arguments) async {
        if (tool == 'memory_search') {
          return '{"type":"text","text":"no memories"}';
        }
        return '{"type":"text","text":"One could not read github (failed)."}';
      },
    );
    expect(checkpoint.calls.map((call) => call.tool), [
      'memory_search',
      'connector',
    ]);
    expect(checkpoint.calls.last.failed, isTrue);
    expect(checkpoint.note, contains('did not return'));
    expect(checkpoint.note, contains('do not have'));
    expect(checkpoint.note, isNot(contains('able to')));
    expect(checkpoint.waves, hasLength(2));
    expect(checkpoint.needsAnotherWay, isFalse);
  });

  test('a missing account names the connector to add', () async {
    final book = playbookFor('What is in my Google Drive?');
    final checkpoint = await runGraph(
      book: book!,
      ask: 'What is in my Google Drive?',
      call: (tool, arguments) async {
        if (tool == 'memory_search') {
          return '{"type":"text","text":"no memories"}';
        }
        return '{"type":"text","text":"google-drive is not connected."}';
      },
    );
    expect(checkpoint.needsAnotherWay, isTrue);
    expect(checkpoint.note, contains('Connectors screen'));
    expect(checkpoint.note, isNot(contains('did not return')));
  });

  test('a word that is not stored is not the nearest mailbox', () {
    final kept = memoriesForAsk(
      'What do you remember about the word quorinth?',
      [
        {
          'kind': 'email',
          'title': 'OAuth Application Approval',
          'body': 'From: Supabase. A new OAuth application was authorized.',
        },
        {'kind': 'note', 'title': 'Checks', 'body': 'You confirmed readiness.'},
      ],
    );
    expect(kept, isEmpty);
    final ferry = memoriesForAsk('What do you remember about the ferry?', [
      {'kind': 'email', 'title': 'Tonight', 'body': 'Ada is on the ferry.'},
      {'kind': 'note', 'title': 'Checks', 'body': 'You confirmed readiness.'},
    ]);
    expect(ferry, hasLength(1));
    expect(ferry.single['title'], 'Tonight');
  });

  test('github notes are not the live account', () {
    final kept = memoriesForAsk('What is my GitHub login?', [
      {
        'kind': 'session',
        'title': 'Checks',
        'body': 'You asked about GitHub access.',
      },
      {
        'kind': 'email',
        'title': 'bennettchamberlain/maia',
        'body': 'The GitHub repository maia.',
      },
    ]);
    expect(kept, isEmpty);
  });

  test('earlier notes that mention github still read the account', () async {
    const notes = '''
{"type":"timeline","title":"Memory","children":[{"type":"memory","kind":"session","title":"Checks","body":"You asked about GitHub access. You asked for your repositories."},{"type":"memory","kind":"note","title":"Checks","body":"Assistant confirmed no Gmail access."}]}
''';
    final book = playbookFor(
      'What is my GitHub login, and who sent my latest Gmail?',
    );
    final platforms = <String>[];
    final checkpoint = await runGraph(
      book: book!,
      ask: 'What is my GitHub login, and who sent my latest Gmail?',
      call: (tool, arguments) async {
        if (tool == 'memory_search') return notes;
        final decoded = jsonDecode(arguments) as Map<String, dynamic>;
        final platform = '${decoded['platform']}';
        platforms.add(platform);
        return '{"type":"text","text":"One could not read $platform (failed)."}';
      },
    );
    expect(platforms, ['github', 'gmail']);
    expect(checkpoint.calls.map((call) => call.tool), [
      'memory_search',
      'connector',
      'connector',
    ]);
    expect(checkpoint.note, contains('earlier notes'));
    expect(checkpoint.note, contains('did not return'));
  });
}
