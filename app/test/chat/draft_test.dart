import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maia_app/chat/draft.dart';
import 'package:maia_app/chat/store_file.dart';

void main() {
  test('a chip in the middle keeps the path and the name', () {
    final draft = ChatDraft()..texts.single.text = 'hello world';
    const file = StoredChatFile(
      name: 'Notes.txt',
      path: '/tmp/a b/Notes.txt',
    );
    draft.insertFile(file, offset: 6);
    final wire = draft.wire();
    expect(wire, 'hello ${fileToken(file)}world');
    final runs = messageRuns(wire);
    expect((runs[0] as MessageText).text, 'hello ');
    expect((runs[1] as MessageFile).file.name, 'Notes.txt');
    expect((runs[1] as MessageFile).file.path, '/tmp/a b/Notes.txt');
    expect((runs[2] as MessageText).text, 'world');
  });

  test('a chip can move to the front of the sentence', () {
    final draft = ChatDraft()..texts.single.text = 'hello world';
    const file = StoredChatFile(name: 'a.txt', path: '/tmp/a.txt');
    draft.insertFile(file, offset: 6);
    final piece = draft.pieces.whereType<DraftFile>().single;
    final first = draft.texts.first;
    draft.moveFile(piece, textId: first.id, offset: 0);
    expect(draft.wire(), '${fileToken(file)}hello world');
  });

  test('picked files are copied into storage under their own name', () async {
    final root = await Directory.systemTemp.createTemp('maia-files');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}/note.txt');
    await source.writeAsString('hello');
    final stored = await storePickedFile(
      XFile(source.path),
      rootPath: '${root.path}/stored',
    );
    expect(stored.name, 'note.txt');
    expect(stored.path, startsWith(root.path));
    expect(await File(stored.path).readAsString(), 'hello');
  });
}
