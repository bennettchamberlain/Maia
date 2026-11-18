import 'package:flutter/widgets.dart';
import 'package:maia_app/chat/draft.dart';
import 'package:maia_app/chat/store_file_stub.dart'
    if (dart.library.io) 'package:maia_app/chat/store_file_io.dart'
    as impl;

export 'package:maia_app/chat/store_file_stub.dart'
    if (dart.library.io) 'package:maia_app/chat/store_file_io.dart'
    show storePickedFile;

Widget filePreview(StoredChatFile file, {double size = 20}) =>
    impl.filePreview(file, size: size);
