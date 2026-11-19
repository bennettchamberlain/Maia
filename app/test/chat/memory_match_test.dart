import 'package:flutter_test/flutter_test.dart';
import 'package:maie_app/chat/memory_match.dart';
import 'package:maie_app/chat/parts/chat_part.dart';

void main() {
  test('quorinth does not show the nearest mailbox', () {
    final part = ChatTimeline(
      title: 'Memory',
      children: [
        const ChatMemory(
          title: 'OAuth Application Approval',
          kind: 'email',
          body: 'From: Supabase. A new OAuth application was authorized.',
        ),
        const ChatMemory(
          title: 'Checks',
          kind: 'note',
          body: 'You confirmed readiness.',
        ),
      ],
    );
    expect(
      withoutUnrelatedMemory(
        part,
        'What do you remember about the word quorinth?',
      ),
      isNull,
    );
  });

  test('a github mail is not the live account', () {
    final part = ChatColumn([
      ChatTimeline(
        title: 'Memory',
        children: const [
          ChatMemory(
            title: 'Checks',
            kind: 'session',
            body: 'You asked about GitHub access.',
          ),
        ],
      ),
    ]);
    expect(withoutUnrelatedMemory(part, 'What is my GitHub login?'), isNull);
  });

  test('a tool lecture is not part of the reply', () {
    expect(
      replyWithoutToolLecture(
        'I do not have the account. '
        'The connector can return information about GitHub users.',
      ),
      'I do not have the account.',
    );
    expect(
      replyWithoutToolLecture(
        'GitHub is able to return a login. I do not have the account.',
      ),
      'I do not have the account.',
    );
  });
}
