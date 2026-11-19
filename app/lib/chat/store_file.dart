import 'package:flutter/widgets.dart';
import 'package:maie_app/chat/draft.dart';
import 'package:maie_app/chat/store_file_stub.dart'
    if (dart.library.io) 'package:maie_app/chat/store_file_io.dart'
    as impl;

export 'package:maie_app/chat/store_file_stub.dart'
    if (dart.library.io) 'package:maie_app/chat/store_file_io.dart'
    show storePickedFile;

Widget filePreview(StoredChatFile file, {double size = 20}) =>
    impl.filePreview(file, size: size);
