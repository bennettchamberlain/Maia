import 'dart:convert';

/// Which shelf a tool sits on. The model is told this order, and the
/// turn refuses to leave memory until memory has been asked once.
enum ToolPlane { memory, special, connector, web, computer }

/// Where each tool belongs. A name that is missing is not on the ladder.
const toolPlanes = <String, ToolPlane>{
  'memory_search': ToolPlane.memory,
  'memory_recent': ToolPlane.memory,
  'memory_get': ToolPlane.memory,
  'life_graph': ToolPlane.memory,
  'library_read': ToolPlane.memory,
  'session_search': ToolPlane.memory,
  'remember': ToolPlane.special,
  'now': ToolPlane.special,
  'intent_create': ToolPlane.special,
  'skill_propose': ToolPlane.special,
  'file_read': ToolPlane.special,
  'image_describe': ToolPlane.special,
  'video_describe': ToolPlane.special,
  'vault_list': ToolPlane.special,
  'connector': ToolPlane.connector,
  'sync': ToolPlane.connector,
  'url_read': ToolPlane.web,
  'web_search': ToolPlane.web,
  'computer': ToolPlane.computer,
};

/// Connectors, the web, and the desktop wait until memory has been read.
bool consultMemoryFirst(String name) {
  final plane = toolPlanes[name];
  if (plane == null) return false;
  return plane.index >= ToolPlane.connector.index;
}

/// A connected app runs in this same step when memory has no live record.
/// Earlier notes that mention the app are not that record. The web and
/// the desktop still wait for a second call.
bool runAlongsideEmptyMemory(String name, String memoryResult) {
  if (name != 'connector' && name != 'sync') return false;
  return memoryIsChatter(memoryResult);
}

/// True when memory has nothing, or only prior notes and session summaries.
bool memoryIsChatter(String result) {
  if (result.toLowerCase().contains('no memories')) return true;
  try {
    final decoded = jsonDecode(result);
    final children = _memoryChildren(decoded);
    if (children.isEmpty) return true;
    for (final child in children) {
      final kind = '${child['kind'] ?? ''}'.toLowerCase();
      if (kind != 'note' && kind != 'session') return false;
    }
    return true;
  } on FormatException {
    return false;
  }
}

List<Map<String, dynamic>> _memoryChildren(Object? node) {
  if (node is! Map) return const [];
  if (node['type'] == 'memory') {
    return [Map<String, dynamic>.from(node)];
  }
  final raw = node['children'];
  if (raw is! List) return const [];
  return [for (final child in raw) ..._memoryChildren(child)];
}

/// What the model sees instead of a premature connector, web, or desktop call.
String memoryFirstNote(String query, String memoryResult) {
  final chatter = memoryIsChatter(memoryResult);
  final next = chatter
      ? 'These are earlier notes, not the live account. '
            'Call this tool again if you still need it.'
      : 'If this answers the person, stop. '
            'Call this tool again only if it does not.';
  return 'Checked memory first for "$query". $memoryResult $next';
}

/// The order, in the words the turn context repeats every time.
const toolLadder =
    'Use tools in this order. Memory first: memory_search, memory_recent, '
    'memory_get, life_graph, library_read. Then a specialized tool: '
    'file_read, image_describe, video_describe, vault_list, now. '
    'Then a connected app, and use it when the turn lists that app: '
    'connector, then sync when they asked to sync. Then a page or the '
    'public web: url_read, web_search. Last, computer, which wakes this '
    "person's desktop. A credential is a cred_ handle from vault_list. "
    'Never ask them to paste a secret, and never repeat one.';
