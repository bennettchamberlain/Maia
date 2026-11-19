import 'dart:convert';
import 'dart:io';

/// One row in a person's directory. The file is the bytes.
/// This row is how the list stays short.
class LibraryEntry {
  const LibraryEntry({
    required this.id,
    required this.kind,
    required this.name,
    required this.line,
    required this.uses,
    required this.updatedAt,
  });

  factory LibraryEntry.fromJson(Map<String, dynamic> json) => LibraryEntry(
    id: '${json['id'] ?? ''}',
    kind: '${json['kind'] ?? ''}',
    name: '${json['name'] ?? ''}',
    line: '${json['line'] ?? ''}',
    uses: (json['uses'] as num?)?.toInt() ?? 0,
    updatedAt:
        DateTime.tryParse('${json['updated_at']}') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );

  final String id;

  /// `skills`, `files`, or `turns`.
  final String kind;
  final String name;
  final String line;
  final int uses;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'name': name,
    'line': line,
    'uses': uses,
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}

/// The three lists. Skills by name, files by use, turns newest first.
class LibrarySnapshot {
  const LibrarySnapshot({
    this.skills = const [],
    this.files = const [],
    this.turns = const [],
  });

  static const empty = LibrarySnapshot();

  final List<LibraryEntry> skills;
  final List<LibraryEntry> files;
  final List<LibraryEntry> turns;

  bool get isEmpty => skills.isEmpty && files.isEmpty && turns.isEmpty;

  Map<String, dynamic> toJson() => {
    'skills': [for (final row in skills) row.toJson()],
    'files': [for (final row in files) row.toJson()],
    'turns': [for (final row in turns) row.toJson()],
  };
}

/// The text a session loads. Names and one line. Bodies stay in the files.
String loadIndex(LibrarySnapshot library, {List<String> timeline = const []}) {
  final parts = <String>[];
  if (library.skills.isNotEmpty) {
    parts.add('Skills:\n${_lines(library.skills.take(12))}');
  }
  if (library.files.isNotEmpty) {
    parts.add('Files used most:\n${_lines(library.files.take(8))}');
  }
  if (library.turns.isNotEmpty) {
    parts.add('Last turns:\n${_lines(library.turns.take(6))}');
  }
  final cards = [
    for (final title in timeline)
      if (title.trim().isNotEmpty) title.trim(),
  ];
  if (cards.isNotEmpty) {
    parts.add(
      'Recent timeline:\n${cards.take(8).map((t) => '- $t').join('\n')}',
    );
  }
  return parts.join('\n\n');
}

String _lines(Iterable<LibraryEntry> rows) => rows
    .map((row) {
      final line = row.line.isEmpty ? '' : ': ${row.line}';
      return '- ${row.name}$line';
    })
    .join('\n');

/// First non-empty line, clipped. The list shows this, not the file.
String libraryLine(String body) {
  for (final raw in body.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    return line.length <= 120 ? line : line.substring(0, 120);
  }
  return '';
}

/// `{root}/{person}/{skills|files|turns}/{id}.md` plus `index.json`.
class PersonLibrary {
  PersonLibrary(this.root);

  final Directory root;

  static const kinds = ['skills', 'files', 'turns'];

  Future<void> write({
    required String personId,
    required String kind,
    required String id,
    required String name,
    required String body,
    bool bump = false,
  }) async {
    final who = _safe(personId);
    final key = _safe(id);
    if (!kinds.contains(kind) || who.isEmpty || key.isEmpty) return;
    final dir = Directory('${_home(who).path}/$kind');
    await dir.create(recursive: true);
    final file = File('${dir.path}/$key.md');
    await file.writeAsString(body);
    final index = _read(who);
    final prior = index[kind]?[key];
    final uses = prior == null ? 1 : prior.uses + (bump ? 1 : 0);
    index.putIfAbsent(kind, () => {});
    index[kind]![key] = LibraryEntry(
      id: key,
      kind: kind,
      name: name.trim().isEmpty ? key : name.trim(),
      line: libraryLine(body),
      uses: uses,
      updatedAt: DateTime.now().toUtc(),
    );
    _save(who, index);
  }

  /// Gel already has the row. Write the file only when the disk does not.
  Future<void> putIfAbsent({
    required String personId,
    required String kind,
    required String id,
    required String name,
    required String body,
  }) async {
    final who = _safe(personId);
    final key = _safe(id);
    if (who.isEmpty || key.isEmpty || !kinds.contains(kind)) return;
    final file = File('${_home(who).path}/$kind/$key.md');
    if (file.existsSync()) return;
    await write(personId: who, kind: kind, id: key, name: name, body: body);
  }

  LibrarySnapshot snapshot(String personId) {
    final who = _safe(personId);
    if (who.isEmpty) return LibrarySnapshot.empty;
    final index = _read(who);
    final repaired = _absorb(who, index);
    if (repaired) _save(who, index);
    List<LibraryEntry> of(String kind) => (index[kind] ?? {}).values.toList();
    final skills = of('skills')
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final files = of('files')
      ..sort((a, b) {
        final byUse = b.uses.compareTo(a.uses);
        if (byUse != 0) return byUse;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    final turns = of('turns')
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return LibrarySnapshot(skills: skills, files: files, turns: turns);
  }

  /// Copies the database open count onto the file index.
  void setUses({
    required String personId,
    required String id,
    required int uses,
  }) {
    final who = _safe(personId);
    final key = _safe(id);
    if (who.isEmpty || key.isEmpty) return;
    final index = _read(who);
    final prior = index['files']?[key];
    if (prior == null) return;
    index['files']![key] = LibraryEntry(
      id: prior.id,
      kind: prior.kind,
      name: prior.name,
      line: prior.line,
      uses: uses,
      updatedAt: prior.updatedAt,
    );
    _save(who, index);
  }

  /// Returns the file. Opening a file counts as a use. Skills and turns do not.
  Future<String?> read({
    required String personId,
    required String kind,
    required String id,
  }) async {
    final who = _safe(personId);
    final key = _safe(id);
    if (who.isEmpty || key.isEmpty || !kinds.contains(kind)) return null;
    final file = File('${_home(who).path}/$kind/$key.md');
    if (!file.existsSync()) return null;
    final body = await file.readAsString();
    if (kind == 'files') {
      final index = _read(who);
      final prior = index['files']?[key];
      if (prior != null) {
        index['files']![key] = LibraryEntry(
          id: prior.id,
          kind: prior.kind,
          name: prior.name,
          line: prior.line,
          uses: prior.uses + 1,
          updatedAt: DateTime.now().toUtc(),
        );
        _save(who, index);
      }
    }
    return body;
  }

  Directory _home(String personId) => Directory('${root.path}/$personId');

  Map<String, Map<String, LibraryEntry>> _read(String personId) {
    final file = File('${_home(personId).path}/index.json');
    if (!file.existsSync()) return {};
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return {};
      final out = <String, Map<String, LibraryEntry>>{};
      for (final kind in kinds) {
        final rows = decoded[kind];
        if (rows is! List) continue;
        out[kind] = {
          for (final row in rows)
            if (row is Map)
              '${row['id']}': LibraryEntry.fromJson(
                Map<String, dynamic>.from(row),
              ),
        };
      }
      return out;
    } on Object {
      return {};
    }
  }

  void _save(String personId, Map<String, Map<String, LibraryEntry>> index) {
    final home = _home(personId)..createSync(recursive: true);
    File('${home.path}/index.json').writeAsStringSync(
      jsonEncode({
        for (final kind in kinds)
          kind: [for (final row in (index[kind] ?? {}).values) row.toJson()],
      }),
    );
  }

  bool _absorb(String personId, Map<String, Map<String, LibraryEntry>> index) {
    var changed = false;
    for (final kind in kinds) {
      final dir = Directory('${_home(personId).path}/$kind');
      if (!dir.existsSync()) continue;
      for (final entity in dir.listSync()) {
        if (entity is! File || !entity.path.endsWith('.md')) continue;
        final id = entity.uri.pathSegments.last.replaceAll('.md', '');
        final bucket = index.putIfAbsent(kind, () => {});
        if (bucket.containsKey(id)) continue;
        final body = entity.readAsStringSync();
        bucket[id] = LibraryEntry(
          id: id,
          kind: kind,
          name: id,
          line: libraryLine(body),
          uses: 0,
          updatedAt: entity.lastModifiedSync().toUtc(),
        );
        changed = true;
      }
    }
    return changed;
  }

  static String _safe(String raw) =>
      raw.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
}
