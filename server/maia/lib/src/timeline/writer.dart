import 'dart:convert';

import 'package:gel/gel.dart' as gel;
import 'package:maia_api/src/timeline/summary.dart';

/// Writes the timeline types. The user timeline is the memory column.
/// Entity, person, and connection timelines are the parallel streams.
class TimelineWriter {
  const TimelineWriter._();

  static Future<String> ensureUser(gel.Client c) => _ensure(
    c,
    lookup: r'''
      select (select UserTimeline filter .key = 'user' limit 1) { id }
    ''',
    insert: r'''
      select (insert UserTimeline {
        owner := assert_exists(global current_person),
        key := 'user',
        name := 'Memory',
      }) { id }
    ''',
  );

  static Future<String> ensureEntity(
    gel.Client c, {
    required String thingId,
    required String name,
  }) => _ensure(
    c,
    lookup: r'''
      select (select EntityTimeline filter .key = <str>$key limit 1) { id }
    ''',
    insert: r'''
      select (insert EntityTimeline {
        owner := assert_exists(global current_person),
        key := <str>$key,
        name := <str>$name,
        subject := assert_single((select Thing filter .id = <uuid>$thing)),
      }) { id }
    ''',
    args: {'key': 'entity:$thingId', 'name': name, 'thing': thingId},
  );

  static Future<String> ensurePerson(
    gel.Client c, {
    required String personId,
    required String name,
  }) => _ensure(
    c,
    lookup: r'''
      select (select PersonTimeline filter .key = <str>$key limit 1) { id }
    ''',
    insert: r'''
      select (insert PersonTimeline {
        owner := assert_exists(global current_person),
        key := <str>$key,
        name := <str>$name,
        subject := assert_single((select Person filter .id = <uuid>$person)),
      }) { id }
    ''',
    args: {'key': 'person:$personId', 'name': name, 'person': personId},
  );

  static Future<String> ensureConnection(
    gel.Client c,
    ConnectorSpec spec,
  ) => _ensure(
    c,
    lookup: r'''
      select (
        select ConnectionTimeline filter .key = <str>$key limit 1
      ) { id }
    ''',
    insert: r'''
      select (insert ConnectionTimeline {
        owner := assert_exists(global current_person),
        key := <str>$key,
        name := <str>$name,
        platform := <str>$platform,
        account := <str>$account,
      }) { id }
    ''',
    args: {
      'key': spec.timelineKey,
      'name': spec.timelineName,
      'platform': spec.platform,
      'account': spec.account,
    },
  );

  /// Puts a chat on the user timeline. Topics are left as they are.
  static Future<void> touchSession(gel.Client c, String sessionId) async {
    final row = await _sessionTimes(c, sessionId);
    if (row == null) return;
    final timeline = await ensureUser(c);
    await _sessionSpan(
      c,
      timelineId: timeline,
      sessionId: sessionId,
      title: row['title'] as String?,
      topics: _strings(row['topics']),
      started: _time(row['started'])!,
      ended: _time(row['ended'])!,
      replaceTopics: false,
    );
  }

  /// Rewrites the user span, and copies it onto each connector timeline.
  static Future<void> applySession(
    gel.Client c, {
    required String sessionId,
    required String? title,
    required List<String> topics,
    required DateTime started,
    required DateTime ended,
    required List<String> connectors,
  }) async {
    final user = await ensureUser(c);
    await _sessionSpan(
      c,
      timelineId: user,
      sessionId: sessionId,
      title: title,
      topics: topics,
      started: started,
      ended: ended,
      replaceTopics: true,
    );
    for (final platform in connectors) {
      final spec = ConnectorSpec(
        kind: 'connector',
        platform: platform,
        account: platform,
        source: 'one:$platform',
      );
      final timeline = await ensureConnection(c, spec);
      await _sessionSpan(
        c,
        timelineId: timeline,
        sessionId: sessionId,
        title: title,
        topics: topics,
        started: started,
        ended: ended,
        replaceTopics: true,
      );
    }
  }

  /// One card per connector row, on the user timeline and that account's.
  static Future<void> recordConnector(
    gel.Client c, {
    required String source,
    required String sourceId,
    required String? title,
    required String? body,
    required DateTime at,
    String? account,
  }) async {
    final spec = connectorSpec(source, account: account);
    if (spec == null || sourceId.isEmpty) return;
    final user = await ensureUser(c);
    final connection = await ensureConnection(c, spec);
    for (final timeline in [user, connection]) {
      await _connectorSpan(
        c,
        timelineId: timeline,
        spec: spec,
        title: title,
        body: body,
        sourceId: sourceId,
        at: at,
      );
    }
  }

  static Future<void> recordFile(
    gel.Client c, {
    required String documentId,
    required String title,
    required String body,
    required DateTime started,
    required DateTime ended,
  }) async {
    final timeline = await ensureUser(c);
    await _id(
      c,
      r'''
      select (
        insert FileSpan {
          owner := assert_exists(global current_person),
          timeline := assert_single((select Timeline filter .id = <uuid>$timeline)),
          document := assert_single((select Document filter .id = <uuid>$document)),
          kind := 'file',
          title := <str>$title,
          body := <str>$body,
          source := 'file',
          source_id := <str>$document,
          started_at := <datetime>$started,
          ended_at := <datetime>$ended,
        }
        unless conflict on ((.timeline, .document))
        else (
          update FileSpan set {
            title := <str>$title,
            body := <str>$body,
            ended_at := <datetime>$ended,
            updated_at := datetime_of_statement(),
          }
        )
      ) { id }
      ''',
      {
        'timeline': timeline,
        'document': documentId,
        'title': title,
        'body': body,
        'started': started.toUtc(),
        'ended': ended.toUtc(),
      },
    );
  }

  /// Opens an entity timeline and records that a memory is about that thing.
  static Future<void> fanOntology(
    gel.Client c, {
    required List<String> thingIds,
    required String memoryId,
    required String body,
    required DateTime at,
  }) async {
    if (thingIds.isEmpty) return;
    final raw = jsonDecode(
      await c.queryJSON(
        r'''
        select Thing { id, name }
        filter .id in array_unpack(<array<uuid>>$ids)
        ''',
        {'ids': thingIds},
      ),
    );
    if (raw is! List) return;
    final snippet = body.length > 280 ? '${body.substring(0, 277)}…' : body;
    for (final row in raw.cast<Map<String, dynamic>>()) {
      final thingId = row['id'] as String?;
      if (thingId == null) continue;
      final name = (row['name'] as String?)?.trim();
      final label = name == null || name.isEmpty ? 'Untitled' : name;
      final timeline = await ensureEntity(c, thingId: thingId, name: label);
      await _id(
        c,
        r'''
        select (
          insert OntologySpan {
            owner := assert_exists(global current_person),
            timeline := assert_single((
              select Timeline filter .id = <uuid>$timeline
            )),
            subject := assert_single((select Thing filter .id = <uuid>$thing)),
            memory := (select MemoryItem filter .id = <uuid>$memory limit 1),
            kind := 'ontology',
            title := <str>$title,
            body := <str>$body,
            source := 'memory',
            source_id := <str>$memory,
            started_at := <datetime>$at,
            ended_at := <datetime>$at,
          }
          unless conflict on ((.timeline, .source, .source_id))
          else (
            update OntologySpan set {
              title := <str>$title,
              body := <str>$body,
              ended_at := <datetime>$at,
              updated_at := datetime_of_statement(),
            }
          )
        ) { id }
        ''',
        {
          'timeline': timeline,
          'thing': thingId,
          'memory': memoryId,
          'title': label,
          'body': snippet,
          'at': at.toUtc(),
        },
      );
    }
  }

  /// Cards for chats that are not on the user timeline yet.
  static Future<void> backfillSessions(gel.Client c) async {
    final timeline = await ensureUser(c);
    final raw = jsonDecode(
      await c.queryJSON(
        r'''
        select ChatSession {
          id,
          title,
          topics,
          started := (min(.messages.created_at) ?? .created_at),
          ended := (
            max(.messages.created_at) ?? .last_message_at ?? .created_at
          ),
        }
        filter not exists (
          select SessionSpan
          filter .session.id = ChatSession.id
            and .timeline.id = <uuid>$timeline
        )
        ''',
        {'timeline': timeline},
      ),
    );
    if (raw is! List) return;
    for (final row in raw.cast<Map<String, dynamic>>()) {
      final id = row['id'] as String?;
      final started = _time(row['started']);
      final ended = _time(row['ended']);
      if (id == null || started == null || ended == null) continue;
      await _sessionSpan(
        c,
        timelineId: timeline,
        sessionId: id,
        title: row['title'] as String?,
        topics: _strings(row['topics']),
        started: started,
        ended: ended,
        replaceTopics: true,
      );
    }
  }

  static Future<void> renameSpans(
    gel.Client c, {
    required String sessionId,
    required String title,
  }) => c.execute(
    r'''
    update SessionSpan filter .session.id = <uuid>$id set {
      title := <str>$title,
      updated_at := datetime_of_statement(),
    }
    ''',
    {'id': sessionId, 'title': title},
  );

  static Future<Map<String, dynamic>?> _sessionTimes(
    gel.Client c,
    String sessionId,
  ) async {
    final raw = jsonDecode(
      await c.querySingleJSON(
        r'''
        select ChatSession {
          title,
          topics,
          started := (min(.messages.created_at) ?? .created_at),
          ended := (
            max(.messages.created_at) ?? .last_message_at ?? .created_at
          ),
        }
        filter .id = <uuid>$id
        ''',
        {'id': sessionId},
      ),
    );
    if (raw is! Map<String, dynamic>) return null;
    if (_time(raw['started']) == null || _time(raw['ended']) == null) {
      return null;
    }
    return raw;
  }

  static Future<void> _sessionSpan(
    gel.Client c, {
    required String timelineId,
    required String sessionId,
    required String? title,
    required List<String> topics,
    required DateTime started,
    required DateTime ended,
    required bool replaceTopics,
  }) {
    final topicsClause = replaceTopics
        ? 'topics := <array<str>>\$topics,'
        : '';
    return _id(
      c,
      '''
      select (
        insert SessionSpan {
          owner := assert_exists(global current_person),
          timeline := assert_single((
            select Timeline filter .id = <uuid>\$timeline
          )),
          session := assert_single((
            select ChatSession filter .id = <uuid>\$session
          )),
          kind := 'session',
          title := <optional str>\$title,
          topics := <array<str>>\$topics,
          source := 'chat',
          source_id := <str>\$source_id,
          started_at := <datetime>\$started,
          ended_at := <datetime>\$ended,
        }
        unless conflict on ((.timeline, .session))
        else (
          update SessionSpan set {
            title := <optional str>\$title,
            $topicsClause
            started_at := <datetime>\$started,
            ended_at := <datetime>\$ended,
            updated_at := datetime_of_statement(),
          }
        )
      ) { id }
      ''',
      {
        'timeline': timelineId,
        'session': sessionId,
        'source_id': sessionId,
        'title': title,
        'topics': topics,
        'started': started.toUtc(),
        'ended': ended.toUtc(),
      },
    );
  }

  static Future<void> _connectorSpan(
    gel.Client c, {
    required String timelineId,
    required ConnectorSpec spec,
    required String? title,
    required String? body,
    required String sourceId,
    required DateTime at,
  }) {
    final type = switch (spec.kind) {
      'mail' => 'MailEvent',
      'calendar' => 'CalendarEvent',
      _ => 'ConnectorEvent',
    };
    return _id(
      c,
      '''
      select (
        insert $type {
          owner := assert_exists(global current_person),
          timeline := assert_single((
            select Timeline filter .id = <uuid>\$timeline
          )),
          kind := <str>\$kind,
          title := <optional str>\$title,
          body := <optional str>\$body,
          platform := <str>\$platform,
          account := <str>\$account,
          source := <str>\$source,
          source_id := <str>\$source_id,
          started_at := <datetime>\$at,
          ended_at := <datetime>\$at,
        }
        unless conflict on ((.timeline, .source, .source_id))
        else (
          update $type set {
            title := <optional str>\$title,
            body := <optional str>\$body,
            account := <str>\$account,
            ended_at := <datetime>\$at,
            updated_at := datetime_of_statement(),
          }
        )
      ) { id }
      ''',
      {
        'timeline': timelineId,
        'kind': spec.kind,
        'title': title,
        'body': body,
        'platform': spec.platform,
        'account': spec.account,
        'source': spec.source,
        'source_id': sourceId,
        'at': at.toUtc(),
      },
    );
  }

  static Future<String> _ensure(
    gel.Client c, {
    required String lookup,
    required String insert,
    Map<String, dynamic>? args,
  }) async {
    final existing = _idOf(await c.querySingleJSON(lookup, args));
    if (existing != null) return existing;
    try {
      return await _id(c, insert, args);
    } on Object {
      return _id(c, lookup, args);
    }
  }

  static Future<String> _id(
    gel.Client c,
    String query, [
    Map<String, dynamic>? args,
  ]) async {
    final id = _idOf(await c.querySingleJSON(query, args));
    if (id == null) throw StateError('timeline row was not stored');
    return id;
  }

  static String? _idOf(String json) {
    final raw = jsonDecode(json);
    if (raw is Map && raw['id'] is String) return raw['id'] as String;
    return null;
  }

  static List<String> _strings(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is String && item.trim().isNotEmpty) item,
    ];
  }

  static DateTime? _time(Object? raw) {
    if (raw is DateTime) return raw;
    if (raw is String) return DateTime.tryParse(raw);
    return null;
  }
}
