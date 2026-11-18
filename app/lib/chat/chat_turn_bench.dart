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
  });

  final String id;
  final String prompt;
  final List<String> mustInclude;
  final List<String> mustNotInclude;

  /// When set, the trimmed reply must equal this exactly.
  final String? exact;
  final bool noTool;

  String? checkReply(String reply, {Iterable<String> toolNames = const []}) {
    final text = reply.trim();
    if (exact != null && text != exact) {
      return 'expected exact "$exact", got "${text.length > 80 ? '${text.substring(0, 80)}…' : text}"';
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
    if (noTool && toolNames.isNotEmpty) {
      return 'expected no tool, saw ${toolNames.join(", ")}';
    }
    return null;
  }
}

/// Ordered ladder, easy then hard (same order as the live eval client).
const chatTurnBenchCases = <ChatTurnBenchCase>[
  ChatTurnBenchCase(
    id: 'ready',
    prompt: 'Reply with the single word ready.',
    exact: 'ready',
    noTool: true,
  ),
  ChatTurnBenchCase(
    id: 'arithmetic',
    prompt: 'What is 2+2? Reply with the number only.',
    exact: '4',
    noTool: true,
  ),
  ChatTurnBenchCase(
    id: 'water-wet',
    prompt: 'Is water wet? Yes or no, then one reason.',
    mustNotInclude: ['what would you like'],
    noTool: true,
  ),
  ChatTurnBenchCase(
    id: 'github-access',
    prompt: 'Do you have access to GitHub?',
    mustNotInclude: [
      'action_id',
      'conn_mod',
      'Call connector',
      'what would you like',
    ],
  ),
  ChatTurnBenchCase(
    id: 'austen',
    prompt: 'Who wrote Pride and Prejudice? Name only.',
    mustInclude: ['Austen'],
    mustNotInclude: ['Search results', 'snippet'],
  ),
  ChatTurnBenchCase(
    id: 'primary-colors',
    prompt: 'Name the three primary colors, one per line, and nothing else.',
    mustInclude: ['red', 'blue'],
    noTool: true,
  ),
  ChatTurnBenchCase(
    id: 'github-account',
    prompt:
        'What is in my GitHub account right now? If you cannot see a repo or a login, say you do not have it. Do not list actions.',
    mustNotInclude: ['action_id', 'conn_mod'],
  ),
];