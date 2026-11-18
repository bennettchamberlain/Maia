/// A quiet gap this long, before a phrase that does not continue the
/// last one, is a new thought.
const thoughtPause = Duration(milliseconds: 1200);

/// True when [next] should start a new line after [previous].
/// A phrase that keeps growing is the same thought, even if a result
/// was slow to arrive. A long run with only a short gap stays one line.
bool newThought({
  required String previous,
  required String next,
  required Duration gap,
}) {
  final prior = previous.trim();
  final incoming = next.trim();
  if (prior.isEmpty || incoming.isEmpty) return false;
  if (incoming.startsWith(prior)) return false;
  return gap >= thoughtPause;
}

/// Adds [next] to [said]. [newLine] puts it under the previous thought.
String joinThought(String said, String next, {required bool newLine}) {
  final incoming = next.trim();
  if (incoming.isEmpty) return said.trim();
  final prior = said.trim();
  if (prior.isEmpty) return incoming;
  if (newLine) return '$prior\n$incoming';
  return '$prior $incoming';
}

/// Turns a transcript into quoted lines for the chat.
///
/// Each thought is its own quote. One continuous run stays one quote.
/// A later diarizer can pass `Name: words` lines. Two or more speakers
/// become one quoted line each.
String quotedSpeech(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return '';
  final lines = text
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  final turns = [for (final line in lines) _labeled(line)];
  final speakers = turns.whereType<_Turn>().map((turn) => turn.speaker).toSet();
  if (turns.every((turn) => turn != null) && speakers.length >= 2) {
    return turns.map((turn) => _wrap(turn!.words)).join('\n');
  }
  if (lines.length > 1) return lines.map(_wrap).join('\n');
  return _wrap(lines.single);
}

final _label = RegExp(r'^([^:]{1,32}):\s+(\S.*)$');
final _speaker = RegExp(r"^[A-Za-z][A-Za-z0-9 .'\-]{0,30}$");

_Turn? _labeled(String line) {
  final match = _label.firstMatch(line);
  if (match == null) return null;
  final speaker = match.group(1)!.trim();
  if (!_speaker.hasMatch(speaker)) return null;
  return _Turn(speaker, match.group(2)!.trim());
}

String _wrap(String words) {
  final trimmed = words.trim();
  if (trimmed.length >= 2 && trimmed.startsWith('"') && trimmed.endsWith('"')) {
    return trimmed;
  }
  return '"$trimmed"';
}

class _Turn {
  const _Turn(this.speaker, this.words);
  final String speaker;
  final String words;
}
