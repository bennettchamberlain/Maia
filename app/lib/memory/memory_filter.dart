import 'package:maia_models/maia_models.dart';

/// What a memory-page phrase asked for. Empty fields mean "leave that alone".
class MemoryPhrase {
  const MemoryPhrase({
    this.platform,
    this.after,
    this.before,
    this.words = const [],
    this.when,
  });

  final String? platform;
  final DateTime? after;
  final DateTime? before;
  final List<String> words;

  /// A short label for the time window, when one was named.
  final String? when;

  bool get narrowed => platform != null || when != null || words.isNotEmpty;
}

const _aliases = {
  'gmail': 'gmail',
  'mail': 'gmail',
  'email': 'gmail',
  'emails': 'gmail',
  'inbox': 'gmail',
  'calendar': 'google-calendar',
  'calendars': 'google-calendar',
  'github': 'github',
  'slack': 'slack',
  'notion': 'notion',
  'linear': 'linear',
};

const _skip = {
  'a',
  'an',
  'the',
  'from',
  'about',
  'my',
  'me',
  'in',
  'on',
  'of',
  'to',
  'for',
  'and',
  'with',
  'show',
  'find',
  'all',
};

/// Reads a phrase such as "gmail from Ada this week".
MemoryPhrase readMemoryPhrase(
  String raw,
  DateTime now, {
  Iterable<String> platforms = const [],
}) {
  final known = {
    for (final platform in platforms)
      if (platform.trim().isNotEmpty) platform.trim().toLowerCase(),
  };
  var text = raw.toLowerCase();
  String? when;
  DateTime? after;
  DateTime? before;
  final window = _window(text, now);
  if (window != null) {
    text = text.replaceAll(window.phrase, ' ');
    when = window.label;
    after = window.after;
    before = window.before;
  }
  text = text.replaceAll('google calendar', ' google-calendar ');
  final words = <String>[];
  String? platform;
  for (final token in text.split(RegExp(r'[^a-z0-9-]+'))) {
    if (token.isEmpty || _skip.contains(token)) continue;
    final alias = _aliases[token];
    final named = alias ?? (known.contains(token) ? token : null);
    if (named != null && platform == null) {
      platform = named;
      continue;
    }
    if (token.length < 2) continue;
    words.add(token);
  }
  return MemoryPhrase(
    platform: platform,
    after: after,
    before: before,
    words: words,
    when: when,
  );
}

/// One line for under the search box. Empty when the phrase narrowed nothing.
String memoryPhraseLine(MemoryPhrase phrase) {
  final parts = <String>[
    if (phrase.platform != null) phrase.platform!,
    if (phrase.when != null) phrase.when!,
    if (phrase.words.isNotEmpty) phrase.words.join(' '),
  ];
  return parts.join(' · ');
}

bool memoryPhraseMatches(MemoryPhrase phrase, TimelineEntry entry) {
  if (phrase.platform != null) {
    final platform = phrase.platform!;
    final source = entry.source ?? '';
    final hit =
        entry.platform == platform ||
        entry.account == platform ||
        source.contains('one:$platform');
    if (!hit) return false;
  }
  final at = entry.endedAt.toLocal();
  if (phrase.after != null && at.isBefore(phrase.after!)) return false;
  if (phrase.before != null && !at.isBefore(phrase.before!)) return false;
  if (phrase.words.isEmpty) return true;
  final hay = [
    entry.title,
    entry.body,
    entry.platform,
    entry.account,
    entry.source,
    ...entry.topics,
  ].whereType<String>().join(' ').toLowerCase();
  return phrase.words.every(hay.contains);
}

class _Window {
  const _Window(this.phrase, this.label, this.after, this.before);

  final String phrase;
  final String label;
  final DateTime after;
  final DateTime? before;
}

_Window? _window(String text, DateTime now) {
  final day = DateTime(now.year, now.month, now.day);
  if (text.contains('last week')) {
    final start = day.subtract(Duration(days: day.weekday + 6));
    return _Window(
      'last week',
      'last week',
      start,
      start.add(const Duration(days: 7)),
    );
  }
  if (text.contains('this week')) {
    final start = day.subtract(Duration(days: day.weekday - 1));
    return _Window('this week', 'this week', start, null);
  }
  if (text.contains('this month')) {
    return _Window(
      'this month',
      'this month',
      DateTime(now.year, now.month),
      null,
    );
  }
  if (text.contains('yesterday')) {
    final start = day.subtract(const Duration(days: 1));
    return _Window('yesterday', 'yesterday', start, day);
  }
  if (text.contains('today')) {
    return _Window('today', 'today', day, null);
  }
  return null;
}
