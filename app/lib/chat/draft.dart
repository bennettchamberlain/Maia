/// A file copied into Maia's own storage. The chat sees [path]. The user
/// sees [name].
class StoredChatFile {
  const new({required this.name, required this.path});

  final String name;
  final String path;

  bool get isImage {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    const images = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'heic', 'bmp'};
    return images.contains(name.substring(dot + 1).toLowerCase());
  }
}

String fileToken(StoredChatFile file) {
  final name = Uri.encodeComponent(file.name);
  final path = Uri.encodeComponent(file.path);
  return '[[file:$name|$path]]';
}

final _token = RegExp(r'\[\[file:([^|\]]+)\|([^\]]+)\]\]');

/// One slice of a message: words, or a stored file.
sealed class MessageRun {
  const new();
}

class MessageText extends MessageRun {
  const new(this.text);
  final String text;
}

class MessageFile extends MessageRun {
  const new(this.file);
  final StoredChatFile file;
}

List<MessageRun> messageRuns(String wire) {
  final runs = <MessageRun>[];
  var start = 0;
  for (final match in _token.allMatches(wire)) {
    if (match.start > start) {
      runs.add(MessageText(wire.substring(start, match.start)));
    }
    runs.add(
      MessageFile(
        StoredChatFile(
          name: Uri.decodeComponent(match.group(1)!),
          path: Uri.decodeComponent(match.group(2)!),
        ),
      ),
    );
    start = match.end;
  }
  if (start < wire.length) runs.add(MessageText(wire.substring(start)));
  if (runs.isEmpty) runs.add(MessageText(wire));
  return runs;
}

/// The composer. Text pieces always bookend the files so a chip can sit
/// at either end or in the middle of a sentence.
sealed class DraftPiece {
  const new();
}

class ChatDraft {
  new() : pieces = [DraftText('')];

  final List<DraftPiece> pieces;

  Iterable<DraftText> get texts => pieces.whereType<DraftText>();

  bool get hasContent => pieces.any(
    (piece) =>
        piece is DraftFile ||
        (piece is DraftText && piece.text.trim().isNotEmpty),
  );

  DraftText insertFile(StoredChatFile file, {int? textId, int offset = 0}) {
    final text = _text(textId) ?? texts.last;
    final at = offset.clamp(0, text.text.length);
    final index = pieces.indexOf(text);
    final left = DraftText(text.text.substring(0, at));
    final right = DraftText(text.text.substring(at));
    pieces
      ..removeAt(index)
      ..insertAll(index, [left, DraftFile(file), right]);
    return right;
  }

  /// Moves [file] into [textId] at [offset]. Adjacent words join first so
  /// the chip does not split a piece that no longer exists.
  void moveFile(DraftFile file, {required int textId, required int offset}) {
    final target = _text(textId);
    if (target == null) return;
    final from = pieces.indexOf(file);
    if (from < 0) return;
    var at = offset.clamp(0, target.text.length);
    pieces.removeAt(from);
    at = _merge(keep: target, offset: at);
    final index = pieces.indexOf(target);
    final left = DraftText(target.text.substring(0, at));
    final right = DraftText(target.text.substring(at));
    pieces
      ..removeAt(index)
      ..insertAll(index, [left, file, right]);
  }

  void removeFile(DraftFile file) {
    final index = pieces.indexOf(file);
    if (index < 0) return;
    pieces.removeAt(index);
    _merge();
    if (pieces.isEmpty) pieces.add(DraftText(''));
  }

  void reset() {
    pieces
      ..clear()
      ..add(DraftText(''));
  }

  String wire() {
    final buf = StringBuffer();
    for (final piece in pieces) {
      switch (piece) {
        case DraftText(:final text):
          buf.write(text);
        case DraftFile(:final file):
          buf.write(fileToken(file));
      }
    }
    return buf.toString();
  }

  DraftText? _text(int? id) {
    if (id == null) return null;
    for (final text in texts) {
      if (text.id == id) return text;
    }
    return null;
  }

  /// Joins neighboring text. When [keep] is the right-hand piece, [offset]
  /// shifts by the words that joined in front of it.
  int _merge({DraftText? keep, int offset = 0}) {
    var cursor = offset;
    var i = 0;
    while (i < pieces.length - 1) {
      final left = pieces[i];
      final right = pieces[i + 1];
      if (left is DraftText && right is DraftText) {
        if (identical(right, keep)) {
          cursor += left.text.length;
          right.text = left.text + right.text;
          pieces
            ..[i] = right
            ..removeAt(i + 1);
          continue;
        }
        left.text = left.text + right.text;
        pieces.removeAt(i + 1);
        continue;
      }
      i++;
    }
    return cursor;
  }
}

class DraftText extends DraftPiece {
  new(this.text) : id = _next++;

  static int _next = 0;
  final int id;
  String text;
}

class DraftFile extends DraftPiece {
  new(this.file);
  final StoredChatFile file;
}
