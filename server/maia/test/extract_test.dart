import 'package:maia_api/src/one/extract.dart';
import 'package:test/test.dart';

void main() {
  test('gmail headers and a slack row both copy', () {
    final mail = connectorCopies('gmail', {
      'messages': [
        {
          'id': 'm1',
          'snippet': 'See you at the ferry',
          'internalDate': '1700000000000',
          'payload': {
            'headers': [
              {'name': 'Subject', 'value': 'Tonight'},
              {'name': 'From', 'value': 'Ada'},
            ],
          },
        },
      ],
    });
    expect(mail, hasLength(1));
    expect(mail.single.title, 'Tonight');
    expect(mail.single.body, contains('Ada'));
    expect(mail.single.kind, 'email');
    expect(mail.single.sourceId, 'm1');

    final slack = connectorCopies('slack', {
      'messages': [
        {'ts': '1.2', 'text': 'ship the glasses'},
      ],
    });
    expect(slack.single.title, 'ship the glasses');
    expect(slack.single.body, 'ship the glasses');
    expect(slack.single.kind, 'note');
    expect(slack.single.sourceId, '1.2');
  });

  test('a github user and a repo list both copy', () {
    final user = connectorCopies('github', {
      'id': 7,
      'login': 'bennettchamberlain',
      'name': 'Bennett',
      'bio': 'memory',
    });
    expect(user.single.title, 'Bennett');
    expect(user.single.body, contains('bennettchamberlain'));
    expect(user.single.body, contains('memory'));
    expect(user.single.sourceId, '7');

    final repos = connectorCopies('github', {
      'repositories': [
        {
          'id': 9,
          'full_name': 'bennettchamberlain/maia',
          'description': 'the record',
          'owner': {'login': 'bennettchamberlain'},
        },
      ],
    });
    expect(repos.single.title, 'bennettchamberlain/maia');
    expect(repos.single.body, contains('the record'));
  });

  test('a gmail row is a reading, not only a subject', () {
    final rows = connectorCopies('gmail', {
      'messages': [
        {
          'id': 'm1',
          'snippet': 'See you at the ferry',
          'payload': {
            'headers': [
              {'name': 'Subject', 'value': 'Tonight'},
              {'name': 'From', 'value': 'Ada'},
            ],
          },
        },
      ],
    });
    final brief = connectorBrief('gmail', rows.length, rows);
    expect(brief, contains('Tonight'));
    expect(brief, contains('Ada'));
    expect(brief, contains('ferry'));
    expect(brief, isNot(contains('Copied')));
  });

  test('the first One call tells the model which action to run', () {
    final text = connectorActionPrompt('notion', [
      {'action_id': 'search', 'title': 'Search pages', 'knowledge': 'query'},
    ]);
    expect(text, contains('action_id: search'));
    expect(text, contains('copied into memory'));
    final named = connectorActionPrompt(
      'github',
      [
        {'action_id': 'repos', 'title': 'List repos'},
      ],
      account: 'bennettchamberlain',
    );
    expect(named, contains('bennettchamberlain'));
    expect(named, contains('path_params'));
  });

  test('harness text is stripped from a public reply', () {
    const leak = 'Call connector again for github with one action_id below';
    final raw =
        'Yes, I can access GitHub. What would you like to do?\n$leak\nfoo';
    expect(publicChatText(raw), 'Yes, I can access GitHub.');
    expect(looksLikeConnectorHarnessText(leak), isTrue);
  });
}