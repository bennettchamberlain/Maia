import 'package:flutter_test/flutter_test.dart';
import 'package:maia_app/chat/quote.dart';

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
}
