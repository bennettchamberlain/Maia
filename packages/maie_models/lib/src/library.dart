/// One skill, file, or turn, as the memory page lists it.
class LibraryEntry {
  const LibraryEntry({
    required this.id,
    required this.kind,
    required this.name,
    required this.line,
    required this.uses,
  });

  factory LibraryEntry.fromJson(Map<String, dynamic> json) => LibraryEntry(
    id: json['id'] as String? ?? '',
    kind: json['kind'] as String? ?? '',
    name: json['name'] as String? ?? '',
    line: json['line'] as String? ?? '',
    uses: (json['uses'] as num?)?.toInt() ?? 0,
  );

  final String id;
  final String kind;
  final String name;
  final String line;
  final int uses;
}

/// Skills by name, files by use, turns newest first.
class LibraryView {
  const LibraryView({
    this.skills = const [],
    this.files = const [],
    this.turns = const [],
  });

  static const empty = LibraryView();

  factory LibraryView.fromJson(Map<String, dynamic> json) => LibraryView(
    skills: _rows(json['skills']),
    files: _rows(json['files']),
    turns: _rows(json['turns']),
  );

  final List<LibraryEntry> skills;
  final List<LibraryEntry> files;
  final List<LibraryEntry> turns;

  bool get isEmpty => skills.isEmpty && files.isEmpty && turns.isEmpty;

  static List<LibraryEntry> _rows(Object? raw) => [
    for (final row in raw as List<dynamic>? ?? const [])
      if (row is Map) LibraryEntry.fromJson(Map<String, dynamic>.from(row)),
  ];
}
