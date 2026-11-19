import 'package:flutter_test/flutter_test.dart';
import 'package:maie_app/chat/quote.dart';

void main() {
  test('one voice is one quote', () {
    expect(quotedSpeech('  hello there  '), '"hello there"');
    expect(quotedSpeech(''), '');
    expect(quotedSpeech('"already quoted"'), '"already quoted"');
  });

  test('two labeled speakers are quotes on their own lines', () {
    expect(
      quotedSpeech('Alex: good morning\nSam: you too'),
      '"good morning"\n"you too"',
    );
  });

  test('a single label stays one quote', () {
    expect(quotedSpeech('Note: bring milk'), '"Note: bring milk"');
  });

  test('separate thoughts are quotes on their own lines', () {
    expect(
      quotedSpeech('We should ship the glasses.\nThen walk to the ferry.'),
      '"We should ship the glasses."\n"Then walk to the ferry."',
    );
  });

  test('a growing phrase is the same thought', () {
    expect(
      newThought(previous: 'we should', next: 'we should ship', gap: thoughtPause),
      isFalse,
    );
    expect(
      newThought(
        previous: 'we should ship',
        next: 'then walk',
        gap: const Duration(milliseconds: 400),
      ),
      isFalse,
    );
    expect(
      newThought(
        previous: 'we should ship',
        next: 'then walk',
        gap: thoughtPause,
      ),
      isTrue,
    );
  });
}
