import 'dart:convert';

import 'package:gel/gel.dart' as gel;

/// The model printed a tool call instead of using the native interface.
const nativeToolCorrection =
    'That tool call was printed as text. Issue it again through the '
    'native tool interface. Do not print the call.';

/// Result for a tool that had not started when the person spoke again.
const skippedToolResult = 'Skipped to process an incoming message.';

/// Result for a tool the model asked for beside the one this step runs.
const heldStepResult = 'Not used.';

/// Model rounds one reply may spend. Each round is one next step.
/// Eight covers a search, a follow-up, and an answer without letting
/// one turn grow until the context cannot hold it.
const chatStepBudget = 8;

/// Names from an OpenAI `tools` array, in the order they were offered.
List<String> toolNames(List<Map<String, dynamic>> definitions) {
  final names = <String>[];
  for (final tool in definitions) {
    final fn = tool['function'];
    if (fn is Map && fn['name'] is String) names.add(fn['name'] as String);
  }
  return names;
}

/// Told to the model after a tool returns. It is not a message from
/// the person, and it must not become the reply.
const answerCue =
    'Answer the person\'s latest message completely, in your own words. '
    'Earlier messages are context, not a task to continue. '
    'The tool result is already on screen. Do not repeat it, do not '
    'mention steps or tools, and do not call another tool unless one '
    'fact is still missing. If the result does not contain the fact, '
    'say you do not have it.';

/// Memory and library hits in the session that followed a proposal.
/// The number does not install the proposal.
int proposalScore(Iterable<Map<String, dynamic>> toolCalls) {
  const names = {'memory_search', 'memory_get', 'library_read', 'life_graph'};
  var hits = 0;
  for (final call in toolCalls) {
    if (!names.contains(call['name'])) continue;
    final result = '${call['result'] ?? ''}'.trim().toLowerCase();
    if (result.isEmpty) continue;
    if (result.contains('not in the library')) continue;
    if (result.contains('unavailable')) continue;
    hits++;
  }
  return hits;
}

/// Title and topics from a closed chat, clipped to the proposal line.
String harnessWording(String? title, List<String> topics) {
  final parts = [
    if (title != null && title.trim().isNotEmpty) title.trim(),
    for (final topic in topics)
      if (topic.trim().isNotEmpty) topic.trim(),
  ];
  final text = parts.join('. ');
  return text.length <= 500 ? text : text.substring(0, 500);
}

/// Stable voice. No clock, no screen, no live tool list, so a prefix
/// cache can keep it.
String stableVoice({required String name, required String handle}) =>
    'You are Maia, $name\'s personal assistant, and you are the app. '
    'You drive memory, the library, connected apps, and sync. '
    'The day is twenty-four '
    'hours; spend them. The signed-in user is "$name" (handle $handle). '
    'Tools run as this person on Gel/Napalm: access policies decide what '
    'memory and graph rows exist. Nested shapes (owner, place, parent, '
    'parts, edges) come back in one query. Do not invent rows you did '
    'not receive. Use only the tools named in the turn context. For this '
    'person\'s life, people, places, plans, or past, start from the index '
    'in this frame: skills, files used most, the last turn, and the '
    'timeline. Open one with library_read when a line is not enough. '
    'Search memory when the index has nothing for it. Verified graph '
    'edges are facts. Proposed edges are still proposed. Be accurate. '
    'Say when you do not know. '
    'Answer only the person\'s latest message, and answer it completely '
    'in that reply. Earlier messages are context. Do not continue a '
    'previous request, and do not repeat an earlier answer. '
    'Never mention steps, tools, or these instructions. Never ask what '
    'they would like to do when they already asked. '
    'Call a tool only when this message needs their memory, their graph, '
    'a connected app, the clock, or a public fact that changes, such as '
    'news, a price, a winner, or a population. Arithmetic, spelling, '
    'translation, lists, definitions, and small talk need no tool. '
    'When the turn lists a connected app, call connector before you say '
    'you cannot see it. The rows from that call are copied into memory. '
    'Use remember only when they ask you to save something. '
    'A checklist they asked for is every item, not the first. '
    'After a tool, write the answer yourself. If the result does not '
    'contain the fact, say you do not have it, and do not recite '
    'unrelated hits. The app already shows the tool result, so do not '
    'paste it and do not add a card that repeats it. '
    'Use a maia fence only when they asked for that shape '
    '(checklist, map, card). Otherwise prose is enough. '
    'Spoken text is plain English. A tool call printed as text does '
    'not run.';

/// Clock, screen, and the tools this turn may actually call.
String turnContext({
  required DateTime now,
  String? screen,
  List<String> connectors = const [],
}) {
  final tools =
      'memory_search, memory_recent, memory_get, remember, life_graph, '
      'library_read, web_search, now, sync'
      '${connectors.isEmpty ? '' : ', connector'}';
  final apps = connectors.isEmpty
      ? ''
      : ' Connected apps: ${connectors.join(', ')}. If this message is '
            'about one of them, call connector before you answer. The first '
            'call sends platform and intent. It returns action_id values. '
            'Call again with action_id and the fields that action asks for. '
            'That second call copies the rows into memory. The connection '
            'already has the account, so do not ask for a username or a '
            'login. Answer from the copy. Do not say you cannot see an app '
            'on this list.';
  const surfaces =
      ' The app is chat, memory, connectors, and jobs. You drive them. '
      'memory_search, memory_recent, memory_get, and remember are memory. '
      'library_read opens a skill, file, or turn. life_graph is goals and '
      'people. connector reads one page of a connected app now. sync '
      'queues the full pull and reports whether jobs are running or still '
      'queued. A queued job has not copied anything. Connecting an account '
      'stays on the Connectors screen. Call sync when they ask to sync or '
      'have just started one.';
  final shown = (screen ?? '').trim();
  final onScreen = shown.isEmpty
      ? ''
      : ' On screen right now, only these parts are visible. Speech may '
            'refer to these titles and must not invent others:\n$shown';
  return 'Current local time: ${now.toIso8601String()} '
      '(${now.timeZoneName}). Tools: $tools.$surfaces$apps$onScreen';
}

/// Stable voice, then the live turn, then folded memory and intents.
String chatPrompt({
  required String name,
  required String handle,
  required DateTime now,
  String? screen,
  List<String> connectors = const [],
  String extra = '',
}) {
  final folded = extra.trim();
  return [
    stableVoice(name: name, handle: handle),
    turnContext(now: now, screen: screen, connectors: connectors),
    if (folded.isNotEmpty) folded,
  ].join('\n\n');
}

/// True when the reply is a tool call written as text. Prose around a
/// mention of a tool does not count.
bool looksLikePrintedToolCall(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return false;
  if (RegExp(r'</?tool_call>', caseSensitive: false).hasMatch(trimmed)) {
    return true;
  }
  final call = RegExp(
    r'"name"\s*:\s*"[A-Za-z0-9_]+"[\s\S]{0,800}"(?:arguments|parameters)"\s*:',
  );
  if (!call.hasMatch(trimmed)) return false;
  final prose = trimmed
      .replaceAll(RegExp(r'```[\s\S]*?```'), ' ')
      .replaceAll(RegExp(r'\{[\s\S]*\}'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return prose.length < 40;
}

/// One in-flight turn. A later message waits here until the running
/// tool batch reaches a boundary.
class TurnLane {
  String? _pending;

  /// Fires when a stored message should show up on the open stream.
  void Function(Map<String, dynamic> message)? onStored;

  void offer(String text, {Map<String, dynamic>? stored}) {
    final next = text.trim();
    if (next.isEmpty) return;
    _pending = _pending == null ? next : '$_pending\n$next';
    if (stored != null) onStored?.call(stored);
  }

  String? take() {
    final pending = _pending;
    _pending = null;
    return pending;
  }
}

/// Sessions with a turn that can still accept a steer.
class TurnLanes {
  final _open = <String, TurnLane>{};

  TurnLane begin(String sessionId) {
    final lane = TurnLane();
    _open[sessionId] = lane;
    return lane;
  }

  TurnLane? current(String sessionId) => _open[sessionId];

  void end(String sessionId, TurnLane lane) {
    if (identical(_open[sessionId], lane)) _open.remove(sessionId);
  }
}

/// Which tools a turn may see. Memory is the second brain.
/// Work is a bounded job and does not get the life graph.
const memoryToolset = <String>{
  'memory_search',
  'memory_recent',
  'memory_get',
  'remember',
  'life_graph',
  'web_search',
  'now',
  'connector',
  'sync',
  'intent_create',
  'library_read',
};

const workToolset = <String>{
  'web_search',
  'now',
  'connector',
  'sync',
  'remember',
  'session_search',
  'skill_propose',
  'library_read',
};

/// A line is promotable when it has been recalled often enough,
/// from more than one distinct search. Both gates are fixed.
bool promotionGate({required int recalls, required int queries}) =>
    recalls >= 3 && queries >= 2;

/// Keep the live tail. Older turns fold into [compaction].
({List<Map<String, dynamic>> kept, List<Map<String, dynamic>> older})
splitForCompaction(List<Map<String, dynamic>> messages, {int keep = 16}) {
  final talk = [
    for (final m in messages)
      if (m['role'] == 'user' || m['role'] == 'assistant') m,
  ];
  if (talk.length <= keep + 8) {
    return (kept: talk, older: const <Map<String, dynamic>>[]);
  }
  return (
    kept: talk.sublist(talk.length - keep),
    older: talk.sublist(0, talk.length - keep),
  );
}

/// One line per older user turn. Used when no model is free to summarize.
String extractiveCompaction(List<Map<String, dynamic>> older) {
  final lines = <String>[];
  for (final m in older) {
    if (m['role'] != 'user') continue;
    final text = '${m['content'] ?? ''}'.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) continue;
    lines.add(text.length > 180 ? text.substring(0, 180) : text);
    if (lines.length == 12) break;
  }
  if (lines.isEmpty) return '';
  return 'Earlier in this chat, the user asked: ${lines.join(' / ')}';
}

/// Intents whose phrase appears in [text]. Matching is literal.
List<Map<String, dynamic>> matchingIntents(
  List<Map<String, dynamic>> intents,
  String text,
) {
  final hay = text.toLowerCase();
  return [
    for (final intent in intents)
      if ('${intent['phrase'] ?? ''}'.trim().isNotEmpty &&
          hay.contains('${intent['phrase']}'.toLowerCase()))
        intent,
  ];
}

bool toolsetAllows(String toolset, String name) {
  final allow = toolset == 'work' ? workToolset : memoryToolset;
  return allow.contains(name);
}

/// Lines added to the system frame. Review notes are not included.
String harnessContext({
  String? compaction,
  List<Map<String, dynamic>> intents = const [],
  List<Map<String, dynamic>> skills = const [],
  String? library,
}) {
  final parts = <String>[];
  final folded = (compaction ?? '').trim();
  if (folded.isNotEmpty) {
    parts.add('Compacted earlier turns:\n$folded');
  }
  if (intents.isNotEmpty) {
    final lines = [
      for (final intent in intents.take(4))
        '- When "${intent['phrase']}" comes up: ${intent['instruction']}',
    ];
    parts.add('Standing intents:\n${lines.join('\n')}');
  }
  final index = (library ?? '').trim();
  if (index.isNotEmpty) {
    parts.add(index);
  } else {
    final active = [
      for (final skill in skills)
        if (skill['status'] == 'active') skill,
    ];
    if (active.isNotEmpty) {
      final lines = [
        for (final skill in active.take(6))
          '- ${skill['name']}: ${_clip('${skill['body']}', 400)}',
      ];
      parts.add('Confirmed procedures:\n${lines.join('\n')}');
    }
  }
  return parts.join('\n\n');
}

String _clip(String text, int max) =>
    text.length <= max ? text : text.substring(0, max);

/// Propose curated rows for episodic memories that cleared the gate.
/// Nothing is activated. A review note records the sweep and is not recalled.
Future<Map<String, dynamic>> consolidate(gel.Client c) async {
  final raw = jsonDecode(
    await c.queryJSON(r'''
      select MemoryItem {
        id, title, body, recall_count, query_count
      }
      filter .tier = MemoryTier.episodic
        and .status = RecordStatus.active
        and .recall_count >= 3
        and .query_count >= 2
        and not exists .promoted_to
      order by .recall_count desc
      limit 8
      '''),
  ) as List<dynamic>;
  final proposed = <String>[];
  for (final row in raw.cast<Map<String, dynamic>>()) {
    final title = '${row['title'] ?? 'note'}';
    final created = jsonDecode(
      await c.querySingleJSON(
        r'''
        with item := (insert MemoryItem {
          owner := assert_exists(global current_person),
          kind := 'note',
          title := <str>$title,
          body := <optional str>$body,
          occurred_at := datetime_of_statement(),
          source := 'consolidate',
          source_id := <str>$source_id,
          tier := MemoryTier.curated,
          origin := MemoryOrigin.agent,
          status := RecordStatus.proposed,
        })
        select item { id }
        ''',
        {
          'title': title,
          'body': row['body'],
          'source_id': 'promote:${row['id']}',
        },
      ),
    ) as Map<String, dynamic>;
    await c.execute(
      r'''
      update MemoryItem
      filter .id = <uuid>$id
      set { promoted_to := (select MemoryItem filter .id = <uuid>$promoted) }
      ''',
      {'id': row['id'], 'promoted': created['id']},
    );
    proposed.add(created['id'] as String);
  }
  await c.execute(
    r'''
    insert MemoryItem {
      owner := assert_exists(global current_person),
      kind := 'note',
      title := 'Consolidation sweep',
      body := <str>$body,
      occurred_at := datetime_of_statement(),
      source := 'consolidate',
      source_id := <str>$source_id,
      tier := MemoryTier.review,
      origin := MemoryOrigin.system,
      status := RecordStatus.active,
    }
    ''',
    {
      'body': proposed.isEmpty
          ? 'Sweep found nothing ready to promote.'
          : 'Proposed ${proposed.length} curated rows. None are active yet.',
      'source_id': 'sweep:${DateTime.now().toUtc().toIso8601String()}',
    },
  );
  return {'proposed': proposed.length};
}

Future<List<Map<String, dynamic>>> activeIntents(gel.Client c) async {
  final raw = jsonDecode(
    await c.queryJSON(r'''
      select StandingIntent { phrase, instruction }
      filter .status = RecordStatus.active
      limit 32
      '''),
  ) as List<dynamic>;
  return raw.cast<Map<String, dynamic>>();
}

Future<List<Map<String, dynamic>>> activeSkills(gel.Client c) async {
  final raw = jsonDecode(
    await c.queryJSON(r'''
      select Skill { id, name, body, status }
      filter .status = RecordStatus.active
      order by .created_at desc
      limit 6
      '''),
  ) as List<dynamic>;
  return raw.cast<Map<String, dynamic>>();
}

Future<String> createIntent(
  gel.Client c, {
  required String phrase,
  required String instruction,
}) async {
  final row = jsonDecode(
    await c.querySingleJSON(
      r'''
      select (insert StandingIntent {
        owner := assert_exists(global current_person),
        phrase := <str>$phrase,
        instruction := <str>$instruction,
        status := RecordStatus.active,
      }) { id }
      ''',
      {'phrase': phrase, 'instruction': instruction},
    ),
  ) as Map<String, dynamic>;
  return row['id'] as String;
}

Future<String> proposeSkill(
  gel.Client c, {
  required String name,
  required String body,
  String? messageId,
}) async {
  final row = jsonDecode(
    await c.querySingleJSON(
      r'''
      select (insert Skill {
        owner := assert_exists(global current_person),
        name := <str>$name,
        body := <str>$body,
        status := RecordStatus.proposed,
        source := (
          select ChatMessage
          filter .id = <optional uuid>$message
          limit 1
        ),
      }) { id }
      ''',
      {'name': name, 'body': body, 'message': messageId},
    ),
  ) as Map<String, dynamic>;
  return row['id'] as String;
}

/// Stores the closed chat's line. [score] stays empty until a later session.
Future<String> recordHarnessProposal(
  gel.Client c, {
  required String sessionId,
  required String wording,
}) async {
  final row = jsonDecode(
    await c.querySingleJSON(
      r'''
      select (insert HarnessProposal {
        owner := assert_exists(global current_person),
        wording := <str>$wording,
        session := assert_single((
          select ChatSession filter .id = <uuid>$session
        )),
        status := RecordStatus.proposed,
      }) { id }
      ''',
      {'wording': wording, 'session': sessionId},
    ),
  ) as Map<String, dynamic>;
  return row['id'] as String;
}

/// Writes [score] on the newest unscored proposal from another session.
Future<void> scorePreviousProposal(
  gel.Client c, {
  required String sessionId,
  required int score,
}) async {
  await c.execute(
    r'''
    with prior := (
      select HarnessProposal
      filter .status = RecordStatus.proposed
        and not exists .score
        and .session.id != <uuid>$session
      order by .created_at desc
      limit 1
    )
    update prior set { score := <int32>$score }
    ''',
    {'session': sessionId, 'score': score},
  );
}

/// Marks a proposal kept. The live prompt is unchanged.
Future<bool> confirmHarnessProposal(gel.Client c, String id) async {
  final row = await c.querySingleJSON(
    r'''
    select (update HarnessProposal
      filter .id = <uuid>$id and .status = RecordStatus.proposed
      set { status := RecordStatus.active }
    ) { id }
    ''',
    {'id': id},
  );
  return row != 'null';
}

Future<bool> confirmSkill(gel.Client c, String id) async {
  final row = await c.querySingleJSON(
    r'''
    select (update Skill
      filter .id = <uuid>$id and .status = RecordStatus.proposed
      set { status := RecordStatus.active }
    ) { id }
    ''',
    {'id': id},
  );
  return row != 'null';
}

Future<bool> promoteMemory(gel.Client c, String id) async {
  final row = await c.querySingleJSON(
    r'''
    select (update MemoryItem
      filter .id = <uuid>$id and .status = RecordStatus.proposed
      set {
        status := RecordStatus.active,
        tier := MemoryTier.curated,
        origin := MemoryOrigin.owner,
      }
    ) { id }
    ''',
    {'id': id},
  );
  return row != 'null';
}

Future<void> noteRecall(gel.Client c, List<String> ids) async {
  if (ids.isEmpty) return;
  await c.execute(
    r'''
    update MemoryItem
    filter .id in array_unpack(<array<uuid>>$ids)
    set {
      recall_count := .recall_count + 1,
      query_count := .query_count + 1,
    }
    ''',
    {'ids': ids},
  );
}

Future<List<Map<String, dynamic>>> searchSessions(
  gel.Client c,
  String query, {
  int limit = 8,
}) async {
  final raw = jsonDecode(
    await c.queryJSON(
      r'''
      with pattern := '%' ++ str_replace(
        str_replace(<str>$q, '%', r'\%'), '_', r'\_') ++ '%'
      select ChatMessage {
        id, role, content, seq,
        session: { id, title }
      }
      filter (.content ilike pattern) and .role = 'user'
      order by .created_at desc
      limit <int64>$limit
      ''',
      {'q': query, 'limit': limit},
    ),
  ) as List<dynamic>;
  return raw.cast<Map<String, dynamic>>();
}

Future<Map<String, dynamic>?> sessionCompaction(
  gel.Client c,
  String sessionId,
) async {
  final row = await c.querySingleJSON(
    r'''
    select ChatSession { compaction, compacted_through_seq }
    filter .id = <uuid>$id
    ''',
    {'id': sessionId},
  );
  if (row == 'null') return null;
  return jsonDecode(row) as Map<String, dynamic>;
}

Future<String> createWork(gel.Client c, String goal) async {
  final row = jsonDecode(
    await c.querySingleJSON(
      r'''
      select (insert WorkRun {
        owner := assert_exists(global current_person),
        goal := <str>$goal,
        toolset := 'work',
        state := JobState.created,
      }) { id }
      ''',
      {'goal': goal},
    ),
  ) as Map<String, dynamic>;
  return row['id'] as String;
}

Future<void> finishWork(
  gel.Client c, {
  required String id,
  required String result,
  required bool ok,
}) async {
  await c.execute(
    r'''
    update WorkRun
    filter .id = <uuid>$id
    set {
      result := <str>$result,
      state := <JobState><str>$state,
    }
    ''',
    {'id': id, 'result': result, 'state': ok ? 'completed' : 'failed'},
  );
}

/// Interests the night should chase. Standing intents come first,
/// then curated memory, then active goals. Three is the cap.
List<String> researchTopics({
  List<Map<String, dynamic>> intents = const [],
  List<Map<String, dynamic>> curated = const [],
  List<Map<String, dynamic>> goals = const [],
  int limit = 3,
}) {
  final out = <String>[];
  final seen = <String>{};
  void add(Object? raw) {
    final text = '$raw'.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.length < 3 || text == 'null') return;
    if (!seen.add(text.toLowerCase())) return;
    out.add(text);
  }

  for (final row in intents) {
    add(row['phrase']);
  }
  for (final row in curated) {
    add(row['title']);
  }
  for (final row in goals) {
    add(row['name']);
  }
  return out.take(limit).toList();
}

/// A note the person can read later. Not fed back into chat.
String researchBrief(String topic, List<Map<String, dynamic>> hits) {
  if (hits.isEmpty) return 'Nothing current turned up for $topic.';
  final lines = <String>[];
  for (final hit in hits.take(3)) {
    final title = '${hit['title'] ?? ''}'.trim();
    final url = '${hit['url'] ?? ''}'.trim();
    var snippet = '${hit['snippet'] ?? ''}'
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (snippet.length > 220) snippet = snippet.substring(0, 220);
    lines.add(
      [
        if (title.isNotEmpty) title,
        if (snippet.isNotEmpty) snippet,
        if (url.isNotEmpty) url,
      ].join('\n'),
    );
  }
  if (lines.isEmpty) return 'Nothing current turned up for $topic.';
  return lines.join('\n\n');
}

String dreamDay(DateTime now) {
  final local = now.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '${local.year}-$month-$day';
}

/// True during the one nightly hour, and only if this process has not
/// already sent today's dream.
bool dreamDue(DateTime now, {String? lastDay, int hour = 3}) {
  if (now.hour != hour) return false;
  return lastDay != dreamDay(now);
}

/// The nightly pass for one person. Promotes what cleared the gate,
/// then caches web notes on their interests. Review rows stay out of search.
Future<Map<String, dynamic>> dream(
  gel.Client c, {
  Future<List<Map<String, dynamic>>> Function(String topic)? search,
  DateTime? now,
}) async {
  final promoted = await consolidate(c);
  final topics = researchTopics(
    intents: await _rows(c, r'''
      select StandingIntent { phrase }
      filter .status = RecordStatus.active
      limit 8
      '''),
    curated: await _rows(c, r'''
      select MemoryItem { title }
      filter .tier = MemoryTier.curated
        and .status = RecordStatus.active
      order by .recall_count desc
      limit 8
      '''),
    goals: await _rows(c, r'''
      select Goal { name }
      filter .status = PursuitStatus.active
      limit 8
      '''),
  );
  final day = dreamDay(now ?? DateTime.now());
  final cached = <String>[];
  if (search != null) {
    for (final topic in topics) {
      final hits = await search(topic);
      await _cacheResearch(c, topic: topic, hits: hits, day: day);
      cached.add(topic);
    }
  }
  if (cached.isNotEmpty) {
    await c.execute(
      r'''
      insert WorkRun {
        owner := assert_exists(global current_person),
        goal := <str>$goal,
        toolset := 'work',
        state := JobState.completed,
        result := <str>$result,
      }
      ''',
      {
        'goal': 'Night research for $day',
        'result': 'Cached research on: ${cached.join(', ')}.',
      },
    );
  }
  return {
    'proposed': promoted['proposed'],
    'researched': cached.length,
    'topics': cached,
  };
}

Future<List<Map<String, dynamic>>> recentDreams(
  gel.Client c, {
  int limit = 30,
}) => _rows(
  c,
  r'''
    select MemoryItem { id, title, body, occurred_at, source_id }
    filter .tier = MemoryTier.review
      and .source = 'dream'
      and .status = RecordStatus.active
    order by .occurred_at desc
    limit <int64>$limit
    ''',
  {'limit': limit},
);

Future<List<Map<String, dynamic>>> _rows(
  gel.Client c,
  String query, [
  Map<String, dynamic>? args,
]) async {
  final raw = jsonDecode(
    args == null ? await c.queryJSON(query) : await c.queryJSON(query, args),
  ) as List<dynamic>;
  return raw.cast<Map<String, dynamic>>();
}

Future<void> _cacheResearch(
  gel.Client c, {
  required String topic,
  required List<Map<String, dynamic>> hits,
  required String day,
}) async {
  final slug = topic
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final clipped = slug.length > 40 ? slug.substring(0, 40) : slug;
  await c.execute(
    r'''
    insert MemoryItem {
      owner := assert_exists(global current_person),
      kind := 'note',
      title := <str>$title,
      body := <str>$body,
      occurred_at := datetime_of_statement(),
      source := 'dream',
      source_id := <str>$source_id,
      tier := MemoryTier.review,
      origin := MemoryOrigin.web,
      status := RecordStatus.active,
    }
    unless conflict on ((.owner, .source, .source_id))
    ''',
    {
      'title': topic,
      'body': researchBrief(topic, hits),
      'source_id': 'research:$day:${clipped.isEmpty ? 'topic' : clipped}',
    },
  );
}

Future<void> storeCompaction(
  gel.Client c, {
  required String sessionId,
  required String text,
  required int throughSeq,
}) async {
  await c.execute(
    r'''
    update ChatSession
    filter .id = <uuid>$id
    set {
      compaction := <str>$text,
      compacted_through_seq := <int32>$seq,
    }
    ''',
    {'id': sessionId, 'text': text, 'seq': throughSeq},
  );
}
