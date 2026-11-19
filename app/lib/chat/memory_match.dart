import 'package:maie_app/chat/parts/chat_part.dart';

const _stops = {
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

/// Words that have to show up in a memory before it belongs to [ask].
List<String> distinctiveWords(String ask) {
  final words = ask.toLowerCase().split(RegExp('[^a-z0-9]+'));
  return [
    for (final word in words)
      if (word.length >= 5 && !_stops.contains(word)) word,
  ];
}

/// True when [ask] is a read of a connected account.
bool asksForAccount(String ask) {
  final lower = ask.toLowerCase();
  if (lower.contains('what do you remember')) return false;
  const desk = [
    'github',
    'gmail',
    'inbox',
    'mailbox',
    'calendar',
    'schedule',
    'agenda',
    'my day',
    'my week',
    'google drive',
    'my drive',
    'google doc',
    'linkedin',
    'linked in',
    'figma',
    'supabase',
    'twitter',
    'slack',
    'notion',
    'linear',
    'zoom',
    'outlook',
    'spreadsheet',
    'google sheet',
    'dropbox',
    'onedrive',
    'one drive',
    'asana',
    'todoist',
    'jira',
    'sentry',
    'vercel',
    'stripe',
  ];
  if (!desk.any(lower.contains)) return false;
  const cues = [
    'account',
    'login',
    'repo',
    'inbox',
    'email',
    'latest',
    'read',
    'who',
    'what',
    'today',
    'tomorrow',
    'plan',
    'open',
    'find',
    'show',
    'list',
    'reply',
    'send',
    'draft',
  ];
  for (final cue in cues) {
    if (lower.contains(cue)) return true;
  }
  return false;
}

/// True when [memory] is a reading of [ask], not a nearest neighbor.
bool memoryAnswers(String ask, ChatMemory memory) {
  final words = distinctiveWords(ask);
  final hay = '${memory.title} ${memory.body}'.toLowerCase();
  if (asksForAccount(ask)) return false;
  if (words.isEmpty) return true;
  return words.any(hay.contains);
}

/// Drops a tool lecture the model was told not to give.
String replyWithoutToolLecture(String text) {
  final parts = text.split(RegExp(r'(?<=[.!?])\s+'));
  final kept = [
    for (final part in parts)
      if (!_lecture(part)) part,
  ];
  return kept.join(' ').trim();
}

bool _lecture(String part) {
  final lower = part.toLowerCase();
  return lower.contains('the connector can return') ||
      lower.contains('is able to return');
}

/// Removes memory cards that do not answer [ask]. An empty timeline goes away.
ChatPart? withoutUnrelatedMemory(ChatPart part, String ask) {
  if (part is ChatText) {
    final clean = replyWithoutToolLecture(part.text).trim();
    if (clean.isEmpty || clean.toLowerCase() == 'no memories') return null;
    return clean == part.text ? part : ChatText(clean);
  }
  if (part is ChatTimeline) {
    final children = [
      for (final child in part.children)
        if (child is! ChatMemory || memoryAnswers(ask, child))
          withoutUnrelatedMemory(child, ask),
    ].whereType<ChatPart>().toList();
    if (children.isEmpty) return null;
    return ChatTimeline(title: part.title, children: children);
  }
  if (part is ChatColumn) {
    final children = _kept(part.children, ask);
    if (children.isEmpty || children.every((child) => child is ChatMap)) {
      return null;
    }
    return ChatColumn(children);
  }
  if (part is ChatRow) {
    final children = _kept(part.children, ask);
    if (children.isEmpty) return null;
    return ChatRow(children);
  }
  if (part is ChatList) {
    final children = _kept(part.children, ask);
    if (children.isEmpty) return null;
    return ChatList(children);
  }
  return part;
}

List<ChatPart> _kept(List<ChatPart> children, String ask) {
  return [for (final child in children) withoutUnrelatedMemory(child, ask)]
      .whereType<ChatPart>()
      .toList();
}
