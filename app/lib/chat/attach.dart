import 'dart:convert';

/// Text the composer inserts for a picked file.
///
/// Plain text is included, capped so a huge file does not become the whole
/// prompt. Anything that is not text is named and sized instead.
/// Name from an [attachmentNote], for the file row in the thread.
String fileLabel(String note) {
  final match = RegExp(r'^\[file: ([^,\]]+)').firstMatch(note.trim());
  return match?.group(1)?.trim() ?? note.trim();
}

String attachmentNote({
  required String name,
  required int length,
  List<int>? bytes,
}) {
  const maxBytes = 48000;
  const maxChars = 12000;
  if (bytes == null || length > maxBytes || bytes.length > maxBytes) {
    return '[file: $name, $length bytes]';
  }
  try {
    final text = utf8.decode(bytes);
    if (text.contains('\u0000')) {
      return '[file: $name, $length bytes]';
    }
    final body = text.length > maxChars
        ? '${text.substring(0, maxChars)}\n…'
        : text;
    return '[file: $name]\n$body';
  } on FormatException {
    return '[file: $name, $length bytes]';
  }
}
