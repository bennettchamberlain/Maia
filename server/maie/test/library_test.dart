import 'dart:io';

import 'package:maie_api/src/library/store.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late PersonLibrary library;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('maie-library');
    library = PersonLibrary(root);
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test('skills list by name, files by use, turns by time', () async {
    await library.write(
      personId: 'p1',
      kind: 'skills',
      id: 'ship',
      name: 'Ship',
      body: 'Run the checks first.',
    );
    await library.write(
      personId: 'p1',
      kind: 'skills',
      id: 'rollback',
      name: 'Rollback',
      body: 'Keep the last tag.',
    );
    await library.write(
      personId: 'p1',
      kind: 'files',
      id: 'notes',
      name: 'Notes',
      body: 'Lisbon.',
      bump: true,
    );
    await library.write(
      personId: 'p1',
      kind: 'files',
      id: 'notes',
      name: 'Notes',
      body: 'Lisbon again.\nThe rest stays in the file.',
      bump: true,
    );
    await library.write(
      personId: 'p1',
      kind: 'files',
      id: 'map',
      name: 'Map',
      body: 'One open.',
    );
    await library.write(
      personId: 'p1',
      kind: 'turns',
      id: 'night',
      name: 'Night',
      body: 'Researched the glasses.',
    );

    final snap = library.snapshot('p1');
    expect(snap.skills.map((s) => s.name), ['Rollback', 'Ship']);
    expect(snap.files.first.name, 'Notes');
    expect(snap.files.first.uses, 2);
    expect(snap.turns.single.line, 'Researched the glasses.');

    final index = loadIndex(snap, timeline: const ['Standup']);
    expect(index, contains('Skills:'));
    expect(index, contains('- Rollback: Keep the last tag.'));
    expect(index, contains('Recent timeline:\n- Standup'));
    expect(index, isNot(contains('The rest stays')));
  });

  test('a second write leaves an existing file alone', () async {
    await library.write(
      personId: 'p1',
      kind: 'skills',
      id: 'ship',
      name: 'Ship',
      body: 'First.',
    );
    await library.putIfAbsent(
      personId: 'p1',
      kind: 'skills',
      id: 'ship',
      name: 'Ship',
      body: 'Second.',
    );
    final body = await library.read(personId: 'p1', kind: 'skills', id: 'ship');
    expect(body, 'First.');
  });

  test('opening a file counts, opening a skill does not', () async {
    await library.write(
      personId: 'p1',
      kind: 'files',
      id: 'notes',
      name: 'Notes',
      body: 'Lisbon.',
    );
    await library.read(personId: 'p1', kind: 'files', id: 'notes');
    await library.write(
      personId: 'p1',
      kind: 'skills',
      id: 'ship',
      name: 'Ship',
      body: 'Run the checks.',
    );
    await library.read(personId: 'p1', kind: 'skills', id: 'ship');
    final snap = library.snapshot('p1');
    expect(snap.files.single.uses, 2);
    expect(snap.skills.single.uses, 1);
  });

  test('a database open count replaces the index count', () async {
    await library.write(
      personId: 'p1',
      kind: 'files',
      id: 'notes',
      name: 'Notes',
      body: 'Lisbon.',
    );
    library.setUses(personId: 'p1', id: 'notes', uses: 7);
    expect(library.snapshot('p1').files.single.uses, 7);
  });
}
