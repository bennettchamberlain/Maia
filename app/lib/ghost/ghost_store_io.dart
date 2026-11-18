import 'dart:io';

Directory? _dir;

Directory _folder() {
  final dir = _dir ??= Directory('${Directory.systemTemp.path}/maia-ghost');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}

/// Writes one frame and returns its file name.
Future<String?> saveShot(List<int> png) async {
  final name = '${DateTime.now().microsecondsSinceEpoch}.png';
  await File('${_folder().path}/$name').writeAsBytes(png, flush: true);
  return name;
}

Future<void> saveTape(String json) async {
  await File('${_folder().path}/tape.json').writeAsString(json, flush: true);
}

Future<String?> readTape() {
  final file = File('${_folder().path}/tape.json');
  if (!file.existsSync()) return Future.value();
  return file.readAsString();
}

Future<List<int>?> readShot(String name) {
  final file = File('${_folder().path}/$name');
  if (!file.existsSync()) return Future.value();
  return file.readAsBytes();
}

String? tapeDirectory() => _folder().path;
