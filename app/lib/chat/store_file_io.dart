import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:maie_app/chat/draft.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Copies a picked file into the app documents folder under `chat-files`.
/// [rootPath] overrides that folder in tests.
Future<StoredChatFile> storePickedFile(XFile file, {String? rootPath}) async {
  final dir = Directory(
    rootPath ?? '${(await getApplicationDocumentsDirectory()).path}/chat-files',
  );
  await dir.create(recursive: true);
  final safe = _safeName(file.name);
  final dest = File(
    '${dir.path}/${DateTime.now().toUtc().microsecondsSinceEpoch}-$safe',
  );
  await dest.writeAsBytes(await file.readAsBytes());
  return StoredChatFile(
    name: file.name.trim().isEmpty ? safe : file.name,
    path: dest.path,
  );
}

String _safeName(String name) {
  final cleaned = name.trim().replaceAll(RegExp(r'[/\\:]+'), '_');
  return cleaned.isEmpty ? 'file' : cleaned;
}

Widget filePreview(StoredChatFile file, {double size = 20}) {
  if (!file.isImage) return Icon(LucideIcons.file, size: size * 0.7);
  return ClipRRect(
    borderRadius: const BorderRadius.all(Radius.circular(4)),
    child: Image.file(
      File(file.path),
      width: size,
      height: size,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => Icon(LucideIcons.file, size: size * 0.7),
    ),
  );
}
