import 'dart:convert';

import 'package:gel/gel.dart' as gel;
import 'package:http/http.dart' as http;
import 'package:maie_api/src/agent.dart';
import 'package:maie_api/src/chat/graphs.dart';
import 'package:maie_api/src/chat/senses.dart';

/// Host tools the chat model can call. OpenClaw keeps its own; Parasail
/// and Ollama run these here so memory and the web stay on the server.
class ChatToolbox {
  ChatToolbox({
    required this.searchMemory,
    required this.recentMemory,
    required this.getMemory,
    required this.remember,
    required this.lifeGraph,
    this.youApiKey,
    this.openRouterApiKey,
    this.openRouterBaseUrl = 'https://openrouter.ai/api/v1',
    this.openRouterModel = 'google/gemini-2.5-flash-lite',
    this.disabled = const {},
    this.connector,
    this.sync,
    this.allow,
    this.sessionSearch,
    this.proposeSkill,
    this.createIntent,
    this.readLibrary,
    this.senses,
    this.computer,
    this.vaultList,
    this.scrub,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final Future<List<Map<String, dynamic>>> Function(
    gel.Client c,
    String query,
    int limit,
  )
  searchMemory;
  final Future<List<Map<String, dynamic>>> Function(gel.Client c, int limit)
  recentMemory;
  final Future<Map<String, dynamic>?> Function(gel.Client c, String id)
  getMemory;
  final Future<String> Function(gel.Client c, String title, String? body)
  remember;
  final Future<Map<String, dynamic>?> Function(gel.Client c) lifeGraph;
  final String? youApiKey;

  /// Used when You.com has no key. Search runs on OpenRouter's web plugin.
  final String? openRouterApiKey;
  final String openRouterBaseUrl;
  final String openRouterModel;
  final Set<String> disabled;

  /// Runs a granted One connector. Null when this person has none.
  final Future<String> Function(Map<String, dynamic> args)? connector;

  /// Queues a connector sync and reports whether jobs are actually pulling.
  final Future<String> Function(gel.Client c, Map<String, dynamic> args)? sync;

  /// Null means every tool. `memory` and `work` are the two planes.
  final Set<String>? allow;
  final Future<List<Map<String, dynamic>>> Function(
    gel.Client c,
    String query,
    int limit,
  )?
  sessionSearch;
  final Future<String> Function(gel.Client c, String name, String body)?
  proposeSkill;
  final Future<String> Function(
    gel.Client c,
    String phrase,
    String instruction,
  )?
  createIntent;
  final Future<String?> Function(String kind, String id)? readLibrary;

  /// Files, images, and video. Null hides those tools.
  final Senses? senses;

  /// Wakes this person's desktop. Null hides the tool.
  final Future<String> Function(gel.Client c, Map<String, dynamic> args)?
  computer;

  /// Credential handles only. Never a secret.
  final Future<String> Function()? vaultList;

  /// Rewrites a tool result so a stored secret becomes its cred_ handle.
  final Future<String> Function(String text)? scrub;
  final http.Client _http;

  bool get youConfigured => youApiKey != null && youApiKey!.isNotEmpty;

  bool get openRouterConfigured =>
      openRouterApiKey != null && openRouterApiKey!.isNotEmpty;

  bool get webAvailable => youConfigured || openRouterConfigured;

  bool get connectorsAvailable => connector != null;

  bool isOn(String name) =>
      !disabled.contains(name) && (allow == null || allow!.contains(name));

  List<Map<String, dynamic>> get catalog => [
    _info(
      'memory_search',
      "Search the user's personal memory (notes, events, people, places).",
    ),
    _info('memory_recent', 'Most recent items in the memory feed.'),
    _info('memory_get', 'Fetch one memory by id.'),
    _info('remember', 'Save a note the user asked to keep.'),
    _info('life_graph', 'Goals, projects, habits, people and relationships.'),
    _info(
      'web_search',
      'Search the public web. Use for news, facts, places.',
      available: webAvailable,
    ),
    _info('now', 'Current local date and time.'),
    _info(
      'library_read',
      'Open one skill, file, or turn from the person\'s directory.',
      available: readLibrary != null,
    ),
    _info(
      'connector',
      'Use a connected app such as Gmail, Calendar, or Slack.',
      available: connectorsAvailable,
    ),
    _info(
      'sync',
      'Queue a full pull of a connected app into memory, and report '
          'whether that pull is actually running.',
      available: sync != null,
    ),
    _info(
      'file_read',
      'Read a public file and, when it is an image or a video, describe it.',
      available: senses != null,
    ),
    _info(
      'image_describe',
      'Describe an image at a public url.',
      available: senses != null,
    ),
    _info(
      'video_describe',
      'Describe a video at a public url.',
      available: senses != null,
    ),
    _info(
      'url_read',
      'Read the text of one public page.',
      available: senses != null,
    ),
    _info(
      'vault_list',
      'List credential handles. The secret stays out of the chat.',
      available: vaultList != null,
    ),
    _info(
      'computer',
      'Wake this person\'s desktop and run a task there.',
      available: computer != null,
    ),
  ];

  /// OpenAI `tools` array. Omit unavailable or switched-off tools.
  List<Map<String, dynamic>> get definitions => [
    if (isOn('memory_search'))
      _fn(
        'memory_search',
        "Search this person's memory. If nothing there answers the "
            'question, say you do not have it.',
        {
          'query': {'type': 'string'},
          'limit': {'type': 'integer'},
        },
        const ['query'],
      ),
    if (isOn('memory_recent'))
      _fn('memory_recent', 'Most recent memories.', {
        'limit': {'type': 'integer'},
      }),
    if (isOn('memory_get'))
      _fn(
        'memory_get',
        'Fetch one memory by id.',
        {
          'id': {'type': 'string'},
        },
        const ['id'],
      ),
    if (isOn('remember'))
      _fn(
        'remember',
        'Save a note only when the person asked you to save or remember it.',
        {
          'title': {'type': 'string'},
          'body': {'type': 'string'},
        },
        const ['title'],
      ),
    if (isOn('life_graph'))
      _fn(
        'life_graph',
        'The life graph: goals, projects, habits, entities, edges.',
      ),
    if (webAvailable && isOn('web_search'))
      _fn(
        'web_search',
        'Search the public web for news or a fact that changes. '
            'Not for arithmetic, spelling, translation, or a list you know.',
        {
          'query': {'type': 'string'},
        },
        const ['query'],
      ),
    if (isOn('now'))
      _fn(
        'now',
        'Local date and weekday, when they ask for the time or the day.',
      ),
    if (connectorsAvailable && isOn('connector'))
      _fn(
        'connector',
        'Read a connected app through One. One call, with platform and '
            'intent, is enough. The server runs the action, fills the '
            'login from the connection, and copies the rows into memory. '
            'Answer from those rows. Do not ask for an action id.',
        {
          'platform': {
            'type': 'string',
            'description': 'Connector slug from the connected apps list.',
          },
          'intent': {
            'type': 'string',
            'description': 'What to do, in words, when action_id is unknown.',
          },
          'action_id': {'type': 'string'},
          'path_params': {'type': 'object'},
          'query': {'type': 'object'},
          'body': {'type': 'object'},
        },
        const ['platform'],
      ),
    if (sync != null && isOn('sync'))
      _fn(
        'sync',
        'Queue a full pull of a connected app. This does not read the '
            'account. To say what is in it now, call connector. Omit '
            'platform to report jobs. Pass a platform, or "all", to queue '
            'the pull. A queued job has not copied anything yet.',
        {
          'platform': {
            'type': 'string',
            'description': 'Connector slug, or all. Omit to only report.',
          },
        },
      ),
    if (sessionSearch != null && isOn('session_search'))
      _fn(
        'session_search',
        'Search earlier chats for what the user said.',
        {
          'query': {'type': 'string'},
        },
        const ['query'],
      ),
    if (proposeSkill != null && isOn('skill_propose'))
      _fn(
        'skill_propose',
        'Propose a procedure. It stays inactive until the person confirms.',
        {
          'name': {'type': 'string'},
          'body': {'type': 'string'},
        },
        const ['name', 'body'],
      ),
    if (readLibrary != null && isOn('library_read'))
      _fn(
        'library_read',
        'Open one skill, file, or turn by id. The index lists the ids.',
        {
          'kind': {'type': 'string', 'description': 'skills, files, or turns'},
          'id': {'type': 'string'},
        },
        const ['kind', 'id'],
      ),
    if (createIntent != null && isOn('intent_create'))
      _fn(
        'intent_create',
        'Remember an instruction for when a phrase shows up later.',
        {
          'phrase': {'type': 'string'},
          'instruction': {'type': 'string'},
        },
        const ['phrase', 'instruction'],
      ),
    if (senses != null && isOn('file_read'))
      _fn(
        'file_read',
        'Read one public file. Images and videos are described. '
            'Use this after memory, before the web and the desktop.',
        {
          'url': {'type': 'string'},
          'ask': {'type': 'string'},
        },
        const ['url'],
      ),
    if (senses != null && isOn('image_describe'))
      _fn(
        'image_describe',
        'Describe a public image. Use after memory, before the web.',
        {
          'url': {'type': 'string'},
          'ask': {'type': 'string'},
        },
        const ['url'],
      ),
    if (senses != null && isOn('video_describe'))
      _fn(
        'video_describe',
        'Describe a public video. Use after memory, before the web.',
        {
          'url': {'type': 'string'},
          'ask': {'type': 'string'},
        },
        const ['url'],
      ),
    if (senses != null && isOn('url_read'))
      _fn(
        'url_read',
        'Read one public page as text. After memory and connectors, '
            'before computer.',
        {
          'url': {'type': 'string'},
        },
        const ['url'],
      ),
    if (vaultList != null && isOn('vault_list'))
      _fn(
        'vault_list',
        'List cred_ handles. Use a handle in a computer task. '
            'You never receive the secret.',
      ),
    if (computer != null && isOn('computer'))
      _fn(
        'computer',
        'Last resort. Wake this person\'s desktop and do a task a file, '
            'a connector, or the web cannot do. The machine is theirs: it '
            'sleeps when idle, wakes for the task, and their instabox '
            'account is billed. Name a credential by its cred_ handle.',
        {
          'task': {'type': 'string'},
        },
        const ['task'],
      ),
  ];

  Future<String> run(gel.Client c, String name, String rawArgs) async {
    final produced = await _dispatch(c, name, rawArgs);
    final clean = scrub;
    if (clean == null) return produced;
    return clean(produced);
  }

  Future<String> _dispatch(gel.Client c, String name, String rawArgs) async {
    Map<String, dynamic> args;
    try {
      final parsed = rawArgs.trim().isEmpty
          ? const <String, dynamic>{}
          : jsonDecode(rawArgs);
      args = parsed is Map<String, dynamic>
          ? parsed
          : const <String, dynamic>{};
    } on FormatException {
      args = const <String, dynamic>{};
    }
    try {
      return switch (name) {
        'now' => jsonEncode({
          'type': 'text',
          'text': readableClock(DateTime.now()),
        }),
        'memory_search' => formatMemories(
          memoriesForAsk(
            '${args['query'] ?? ''}',
            await searchMemory(
              c,
              '${args['query'] ?? ''}',
              _int(args['limit'], 8),
            ),
          ),
        ),
        'memory_recent' => formatMemories(
          await recentMemory(c, _int(args['limit'], 10)),
        ),
        'memory_get' => formatMemory(await getMemory(c, '${args['id'] ?? ''}')),
        'remember' => formatRemember(
          await remember(
            c,
            '${args['title'] ?? 'note'}',
            args['body'] as String?,
          ),
          '${args['title'] ?? 'note'}',
          args['body'] as String?,
        ),
        'life_graph' => formatGraph(await lifeGraph(c)),
        'web_search' => await _webSearch('${args['query'] ?? ''}'),
        'connector' =>
          connector == null
              ? jsonEncode({'type': 'text', 'text': 'no connected apps'})
              : await connector!(args),
        'sync' =>
          sync == null
              ? jsonEncode({'type': 'text', 'text': 'sync is off'})
              : await sync!(c, args),
        'session_search' =>
          sessionSearch == null
              ? 'session search is off'
              : jsonEncode(
                  await sessionSearch!(c, '${args['query'] ?? ''}', 8),
                ),
        'skill_propose' =>
          proposeSkill == null
              ? 'skills are off'
              : jsonEncode({
                  'id': await proposeSkill!(
                    c,
                    '${args['name'] ?? 'procedure'}',
                    '${args['body'] ?? ''}',
                  ),
                  'status': 'proposed',
                }),
        'library_read' =>
          readLibrary == null
              ? 'library is off'
              : await _readLibrary(
                  '${args['kind'] ?? ''}',
                  '${args['id'] ?? ''}',
                ),
        'intent_create' =>
          createIntent == null
              ? 'intents are off'
              : jsonEncode({
                  'id': await createIntent!(
                    c,
                    '${args['phrase'] ?? ''}',
                    '${args['instruction'] ?? ''}',
                  ),
                  'status': 'active',
                }),
        'file_read' =>
          senses == null
              ? _plain('file reading is off')
              : await senses!.readFile(
                  '${args['url'] ?? ''}',
                  ask: args['ask'] as String?,
                ),
        'image_describe' =>
          senses == null
              ? _plain('vision is off')
              : await senses!.describeImage(
                  '${args['url'] ?? ''}',
                  ask: args['ask'] as String?,
                ),
        'video_describe' =>
          senses == null
              ? _plain('vision is off')
              : await senses!.describeVideo(
                  '${args['url'] ?? ''}',
                  ask: args['ask'] as String?,
                ),
        'url_read' =>
          senses == null
              ? _plain('url reading is off')
              : await senses!.readUrl('${args['url'] ?? ''}'),
        'vault_list' =>
          vaultList == null ? _plain('vault is off') : await vaultList!(),
        'computer' =>
          computer == null
              ? _plain('the desktop is off')
              : await computer!(c, args),
        _ => 'unknown tool $name',
      };
    } on Object catch (e) {
      return 'error: $e';
    }
  }

  Future<String> _readLibrary(String kind, String id) async {
    final body = await readLibrary!(kind, id);
    if (body == null) {
      return jsonEncode({'type': 'text', 'text': 'not in the library'});
    }
    return jsonEncode({'type': 'text', 'text': body});
  }

  Future<String> _webSearch(String query) async {
    if (!webAvailable) {
      return jsonEncode({
        'type': 'text',
        'text': 'web search is not configured',
      });
    }
    final q = query.trim();
    if (q.isEmpty) {
      return jsonEncode({'type': 'text', 'text': 'query required'});
    }
    if (!youConfigured) return _openRouterSearch(q);
    final r = await _http.post(
      Uri.parse('https://ydc-index.io/v1/search'),
      headers: {'X-API-Key': youApiKey!, 'content-type': 'application/json'},
      body: jsonEncode({'query': q, 'count': 5}),
    );
    if (r.statusCode >= 400) {
      return jsonEncode({
        'type': 'text',
        'text': 'web search failed (${r.statusCode})',
      });
    }
    Object? decoded;
    try {
      decoded = jsonDecode(r.body);
    } on FormatException {
      return jsonEncode({'type': 'text', 'text': 'web search failed'});
    }
    final hits = youWebHits(decoded);
    if (hits.isEmpty) {
      return jsonEncode({'type': 'text', 'text': 'no results'});
    }
    return jsonEncode({'type': 'column', 'children': hits});
  }

  Future<String> _openRouterSearch(String query) async {
    final uri = AgentClient.completionsUri(Uri.parse(openRouterBaseUrl));
    final headers = {
      'content-type': 'application/json',
      'authorization': 'Bearer $openRouterApiKey',
      'HTTP-Referer': 'http://127.0.0.1:8090',
      'X-Title': 'Maie',
    };
    final messages = [
      {
        'role': 'user',
        'content': 'Search the public web and cite each source.\nQuery: $query',
      },
    ];
    var response = await _http.post(
      uri,
      headers: headers,
      body: jsonEncode({
        'model': openRouterModel,
        'messages': messages,
        'plugins': [
          {'id': 'web', 'max_results': 5},
        ],
        'max_tokens': 400,
      }),
    );
    if (response.statusCode == 400) {
      response = await _http.post(
        uri,
        headers: headers,
        body: jsonEncode({
          'model': openRouterModel,
          'messages': messages,
          'tools': [
            {
              'type': 'openrouter:web_search',
              'parameters': {'max_results': 5},
            },
          ],
          'max_tokens': 400,
        }),
      );
    }
    if (response.statusCode >= 400) {
      return jsonEncode({
        'type': 'text',
        'text': 'web search failed (${response.statusCode})',
      });
    }
    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      return jsonEncode({'type': 'text', 'text': 'web search failed'});
    }
    final links = linksFromOpenRouter(decoded);
    if (links.isEmpty) {
      final text = answerFromOpenRouter(decoded);
      return jsonEncode({'type': 'text', 'text': text ?? 'no results'});
    }
    return jsonEncode({'type': 'column', 'children': links});
  }

  static String formatMemories(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) {
      return jsonEncode({'type': 'text', 'text': 'no memories'});
    }
    final shown = rows.take(4);
    final timeline = {
      'type': 'timeline',
      'title': 'Memory',
      'children': [for (final row in shown) memoryPart(row)],
    };
    final markers = _markers(shown.toList());
    if (markers.isEmpty) return jsonEncode(timeline);
    return jsonEncode({
      'type': 'column',
      'children': [
        timeline,
        {'type': 'map', 'markers': markers},
      ],
    });
  }

  static String formatMemory(Map<String, dynamic>? row) {
    if (row == null) {
      return jsonEncode({'type': 'text', 'text': 'not found'});
    }
    return jsonEncode(memoryPart(row));
  }

  static String formatRemember(String id, String title, String? body) {
    return jsonEncode({
      'type': 'memory',
      'id': id,
      'title': title,
      'kind': 'note',
      'body': body ?? '',
    });
  }

  static Map<String, dynamic> memoryPart(Map<String, dynamic> row) {
    final place = row['place'];
    return {
      'type': 'memory',
      'id': '${row['id'] ?? ''}',
      'title': '${row['title'] ?? row['kind'] ?? 'memory'}',
      'kind': '${row['kind'] ?? 'note'}',
      'when': '${row['occurred_at'] ?? row['created_at'] ?? ''}',
      'body': clipSentence('${row['body'] ?? ''}'),
      if (place is Map)
        'place': {
          'type': 'place',
          'name': place['name'] ?? '',
          'city': place['city'] ?? '',
          'region': place['region'] ?? '',
          'country': place['country'] ?? '',
          if (_coord(place['lat']) != null) 'lat': _coord(place['lat']),
          if (_coord(place['lng']) != null) 'lng': _coord(place['lng']),
        },
    };
  }

  static String formatMemoryRow(Map<String, dynamic> row) =>
      jsonEncode(memoryPart(row));

  static List<Map<String, dynamic>> _markers(List<Map<String, dynamic>> rows) {
    final markers = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final row in rows) {
      final place = row['place'];
      if (place is! Map) continue;
      final lat = _coord(place['lat']);
      final lng = _coord(place['lng']);
      if (lat == null || lng == null) continue;
      final key = '${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)}';
      if (!seen.add(key)) continue;
      markers.add({
        'lat': lat,
        'lng': lng,
        'title': '${place['name'] ?? row['title'] ?? ''}',
      });
    }
    return markers;
  }

  static double? _coord(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  static String formatGraph(Map<String, dynamic>? g) {
    if (g == null) {
      return jsonEncode({'type': 'text', 'text': 'Nothing stored yet.'});
    }
    List<dynamic> listOf(String key) =>
        g[key] is List ? g[key]! as List<dynamic> : const [];
    final payload = {
      'type': 'graph',
      'goals': listOf('goals'),
      'projects': listOf('projects'),
      'habits': listOf('habits'),
      'entities': listOf('entities'),
      'edges': listOf('edges'),
    };
    final empty = payload.values.whereType<List<dynamic>>().every(
      (rows) => rows.isEmpty,
    );
    if (empty) {
      return jsonEncode({'type': 'text', 'text': 'Nothing stored yet.'});
    }
    return jsonEncode(payload);
  }

  static int _int(Object? v, int fallback) {
    if (v is int) return v.clamp(1, 40);
    if (v is num) return v.toInt().clamp(1, 40);
    return fallback;
  }

  static String _plain(String text) =>
      jsonEncode({'type': 'text', 'text': text});

  static Map<String, dynamic> _info(
    String name,
    String description, {
    bool available = true,
  }) => {'name': name, 'description': description, 'available': available};

  List<Map<String, dynamic>> catalogFor() => [
    for (final t in catalog)
      {...t, 'enabled': isOn(t['name'] as String), 'available': t['available']},
  ];

  static Map<String, dynamic> _fn(
    String name,
    String description, [
    Map<String, dynamic> properties = const {},
    List<String> required = const [],
  ]) => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': {
        'type': 'object',
        'properties': properties,
        if (required.isNotEmpty) 'required': required,
      },
    },
  };
}

/// A clock phrase a person can read. Weekday first, then the date and time.
String readableClock(DateTime time) {
  const weekdays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  const months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  final hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
  final minute = time.minute.toString().padLeft(2, '0');
  final suffix = time.hour < 12 ? 'AM' : 'PM';
  final day = weekdays[time.weekday - 1];
  final month = months[time.month - 1];
  return '$day, $month ${time.day}, ${time.year}, $hour:$minute $suffix';
}

/// One line, clipped so a source does not become the reply.
String clipSentence(String text, {int max = 140}) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.length <= max) return flat;
  return '${flat.substring(0, max - 1).trimRight()}…';
}

/// Link cards from a You.com `/v1/search` body (`results.web` and news).
List<Map<String, dynamic>> youWebHits(Object? decoded) {
  if (decoded is! Map) return const [];
  final results = decoded['results'];
  if (results is! Map) return const [];
  final links = <Map<String, dynamic>>[];
  for (final section in ['web', 'news']) {
    final rows = results[section];
    if (rows is! List) continue;
    for (final row in rows) {
      if (row is! Map) continue;
      final url = row['url'];
      if (url is! String || url.isEmpty) continue;
      final title = row['title'];
      links.add({
        'type': 'link',
        'title': title is String && title.trim().isNotEmpty
            ? title.trim()
            : url,
        'url': url,
        'snippet': clipSentence(_youSnippet(row)),
      });
      if (links.length == 3) return links;
    }
  }
  return links;
}

String _youSnippet(Map<dynamic, dynamic> row) {
  final description = row['description'];
  if (description is String && description.trim().isNotEmpty) {
    return description.trim();
  }
  final snippets = row['snippets'];
  if (snippets is List) {
    for (final snippet in snippets) {
      if (snippet is String && snippet.trim().isNotEmpty) {
        return snippet.trim();
      }
    }
  }
  return '';
}

/// Link cards from an OpenRouter chat completion that used web search.
List<Map<String, dynamic>> linksFromOpenRouter(Object? decoded) {
  final message = _openRouterMessage(decoded);
  if (message == null) return const [];
  final annotations = message['annotations'];
  if (annotations is! List) return const [];
  final links = <Map<String, dynamic>>[];
  final seen = <String>{};
  for (final item in annotations) {
    if (item is! Map) continue;
    final cite = item['url_citation'];
    if (cite is! Map) continue;
    final url = cite['url'];
    if (url is! String || url.isEmpty || !seen.add(url)) continue;
    final title = cite['title'];
    final content = cite['content'];
    links.add({
      'type': 'link',
      'title': title is String && title.trim().isNotEmpty ? title.trim() : url,
      'url': url,
      'snippet': clipSentence(content is String ? content : ''),
    });
    if (links.length == 3) break;
  }
  return links;
}

/// Assistant text from an OpenRouter completion, when there are no citations.
String? answerFromOpenRouter(Object? decoded) {
  final message = _openRouterMessage(decoded);
  final content = message?['content'];
  if (content is! String) return null;
  final text = content.trim();
  return text.isEmpty ? null : text;
}

/// What the sync tool tells the model. A created job has not copied data.
String formatSyncStatus({
  List<String> enqueued = const [],
  required List<Map<String, dynamic>> jobs,
  required List<Map<String, dynamic>> cursors,
}) {
  final etl = [
    for (final job in jobs)
      if ('${job['name']}'.startsWith('etl')) job,
  ];
  final counts = <String, int>{};
  for (final job in etl) {
    final state = '${job['state']}';
    counts[state] = (counts[state] ?? 0) + 1;
  }
  final pulling = etl
      .where((job) => job['state'] == 'active' || job['state'] == 'completed')
      .length;
  final lines = <String>[];
  if (enqueued.isNotEmpty) {
    lines.add('Queued sync for ${enqueued.join(', ')}.');
  }
  if (etl.isEmpty) {
    lines.add('No sync jobs.');
  } else {
    final bits = [
      for (final entry in counts.entries) '${entry.value} ${entry.key}',
    ];
    lines.add('Sync jobs: ${bits.join(', ')}.');
    if (pulling == 0) {
      lines.add('Nothing is pulling yet. The jobs are still queued.');
    }
  }
  final saved = [
    for (final row in cursors)
      if (row['endpoint'] == 'sync') row,
  ];
  if (saved.isEmpty) {
    lines.add('No page cursor has been saved, so a pull has not started.');
  } else {
    for (final row in saved) {
      final cursor = _cursorMap(row['cursor']);
      final mode = cursor?['mode'];
      final err = row['last_error'];
      final note = err == null || '$err'.isEmpty ? '' : ' ($err)';
      lines.add('${row['platform']}: ${mode ?? 'cursor'}$note');
    }
  }
  return lines.join('\n');
}

Map<String, dynamic>? _cursorMap(Object? raw) {
  if (raw is Map) return Map<String, dynamic>.from(raw);
  if (raw is String && raw.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } on FormatException {
      return null;
    }
  }
  return null;
}

Map<String, dynamic>? _openRouterMessage(Object? decoded) {
  if (decoded is! Map) return null;
  final choices = decoded['choices'];
  if (choices is! List || choices.isEmpty) return null;
  final first = choices.first;
  if (first is! Map) return null;
  final message = first['message'];
  if (message is! Map) return null;
  return Map<String, dynamic>.from(message);
}
