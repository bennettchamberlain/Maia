import 'package:maia_app/ghost/ghost_store_stub.dart'
    if (dart.library.io) 'package:maia_app/ghost/ghost_store_io.dart'
    as store;

/// One png in the tape folder, or null when this platform cannot store it.
Future<String?> saveShot(List<int> png) => store.saveShot(png);

/// Replaces the tape file with [json].
Future<void> saveTape(String json) => store.saveTape(json);

/// The current tape, or null when none has been written.
Future<String?> readTape() => store.readTape();

/// The png named [name] in the tape folder.
Future<List<int>?> readShot(String name) => store.readShot(name);

/// Folder that holds `tape.json` and the frames.
String? tapeDirectory() => store.tapeDirectory();
