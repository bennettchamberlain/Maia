/// Verifiable chat-turn cases mirrored from `evals/chat/answers.md`.
/// The app (or tests) can check a reply string against [ChatTurnBenchCase].
class ChatTurnBenchCase {
  const new({
    required this.id,
    required this.prompt,
    this.mustInclude = const [],
    this.mustNotInclude = const [],
    this.exact,
    this.noTool = false,
    this.toolsBefore = const [],
    this.mustNotTool = const [],
  });

  final String id;
  final String prompt;
  final List<String> mustInclude;
  final List<String> mustNotInclude;

  /// When set, the trimmed reply must equal this exactly.
  final String? exact;
  final bool noTool;

  /// Tool names that must appear in this order. Extra calls may sit between.
  final List<String> toolsBefore;

  /// Tools that fail the case when the turn calls them.
  final List<String> mustNotTool;

  String? checkReply(String reply, {Iterable<String> toolNames = const []}) {
    final text = reply.trim();
    final names = toolNames.toList();
    if (exact != null && text != exact) {
      final shown = text.length > 80 ? '${text.substring(0, 80)}…' : text;
      return 'expected exact "$exact", got "$shown"';
    }
    final lower = text.toLowerCase();
    for (final needle in mustInclude) {
      if (!lower.contains(needle.toLowerCase())) {
        return 'missing "$needle"';
      }
    }
    for (final needle in mustNotInclude) {
      if (lower.contains(needle.toLowerCase())) {
        return 'must not contain "$needle"';
      }
    }
    if (noTool && names.isNotEmpty) {
      return 'expected no tool, saw ${names.join(", ")}';
    }
    for (final banned in mustNotTool) {
      if (names.contains(banned)) return 'called $banned';
    }
    var at = 0;
    for (final name in names) {
      if (at < toolsBefore.length && name == toolsBefore[at]) at++;
    }
    if (at != toolsBefore.length) {
      final want = toolsBefore.join(' then ');
      return 'tools ${names.join(", ")} did not follow $want';
    }
    return null;
  }
}

/// The previous ladder passed. These judge a failed read, a two-app
/// graph, and a question that must not become a tool call.
const chatTurnBenchCases = <ChatTurnBenchCase>[
  ChatTurnBenchCase(
    id: 'checkpoint',
    prompt: 'Reply with the single word checkpoint.',
    exact: 'checkpoint',
    noTool: true,
  ),
  ChatTurnBenchCase(
    id: 'acyclic',
    prompt: 'In one sentence, what makes a graph acyclic? No tools.',
    mustInclude: ['cycle'],
    mustNotInclude: ['what would you like'],
    noTool: true,
  ),
  ChatTurnBenchCase(
    id: 'quorinth',
    prompt: 'What do you remember about the word quorinth? If memory has nothing, say you do not have it. Do not search the web.',
    mustInclude: ['quorinth', 'do not have'],
    mustNotInclude: ['what would you like', 'action_id'],
    mustNotTool: ['web_search', 'url_read', 'computer'],
  ),
  ChatTurnBenchCase(
    id: 'capability',
    prompt: 'The GitHub read did not return. Say what that tool is able to return, and say you do not have the account. Do not invent a login or a repository.',
    mustInclude: ['able', 'do not have'],
    mustNotInclude: [
      'action_id',
      'conn_mod',
      'Call connector',
      'what would you like',
    ],
    toolsBefore: ['memory_search', 'connector'],
    mustNotTool: ['web_search', 'computer'],
  ),
  ChatTurnBenchCase(
    id: 'one-read',
    prompt: 'Read my GitHub account once. If the read fails, do not search the web and do not try again. Say that you do not have the account.',
    mustInclude: ['github', 'do not have'],
    mustNotInclude: ['action_id', 'conn_mod', 'what would you like'],
    toolsBefore: ['memory_search', 'connector'],
    mustNotTool: ['web_search', 'url_read', 'computer'],
  ),
  ChatTurnBenchCase(
    id: 'two-apps',
    prompt: 'What is my GitHub login, and who sent my latest Gmail? They do not depend on each other. For whichever call does not return, say you do not have that one. Do not invent it.',
    mustInclude: ['github', 'gmail', 'do not have'],
    mustNotInclude: [
      'action_id',
      'conn_mod',
      'Call connector',
      'what would you like',
    ],
    toolsBefore: ['memory_search', 'connector', 'connector'],
    mustNotTool: ['web_search', 'computer'],
  ),
];
