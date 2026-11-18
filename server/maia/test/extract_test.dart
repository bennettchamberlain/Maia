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

  test('the first One call tells the model which action to run', () {
    final text = connectorActionPrompt('notion', [
      {'action_id': 'search', 'title': 'Search pages', 'knowledge': 'query'},
    ]);
    expect(text, contains('action_id: search'));
    expect(text, contains('copied into memory'));
  });

  test('harness text is stripped from a public reply', () {
    const leak = 'Call connector again for github with one action_id below';
    final raw =
        'Yes, I can access GitHub. What would you like to do?\n$leak\nfoo';
    expect(publicChatText(raw), 'Yes, I can access GitHub.');
    expect(looksLikeConnectorHarnessText(leak), isTrue);
  });
}