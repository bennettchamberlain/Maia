import 'dart:convert';

/// What a session close should write. [title] is null when the stored
/// title must stay (the person renamed it, or the model offered nothing).
class ClosePlan {
  const ClosePlan({
    required this.apply,
    required this.topics,
    required this.connectors,
    this.title,
    this.startedAt,
    this.endedAt,
  });

  /// False when the transcript is unchanged or the model did not answer.
  final bool apply;
  final String? title;
  final List<String> topics;
  final DateTime? startedAt;
  final DateTime? endedAt;

  /// Connector platforms named by tool calls in the transcript.
  final List<String> connectors;

  static const skipped = ClosePlan(
    apply: false,
    topics: [],
    connectors: [],
  );
}

/// Prompt for the one close-time summary.
const sessionSummaryPrompt = '''
Read the conversation. Reply with JSON only.
{"title":"","topics":[""]}
Rules:
- title is one line, second person, past tense, under 80 characters.
- Use names that appear in the conversation. Do not invent any.
- topics is 3 to 6 one-line high points that together cover the whole conversation.
- If the conversation is too small for several topics, return fewer.
''';

/// Host tools. Anything else a turn calls is a connector.
const hostTools = {
  'memory_search',
  'memory_recent',
  'memory_get',
  'remember',
  'life_graph',
  'web_search',
  'now',
  'you_search',
  'you_web_search',
};

/// Decide the close write from the transcript and the model's reply.
///
/// [modelText] null means the model was down or returned nothing: the
/// placeholder title and the current topics stay, and no span is written.
ClosePlan planSessionClose({
  required bool titleLocked,
  required int summarizedThrough,
  required int latestSeq,
  required String? modelText,
  required List<DateTime> times,
  required List<Map<String, dynamic>> toolCalls,
}) {
  if (latestSeq <= 0 || summarizedThrough >= latestSeq) {
    return ClosePlan.skipped;
  }
  final summary = modelText == null ? null : parseSessionSummary(modelText);
  if (summary == null) return ClosePlan.skipped;
  final span = spanOf(times);
  return ClosePlan(
    apply: true,
    title: titleLocked ? null : summary.title,
    topics: summary.topics,
    startedAt: span?.start,
    endedAt: span?.end,
    connectors: connectionKeys(toolCalls),
  );
}

class SessionSummary {
  const SessionSummary({required this.title, required this.topics});

  final String title;
  final List<String> topics;
}

/// Pulls a title and topics out of a model reply. Null when it is not JSON.
SessionSummary? parseSessionSummary(String raw) {
  final body = _jsonObject(raw);
  if (body == null) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final title = _clip(_string(decoded['title']), 80);
  if (title == null) return null;
  final topics = <String>[];
  final rawTopics = decoded['topics'];
  if (rawTopics is List) {
    for (final item in rawTopics) {
      final line = _clip(_string(item), 120);
      if (line == null || topics.contains(line)) continue;
      topics.add(line);
      if (topics.length == 6) break;
    }
  }
  return SessionSummary(title: title, topics: topics);
}

/// Messages at or before [messageId], in their existing order.
List<Map<String, dynamic>> messagesThrough(
  List<Map<String, dynamic>> messages,
  String messageId,
) {
  Map<String, dynamic>? target;
  for (final message in messages) {
    if (message['id'] == messageId) {
      target = message;
      break;
    }
  }
  if (target == null) return const [];
  final seq = (target['seq'] as num).toInt();
  return [
    for (final message in messages)
      if ((message['seq'] as num).toInt() <= seq) message,
  ];
}

/// One span covering every moment in [times]. Null when there are none.
({DateTime start, DateTime end})? spanOf(List<DateTime> times) {
  if (times.isEmpty) return null;
  var start = times.first;
  var end = times.first;
  for (final time in times.skip(1)) {
    if (time.isBefore(start)) start = time;
    if (time.isAfter(end)) end = time;
  }
  return (start: start, end: end);
}

/// Platforms a transcript's tool calls named, aside from host tools.
List<String> connectionKeys(List<Map<String, dynamic>> calls) {
  final keys = <String>[];
  for (final call in calls) {
    final named = _platformOf(call);
    if (named == null || keys.contains(named)) continue;
    keys.add(named);
  }
  return keys;
}

String? _platformOf(Map<String, dynamic> call) {
  final arguments = call['arguments'];
  if (arguments is String && arguments.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(arguments);
      if (decoded is Map && decoded['platform'] is String) {
        final platform = (decoded['platform'] as String).trim();
        if (platform.isNotEmpty) return platform;
      }
    } on FormatException {
      // The arguments were not JSON. The tool name still counts.
    }
  }
  final name = (call['name'] as String?)?.trim() ?? '';
  if (name.isEmpty || hostTools.contains(name)) return null;
  return name;
}

/// How a memory source lands on a timeline. Null is not a connector.
class ConnectorSpec {
  const ConnectorSpec({
    required this.kind,
    required this.platform,
    required this.account,
    required this.source,
  });

  /// `mail`, `calendar`, or `connector`.
  final String kind;
  final String platform;
  final String account;
  final String source;

  String get timelineKey => 'connection:$platform:$account';

  String get timelineName {
    final label = switch (platform) {
      'gmail' => 'Gmail',
      'google-calendar' => 'Calendar',
      'github' => 'GitHub',
      _ => platform,
    };
    if (account.isEmpty || account == platform) return label;
    return '$label · $account';
  }
}

/// `one:gmail` is mail, `one:google-calendar` is calendar, other `one:`
/// sources are a generic connector. Anything else is not a timeline event.
ConnectorSpec? connectorSpec(String source, {String? account}) {
  if (!source.startsWith('one:')) return null;
  final platform = source.substring(4).trim();
  if (platform.isEmpty) return null;
  final kind = switch (platform) {
    'gmail' => 'mail',
    'google-calendar' => 'calendar',
    _ => 'connector',
  };
  final who = (account ?? '').trim();
  return ConnectorSpec(
    kind: kind,
    platform: platform,
    account: who.isEmpty ? platform : who,
    source: source,
  );
}

/// Appends [passage] and a one-line [citation] to a document body.
String appendPassage({
  required String body,
  required String passage,
  required String citation,
}) {
  final block = '${passage.trim()}\n\n$citation';
  final existing = body.trimRight();
  if (existing.isEmpty) return block;
  return '$existing\n\n$block';
}

/// Where a saved passage came from.
String fileCitation({
  String? sessionId,
  String? messageId,
  required DateTime at,
}) {
  final when = at.toUtc().toIso8601String();
  if (sessionId == null || sessionId.isEmpty) return 'Saved $when.';
  final message = messageId == null || messageId.isEmpty
      ? ''
      : ' message $messageId';
  return 'From chat $sessionId$message at $when.';
}

/// First line of a passage, clipped, for a new file's title.
String titleFromPassage(String content) {
  final oneLine = content.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (oneLine.isEmpty) return 'Untitled';
  return oneLine.length <= 60 ? oneLine : '${oneLine.substring(0, 57)}…';
}

String? _string(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _clip(String? value, int max) {
  if (value == null) return null;
  return value.length <= max ? value : value.substring(0, max);
}

String? _jsonObject(String raw) {
  final start = raw.indexOf('{');
  final end = raw.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  return raw.substring(start, end + 1);
}
