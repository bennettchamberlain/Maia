/// Turns a transcript into quoted lines for the chat.
///
/// The on-device recognizer is one voice, so the whole turn is one quote.
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
  return _wrap(lines.join(' '));
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
