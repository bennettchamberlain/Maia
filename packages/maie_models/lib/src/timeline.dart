/// A stream of a life. [kind] is `user`, `entity`, `person`, or `connection`.
class TimelineInfo {
  const TimelineInfo({
    required this.id,
    required this.key,
    required this.name,
    required this.kind,
    this.subjectName,
    this.personHandle,
    this.platform,
    this.account,
  });

  factory TimelineInfo.fromJson(Map<String, dynamic> json) => TimelineInfo(
    id: json['id'] as String,
    key: json['key'] as String? ?? '',
    name: json['name'] as String? ?? '',
    kind: timelineKind(json['type_name'] as String? ?? json['kind'] as String?),
    subjectName: json['subject_name'] as String?,
    personHandle: json['person_handle'] as String?,
    platform: json['platform'] as String?,
    account: json['account'] as String?,
  );

  final String id;
  final String key;
  final String name;
  final String kind;
  final String? subjectName;
  final String? personHandle;
  final String? platform;
  final String? account;
}

/// Maps a Gel type name onto the timeline kind the column understands.
String timelineKind(String? typeName) {
  final name = typeName ?? '';
  if (name.endsWith('UserTimeline') || name == 'user') return 'user';
  if (name.endsWith('EntityTimeline') || name == 'entity') return 'entity';
  if (name.endsWith('PersonTimeline') || name == 'person') return 'person';
  if (name.endsWith('ConnectionTimeline') || name == 'connection') {
    return 'connection';
  }
  return name;
}

/// One card on a timeline: a chat, a mail, a calendar event, a file.
class TimelineEntry {
  const TimelineEntry({
    required this.id,
    required this.kind,
    required this.startedAt,
    required this.endedAt,
    this.title,
    this.body,
    this.topics = const [],
    this.sessionId,
    this.platform,
    this.account,
    this.source,
  });

  factory TimelineEntry.fromJson(Map<String, dynamic> json) => TimelineEntry(
    id: json['id'] as String,
    kind: json['kind'] as String? ?? 'connector',
    title: json['title'] as String?,
    body: json['body'] as String?,
    topics: [
      for (final topic in json['topics'] as List<dynamic>? ?? const [])
        if (topic is String) topic,
    ],
    startedAt: DateTime.parse(json['started_at'] as String),
    endedAt: DateTime.parse(json['ended_at'] as String),
    sessionId: json['session_id'] as String?,
    platform: json['platform'] as String?,
    account: json['account'] as String?,
    source: json['source'] as String?,
  );

  /// A chat that is not on the timeline yet, drawn the same way.
  factory TimelineEntry.fromSession({
    required String sessionId,
    required DateTime createdAt,
    String? title,
    DateTime? firstMessageAt,
    DateTime? lastMessageAt,
    List<String> topics = const [],
  }) => TimelineEntry(
    id: 'session-$sessionId',
    kind: 'session',
    title: title,
    topics: topics,
    startedAt: firstMessageAt ?? createdAt,
    endedAt: lastMessageAt ?? firstMessageAt ?? createdAt,
    sessionId: sessionId,
  );

  final String id;
  final String kind;
  final String? title;
  final String? body;
  final List<String> topics;
  final DateTime startedAt;
  final DateTime endedAt;
  final String? sessionId;
  final String? platform;
  final String? account;
  final String? source;

  bool get isSession => kind == 'session' && sessionId != null;

  TimelineEntry copyWith({
    String? title,
    List<String>? topics,
    DateTime? startedAt,
    DateTime? endedAt,
  }) => TimelineEntry(
    id: id,
    kind: kind,
    title: title ?? this.title,
    body: body,
    topics: topics ?? this.topics,
    startedAt: startedAt ?? this.startedAt,
    endedAt: endedAt ?? this.endedAt,
    sessionId: sessionId,
    platform: platform,
    account: account,
    source: source,
  );
}

/// The memory column: the user timeline and the entries on it.
class UserTimelineView {
  const UserTimelineView({this.timeline, this.entries = const []});

  factory UserTimelineView.fromJson(Map<String, dynamic> json) =>
      UserTimelineView(
        timeline: json['timeline'] is Map
            ? TimelineInfo.fromJson(
                Map<String, dynamic>.from(json['timeline'] as Map),
              )
            : null,
        entries: [
          for (final entry in json['entries'] as List<dynamic>? ?? const [])
            if (entry is Map)
              TimelineEntry.fromJson(Map<String, dynamic>.from(entry)),
        ],
      );

  static const empty = UserTimelineView();

  final TimelineInfo? timeline;
  final List<TimelineEntry> entries;
}

/// A file kept in Napalm.
class Document {
  const Document({
    required this.id,
    required this.title,
    required this.createdAt,
    this.body = '',
  });

  factory Document.fromJson(Map<String, dynamic> json) => Document(
    id: json['id'] as String,
    title: json['title'] as String? ?? 'Untitled',
    body: json['body'] as String? ?? '',
    createdAt: DateTime.parse(json['created_at'] as String),
  );

  final String id;
  final String title;
  final String body;
  final DateTime createdAt;
}
