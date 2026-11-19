import 'dart:convert';

import 'package:maie_api/src/chat/ladder.dart';

/// Told to the model after a known-problem graph has run. The checkpoint
/// is already in the thread. This is not a message from the person.
const graphAnswerCue =
    "Answer the person's latest message from the checkpoint above. "
    'The graph has finished, so do not call a tool. '
    'A call that did not return is finished. Say you do not have '
    'the fact. Do not describe the tool. Earlier notes are not '
    'the account. Do not invent it. '
    'Do not mention the graph, the checkpoint, or the tools.';

/// After a read, one more connector call may do the change they asked for.
const graphChangeCue =
    'The account page is already in the checkpoint. '
    'They asked for a change. Call connector once, with that platform '
    'and an intent that is the change: reply, send, schedule, create, '
    'or move. Then answer from whatever comes back. '
    'If that call does not return, say you do not have it. '
    'Do not describe the tool. Do not search the web.';

/// The read needed an account that is not connected.
const graphMissingCue =
    'A needed account is not connected. Call connector once more only if '
    'another connected app could hold the same fact. If none can, tell them '
    'which connector to add on the Connectors screen. Do not invent the '
    'page. Do not describe the tool.';

/// The tool result says the account was never granted.
bool missingAccount(String result) {
  final text = result.toLowerCase();
  return text.contains('not connected') || text.contains('no grant');
}

/// One node. [after] are the node ids that must finish first.
/// Nodes that share no edge are one superstep and may run together.
class GraphNode {
  const new({
    required this.id,
    required this.tool,
    required this.label,
    required this.able,
    required this.after,
    required this.args,
    this.when,
  });

  final String id;
  final String tool;
  final String label;
  final String able;
  final List<String> after;
  final Map<String, dynamic> Function(GraphState state) args;
  final bool Function(GraphState state)? when;
}

class GraphState {
  const new(this.ask, this.results);

  final String ask;
  final Map<String, String> results;
}

class GraphCall {
  const new({
    required this.id,
    required this.tool,
    required this.label,
    required this.able,
    required this.arguments,
    required this.result,
    required this.failed,
  });

  final String id;
  final String tool;
  final String label;
  final String able;
  final String arguments;
  final String result;
  final bool failed;
}

class GraphCheckpoint {
  const new(this.playbookId, this.waves);

  final String playbookId;
  final List<List<GraphCall>> waves;

  List<GraphCall> get calls => [for (final wave in waves) ...wave];

  /// A required account is missing, so one other app may still answer.
  bool get needsAnotherWay => calls.any(
    (call) => call.tool == 'connector' && missingAccount(call.result),
  );

  /// What the model reads. A failed call stays failed.
  String get note {
    final bits = <String>[
      'Checkpoint for $playbookId. This graph is finished.',
    ];
    for (final call in calls) {
      final notes =
          call.tool == 'memory_search' && memoryIsChatter(call.result);
      bits.add(
        call.failed
            ? missingAccount(call.result)
                  ? '${call.label} is not connected. Tell them to connect '
                        'it on the Connectors screen. One other connected '
                        'app is allowed if it could hold the same fact. '
                        'Do not invent the page.'
                  : '${call.tool} on ${call.label} did not return. '
                        'You do not have that fact. Do not describe the '
                        'tool and do not call it again.'
            : notes
            ? 'memory_search returned earlier notes, not the live account. '
                  'Do not treat them as the login or the mailbox.'
            : '${call.tool} on ${call.label} returned. '
                  '${nextStep(call.label)} '
                  'Use that result. Call again only for a change they asked for.',
      );
    }
    return bits.join(' ');
  }
}

class Playbook {
  const new(this.id, this.nodes);

  final String id;
  final List<GraphNode> nodes;
}

/// Nodes whose dependencies are in [done]. Order follows [nodes].
List<GraphNode> readyNodes(List<GraphNode> nodes, Set<String> done) {
  return [
    for (final node in nodes)
      if (!done.contains(node.id) && node.after.every(done.contains)) node,
  ];
}

/// A failed tool result is a finished node, not a prompt to try again.
bool nodeFailed(String result) {
  final text = result.toLowerCase();
  const marks = [
    'could not',
    'unavailable',
    'returned nothing',
    'needs a reconnect',
    'refused',
    'no connected apps',
    'not connected',
    'no grant',
    'failed',
    'error',
  ];
  for (final mark in marks) {
    if (text.contains(mark)) return true;
  }
  return false;
}

/// One connected app. [phrases] are how a person names it. [next] is
/// what a later call can do, and only when they asked for that change.
class DeskApp {
  const DeskApp(this.slug, this.phrases, this.next);

  final String slug;
  final List<String> phrases;
  final String next;
}

const deskApps = <DeskApp>[
  DeskApp('gmail', [
    'gmail',
    'inbox',
    'mailbox',
    'latest email',
  ], 'A reply or a send is a later call only if they asked to reply or send.'),
  DeskApp(
    'google-calendar',
    [
      'calendar',
      'schedule',
      'agenda',
      'my day',
      'my week',
      'this afternoon',
      'my afternoon',
    ],
    'A new or moved event is a later call only if they asked to change the day.',
  ),
  DeskApp(
    'google-drive',
    ['google drive', 'my drive'],
    'Opening or creating a file is a later call only if they asked for a file.',
  ),
  DeskApp('google-docs', [
    'google doc',
    'google docs',
    'my docs',
  ], 'Editing a document is a later call only if they asked to change it.'),
  DeskApp(
    'github',
    ['github'],
    'An issue or a pull request is a later call only if they asked to write one.',
  ),
  DeskApp('linked-in', [
    'linkedin',
    'linked in',
  ], 'A post is a later call only if they asked to publish it.'),
  DeskApp('figma', [
    'figma',
  ], 'A change to a file is a later call only if they asked to edit it.'),
  DeskApp('supabase', [
    'supabase',
  ], 'A change to the project is a later call only if they asked for it.'),
  DeskApp('x', [
    'twitter',
    'on x',
  ], 'A post is a later call only if they asked to publish it.'),
  DeskApp('google-sheets', [
    'google sheet',
    'google sheets',
    'google-sheets',
    'spreadsheet',
  ], 'Editing a sheet is a later call only if they asked to change it.'),
  DeskApp('google-slides', [
    'google slides',
    'google-slides',
    'slide deck',
  ], 'Editing a deck is a later call only if they asked to change it.'),
  DeskApp('google-tasks', [
    'google tasks',
    'google-tasks',
  ], 'A new or completed task is a later call only if they asked for it.'),
  DeskApp('slack', [
    'slack',
  ], 'A message is a later call only if they asked to send one.'),
  DeskApp('notion', [
    'notion',
  ], 'A new or edited page is a later call only if they asked to change it.'),
  DeskApp('linear', [
    'in linear',
    'linear issue',
    'linear ticket',
  ], 'A new issue is a later call only if they asked to write one.'),
  DeskApp('zoom', [
    'zoom',
  ], 'A new meeting is a later call only if they asked to book one.'),
  DeskApp(
    'outlook-calendar',
    ['outlook calendar', 'outlook-calendar'],
    'A new or moved event is a later call only if they asked to change the day.',
  ),
  DeskApp('outlook-mail', [
    'outlook mail',
    'outlook-mail',
    'outlook',
  ], 'A reply or a send is a later call only if they asked to reply or send.'),
  DeskApp('teams', [
    'microsoft teams',
    'on teams',
  ], 'A message is a later call only if they asked to send one.'),
  DeskApp(
    'one-drive',
    ['onedrive', 'one drive', 'one-drive'],
    'Opening or creating a file is a later call only if they asked for a file.',
  ),
  DeskApp(
    'dropbox',
    ['dropbox'],
    'Opening or creating a file is a later call only if they asked for a file.',
  ),
  DeskApp('asana', [
    'asana',
  ], 'A new or completed task is a later call only if they asked for it.'),
  DeskApp('todoist', [
    'todoist',
  ], 'A new or completed task is a later call only if they asked for it.'),
  DeskApp('airtable', [
    'airtable',
  ], 'A new or edited row is a later call only if they asked to change it.'),
  DeskApp('jira', [
    'jira',
  ], 'A new issue is a later call only if they asked to write one.'),
  DeskApp('trello', [
    'trello',
  ], 'A new card is a later call only if they asked to write one.'),
  DeskApp('click-up', [
    'clickup',
    'click up',
    'click-up',
  ], 'A new task is a later call only if they asked to write one.'),
  DeskApp('calendly', [
    'calendly',
  ], 'A new booking is a later call only if they asked to book it.'),
  DeskApp('hubspot', [
    'hubspot',
  ], 'A new or edited record is a later call only if they asked to change it.'),
  DeskApp('stripe', [
    'stripe',
  ], 'A refund or a charge is a later call only if they asked for it.'),
  DeskApp('sentry', [
    'sentry',
  ], 'Resolving an issue is a later call only if they asked to change it.'),
  DeskApp('vercel', [
    'vercel',
  ], 'A deploy is a later call only if they asked to start one.'),
  DeskApp('cloudflare', [
    'cloudflare',
  ], 'A DNS or config change is a later call only if they asked for it.'),
  DeskApp('discord', [
    'discord',
  ], 'A message is a later call only if they asked to send one.'),
  DeskApp('intercom', [
    'intercom',
  ], 'A reply is a later call only if they asked to send one.'),
];

/// The one line the model reads after a page comes back.
String nextStep(String platform) {
  for (final app in deskApps) {
    if (app.slug == platform) return app.next;
  }
  return 'A change is a later call only if they asked for the change.';
}

/// A known account read. Sync stays on the model, because that is a
/// different job. A memory question stays on memory.
Playbook? playbookFor(String text) {
  final lower = text.toLowerCase();
  if (RegExp(r'\bsync\b').hasMatch(lower)) return null;
  if (lower.contains('what do you remember')) return null;
  final hits = <({int at, String slug})>[];
  for (final app in deskApps) {
    var at = -1;
    for (final phrase in app.phrases) {
      final found = lower.indexOf(phrase);
      if (found >= 0 && (at < 0 || found < at)) at = found;
    }
    if (at >= 0) hits.add((at: at, slug: app.slug));
  }
  hits.sort((a, b) => a.at.compareTo(b.at));
  final apps = [for (final hit in hits) hit.slug];
  if (apps.isEmpty) {
    final named = _namedSlug(lower);
    if (named != null) apps.add(named);
  }
  if (apps.isEmpty || !_isRead(lower)) return null;
  return Playbook('account-read', [
    GraphNode(
      id: 'memory',
      tool: 'memory_search',
      label: 'memory',
      able: "search this person's memory",
      after: const [],
      args: (state) => {'query': state.ask, 'limit': 6},
    ),
    for (final platform in apps)
      GraphNode(
        id: 'read-$platform',
        tool: 'connector',
        label: platform,
        able: 'read one page of the connected $platform account',
        after: const ['memory'],
        args: (state) => {'platform': platform, 'intent': state.ask},
      ),
  ]);
}

/// They told us to change the account, not only to look.
bool asksToChange(String text) {
  final lower = text.toLowerCase();
  if (lower.contains('should i') || lower.contains('should we')) return false;
  if (RegExp(r'\b(send|reply|draft|book|create|reschedule|invite|write)\b')
      .hasMatch(lower)) {
    return true;
  }
  return RegExp(r'\b(schedule|move)\s+(a|an|the|this|it|me|my)\b')
      .hasMatch(lower);
}

const _memoryStops = {
  'about',
  'remember',
  'memory',
  'memories',
  'something',
  'anything',
  'nothing',
  'please',
  'search',
  'would',
  'could',
  'should',
  'there',
  'their',
  'which',
  'where',
  'what',
  'that',
  'this',
  'with',
  'from',
  'have',
  'your',
  'word',
  'words',
  'email',
  'inbox',
  'account',
  'login',
  'latest',
  'read',
  'return',
  'returned',
  'connector',
  'tools',
  'tool',
  'does',
  'dont',
  'didnt',
  'they',
  'them',
  'into',
  'call',
  'calls',
  'again',
  'page',
  'once',
  'fails',
  'fail',
  'invent',
  'repository',
  'repositories',
  'subject',
  'sent',
  'name',
  'named',
};

/// Words that have to appear in a memory before it counts as this ask.
List<String> distinctiveWords(String query) {
  final words = query.toLowerCase().split(RegExp('[^a-z0-9]+'));
  return [
    for (final word in words)
      if (word.length >= 5 && !_memoryStops.contains(word)) word,
  ];
}

String _rowText(Map<String, dynamic> row) {
  return '${row['title'] ?? ''} ${row['body'] ?? ''}'.toLowerCase();
}

/// Drops nearest neighbors that do not contain the asked word.
/// On an account read, prior notes are not the account either.
List<Map<String, dynamic>> memoriesForAsk(
  String query,
  List<Map<String, dynamic>> rows,
) {
  final words = distinctiveWords(query);
  var kept = words.isEmpty
      ? rows
      : [
          for (final row in rows)
            if (words.any((word) => _rowText(row).contains(word))) row,
        ];
  if (playbookFor(query) != null) return const [];
  return kept;
}

bool _isRead(String lower) {
  const cues = [
    'account',
    'login',
    'repo',
    'inbox',
    'email',
    'who sent',
    'latest',
    'what is in',
    "what's in",
    'what is on',
    "what's on",
    'read',
    'today',
    'tomorrow',
    'plan',
    'open',
    'find',
    'show',
    'list',
    'check',
    'unread',
    'meeting',
  ];
  for (final cue in cues) {
    if (lower.contains(cue)) return true;
  }
  return false;
}

/// A connector slug written in the message, for a tool with no phrase yet.
/// One's directory is about a thousand tools. Naming the slug is enough.
String? _namedSlug(String lower) {
  final match = RegExp(r'\b[a-z0-9]+(?:-[a-z0-9]+){1,4}\b').firstMatch(lower);
  if (match == null) return null;
  final slug = match.group(0)!;
  if (slug.length < 5) return null;
  if (deskApps.any((app) => app.slug == slug || app.phrases.contains(slug))) {
    return null;
  }
  const ordinary = {
    'well-known',
    'non-empty',
    'follow-up',
    'long-term',
    'real-time',
    'built-in',
    'high-level',
    'day-to-day',
    'e-mail',
  };
  if (ordinary.contains(slug)) return null;
  return slug;
}

/// Runs [book] in supersteps. Independent nodes share a wave.
Future<GraphCheckpoint> runGraph({
  required Playbook book,
  required String ask,
  required Future<String> Function(String tool, String arguments) call,
}) async {
  final waiting = [...book.nodes];
  final done = <String>{};
  final results = <String, String>{};
  final waves = <List<GraphCall>>[];
  while (waiting.isNotEmpty) {
    final ready = readyNodes(waiting, done);
    if (ready.isEmpty) break;
    waiting.removeWhere(ready.contains);
    final wave = <GraphCall>[];
    for (final node in ready) {
      final state = GraphState(ask, results);
      if (node.when != null && !node.when!(state)) {
        done.add(node.id);
        results[node.id] = '';
        continue;
      }
      final arguments = jsonEncode(node.args(state));
      final result = await call(node.tool, arguments);
      done.add(node.id);
      results[node.id] = result;
      wave.add(
        GraphCall(
          id: 'graph-${node.id}',
          tool: node.tool,
          label: node.label,
          able: node.able,
          arguments: arguments,
          result: result,
          failed: nodeFailed(result),
        ),
      );
    }
    if (wave.isNotEmpty) waves.add(wave);
  }
  return GraphCheckpoint(book.id, waves);
}
