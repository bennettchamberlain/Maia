import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:maia_app/chat/draft.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

Future<StoredChatFile> storePickedFile(XFile file, {String? rootPath}) async {
  throw UnsupportedError('File storage needs a device directory.');
}

Widget filePreview(StoredChatFile file, {double size = 20}) {
  return Icon(LucideIcons.file, size: size * 0.7, semanticLabel: file.name);
}
