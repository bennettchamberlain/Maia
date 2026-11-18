import 'dart:convert';

import 'package:maia_api/src/chat/ladder.dart';

/// Told to the model after a known-problem graph has run. The checkpoint
/// is already in the thread. This is not a message from the person.
const graphAnswerCue =
    "Answer the person's latest message from the checkpoint above. "
    'The graph has finished, so do not call a tool. '
    'A call that did not return is finished: say what it is able to '
    'return, and say you do not have the fact. Earlier notes are not '
    'the account. Do not invent it. '
    'Do not mention the graph, the checkpoint, or the tools.';

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
            ? '${call.tool} on ${call.label} did not return. '
                  'It is able to ${call.able}. You do not have that fact. '
                  'Do not call it again.'
            : notes
            ? 'memory_search returned earlier notes, not the live account. '
                  'Do not treat them as the login or the mailbox.'
            : '${call.tool} on ${call.label} returned. '
                  'Use that result and do not call it again.',
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
    'failed',
    'error',
  ];
  for (final mark in marks) {
    if (text.contains(mark)) return true;
  }
  return false;
}

const _platforms = ['github', 'gmail', 'calendar'];

/// A known account read. Sync stays on the model, because that is a
/// different job. Anything else is not a graph.
Playbook? playbookFor(String text) {
  final lower = text.toLowerCase();
  if (RegExp(r'\bsync\b').hasMatch(lower)) return null;
  final apps = [
    for (final platform in _platforms)
      if (_mentions(lower, platform)) platform,
  ];
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

bool _mentions(String lower, String platform) {
  return switch (platform) {
    'github' => lower.contains('github'),
    'gmail' =>
      lower.contains('gmail') ||
          lower.contains('inbox') ||
          lower.contains('latest email'),
    'calendar' => lower.contains('calendar'),
    _ => false,
  };
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
    'read',
  ];
  for (final cue in cues) {
    if (lower.contains(cue)) return true;
  }
  return false;
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
