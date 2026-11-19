import 'dart:io';

/// The One callback page. Black-and-white instrument, one sunset band.
String oneDoneHtml({required String title, required String text}) {
  final page = _template()
      .replaceAll('__TITLE__', _esc(title))
      .replaceAll('__TEXT__', _esc(text));
  return page;
}

String _template() {
  if (_cached != null) return _cached!;
  for (final path in _paths()) {
    final file = File(path);
    if (file.existsSync()) {
      _cached = file.readAsStringSync();
      return _cached!;
    }
  }
  return _plain;
}

List<String> _paths() {
  final beside = File.fromUri(
    Platform.script.resolve('../lib/src/one/done_page.html'),
  ).path;
  return [
    beside,
    'lib/src/one/done_page.html',
    'server/maie/lib/src/one/done_page.html',
  ];
}

String _esc(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String? _cached;

const _plain =
    '<!doctype html><meta charset="utf-8"><title>__TITLE__</title>'
    '<body style="font:16px/1.4 system-ui;background:#000;color:#fff">'
    '<h1>__TITLE__</h1><p>__TEXT__</p></body>';
