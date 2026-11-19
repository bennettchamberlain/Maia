/// Rows worth keeping from a One action result. Any connector, not only
/// the three the nightly pull names.
class ConnectorCopy {
  const ConnectorCopy({
    required this.sourceId,
    required this.title,
    required this.body,
    required this.at,
    required this.kind,
  });

  final String sourceId;
  final String title;
  final String body;
  final DateTime at;
  final String kind;
}

/// The first call names actions. The second call's data is what we copy.
List<ConnectorCopy> connectorCopies(String platform, Object? data) {
  final out = <ConnectorCopy>[];
  for (final row in _records(data)) {
    final id = _id(row);
    if (id.isEmpty) continue;
    final headers = _headers(row);
    final title = _text(
      headers['subject'] ??
          row['full_name'] ??
          row['title'] ??
          row['name'] ??
          row['login'] ??
          row['summary'] ??
          row['subject'] ??
          row['snippet'] ??
          row['text'] ??
          platform,
    );
    final sender = _text(headers['from'] ?? row['from'] ?? '');
    final login = _text(row['login'] ?? _ownerLogin(row));
    final body = _text(
      row['bio'] ??
          row['description'] ??
          row['snippet'] ??
          row['text'] ??
          row['body'] ??
          row['preview'] ??
          '',
    );
    final withLogin = login.isEmpty || title == login ? body : '$login. $body';
    final written = sender.isEmpty
        ? withLogin
        : 'From: $sender\n$withLogin'.trim();
    out.add(
      ConnectorCopy(
        sourceId: id,
        title: title.isEmpty ? platform : title,
        body: _clip(written, 500),
        at: _when(row),
        kind: _kind(platform),
      ),
    );
    if (out.length == 8) break;
  }
  return out;
}

/// What the model reads back. The title alone is not a reading of the mail.
String connectorBrief(String platform, int copied, List<ConnectorCopy> rows) {
  final lines = <String>[];
  for (final row in rows) {
    final said = row.body.replaceAll(RegExp(r'\s+'), ' ').trim();
    lines.add(said.isEmpty ? '- ${row.title}' : '- ${row.title}. $said');
  }
  final noun = copied == 1 ? 'record' : 'records';
  return 'Read $copied $platform $noun.\n${lines.join('\n')}';
}

/// What the model should do with the action list from the first call.
String connectorActionPrompt(
  String platform,
  Object? actions, {
  String account = '',
}) {
  if (actions is! List || actions.isEmpty) {
    return 'No One action matched $platform. Say that and stop.';
  }
  final lines = <String>[];
  for (final action in actions.take(3)) {
    if (action is! Map) continue;
    final id = _text(action['action_id'] ?? action['id']);
    if (id.isEmpty) continue;
    final title = _text(action['title'] ?? action['name'] ?? id);
    final hint = _clip(
      _text(action['knowledge'] ?? action['description'] ?? ''),
      180,
    );
    lines.add(
      hint.isEmpty ? '$title. action_id: $id' : '$title. action_id: $id. $hint',
    );
  }
  if (lines.isEmpty) {
    return 'No One action matched $platform. Say that and stop.';
  }
  final login = account.trim().isEmpty
      ? ''
      : ' The connected login is $account. Put it in path_params for a '
            'field such as username. Do not ask the person for it.';
  return 'Call connector again for $platform with one action_id below '
      'and the fields that action asks for, in path_params. '
      'The rows are copied into memory.$login\n'
      '${lines.join('\n')}';
}

const _harnessMarkers = [
  'Call connector again',
  'conn_mod_def',
  'action_id:',
  'conn_mod_def::',
];

/// True when [text] carries connector harness instructions, not human prose.
bool looksLikeConnectorHarnessText(String text) {
  final hay = text.toLowerCase();
  for (final marker in _harnessMarkers) {
    if (hay.contains(marker.toLowerCase())) return true;
  }
  return false;
}

/// Drops connector action prompts and other harness text before it reaches
/// the person or the stored assistant message.
String publicChatText(String text) {
  var t = text;
  for (final marker in _harnessMarkers) {
    final i = t.indexOf(marker);
    if (i >= 0) t = t.substring(0, i);
  }
  t = t.replaceAll(
    RegExp(r'\s*What would you like to do\??', caseSensitive: false),
    '',
  );
  final lecture = t.toLowerCase().indexOf('the connector can return');
  if (lecture >= 0) t = t.substring(0, lecture);
  return t.trimRight();
}

List<Map<String, dynamic>> _records(Object? payload) {
  const keys = [
    'items',
    'data',
    'results',
    'records',
    'repositories',
    'repos',
    'messages',
    'events',
    'issues',
    'nodes',
    'values',
    'threads',
  ];
  if (payload is List) {
    return [
      for (final row in payload)
        if (row is Map) Map<String, dynamic>.from(row),
    ];
  }
  if (payload is! Map) return const [];
  final map = Map<String, dynamic>.from(payload);
  for (final key in keys) {
    final value = map[key];
    if (value is List) {
      final rows = [
        for (final row in value)
          if (row is Map) Map<String, dynamic>.from(row),
      ];
      if (rows.isNotEmpty) return rows;
    }
    if (value is Map) {
      final nested = _records(value);
      if (nested.isNotEmpty) return nested;
    }
  }
  return map['id'] == null && map['ts'] == null ? const [] : [map];
}

String _ownerLogin(Map<String, dynamic> row) {
  final owner = row['owner'];
  if (owner is! Map) return '';
  return _text(owner['login']);
}

String _id(Map<String, dynamic> row) {
  for (final key in ['id', 'ts', 'gid', 'url', 'threadId', 'iCalUID']) {
    final value = _text(row[key]);
    if (value.isNotEmpty) return value;
  }
  return '';
}

Map<String, String> _headers(Map<String, dynamic> row) {
  final payload = row['payload'];
  final raw = payload is Map ? payload['headers'] : row['headers'];
  if (raw is! List) return const {};
  final out = <String, String>{};
  for (final header in raw) {
    if (header is! Map) continue;
    final name = _text(header['name']).toLowerCase();
    if (name.isEmpty) continue;
    out[name] = _text(header['value']);
  }
  return out;
}

DateTime _when(Map<String, dynamic> row) {
  final start = row['start'];
  final candidates = [
    row['internalDate'],
    row['date'],
    row['occurred_at'],
    row['updated_at'],
    row['created_at'],
    if (start is Map) start['dateTime'] ?? start['date'],
  ];
  for (final value in candidates) {
    final parsed = _time(value);
    if (parsed != null) return parsed;
  }
  return DateTime.now().toUtc();
}

DateTime? _time(Object? value) {
  if (value is DateTime) return value.toUtc();
  if (value is num) {
    final ms = value < 10000000000 ? value * 1000 : value;
    return DateTime.fromMillisecondsSinceEpoch(ms.round(), isUtc: true);
  }
  final text = _text(value);
  if (text.isEmpty) return null;
  if (RegExp(r'^\d+$').hasMatch(text)) return _time(num.parse(text));
  return DateTime.tryParse(text)?.toUtc();
}

String _kind(String platform) => switch (platform) {
  'gmail' || 'outlook-mail' => 'email',
  'google-calendar' || 'outlook-calendar' => 'event',
  'google-drive' ||
  'google-docs' ||
  'google-sheets' ||
  'google-slides' ||
  'one-drive' ||
  'dropbox' => 'file',
  _ => 'note',
};

String _text(Object? value) => '$value'.trim() == 'null' ? '' : '$value'.trim();

String _clip(String text, int max) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= max ? flat : flat.substring(0, max);
}
