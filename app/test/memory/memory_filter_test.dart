import 'package:flutter_test/flutter_test.dart';
import 'package:maie_app/memory/memory_filter.dart';
import 'package:maie_models/maie_models.dart';

void main() {
  final now = DateTime(2026, 11, 18, 9);

  test('a phrase names the app, the week, and the person', () {
    final phrase = readMemoryPhrase(
      'gmail from Ada this week',
      now,
      platforms: const ['slack'],
    );
    expect(phrase.platform, 'gmail');
    expect(phrase.when, 'this week');
    expect(phrase.words, ['ada']);
    expect(memoryPhraseLine(phrase), 'gmail · this week · ada');
  });

  test('a connected app name is a filter even without an alias', () {
    final phrase = readMemoryPhrase('figma about the ferry', now);
    expect(phrase.platform, isNull);
    final known = readMemoryPhrase(
      'figma about the ferry',
      now,
      platforms: const ['figma'],
    );
    expect(known.platform, 'figma');
    expect(known.words, ['ferry']);
  });

  test('the phrase keeps the matching row and drops the rest', () {
    final phrase = readMemoryPhrase('emails from Ada yesterday', now);
    final ada = TimelineEntry(
      id: '1',
      kind: 'email',
      title: 'Tonight',
      body: 'From: Ada',
      platform: 'gmail',
      source: 'one:gmail',
      startedAt: DateTime(2026, 11, 17, 18),
      endedAt: DateTime(2026, 11, 17, 18),
    );
    final slack = TimelineEntry(
      id: '2',
      kind: 'note',
      title: 'ship it',
      platform: 'slack',
      source: 'one:slack',
      startedAt: DateTime(2026, 11, 17, 18),
      endedAt: DateTime(2026, 11, 17, 18),
    );
    expect(memoryPhraseMatches(phrase, ada), isTrue);
    expect(memoryPhraseMatches(phrase, slack), isFalse);
  });
}
