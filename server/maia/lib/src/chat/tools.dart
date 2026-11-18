import 'dart:convert';

import 'package:gel/gel.dart' as gel;
import 'package:http/http.dart' as http;
import 'package:maia_api/src/agent.dart';

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
  final http.Client _http;

  bool get youConfigured => youApiKey != null && youApiKey!.isNotEmpty;

  bool get openRouterConfigured =>
      openRouterApiKey != null && openRouterApiKey!.isNotEmpty;

  bool get webAvailable => youConfigured || openRouterConfigured;

  bool isOn(String name) => !disabled.contains(name);

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
  ];

  /// OpenAI `tools` array. Omit unavailable or switched-off tools.
  List<Map<String, dynamic>> get definitions => [
    if (isOn('memory_search'))
      _fn(
        'memory_search',
        "Search the user's personal memory.",
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
        'Save a note to memory.',
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
        'Search the public web. Returns titles, URLs and snippets.',
        {
          'query': {'type': 'string'},
        },
        const ['query'],
      ),
    if (isOn('now')) _fn('now', 'Current local date and time.'),
  ];

  Future<String> run(gel.Client c, String name, String rawArgs) async {
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
          'type': 'metric',
          'label': 'now',
          'value': DateTime.now().toIso8601String(),
        }),
        'memory_search' => formatMemories(
          await searchMemory(c, '${args['query'] ?? ''}', _int(args['limit'], 8)),
        ),
        'memory_recent' => formatMemories(
          await recentMemory(c, _int(args['limit'], 10)),
        ),
        'memory_get' => formatMemory(await getMemory(c, '${args['id'] ?? ''}')),
        'remember' => formatRemember(
          await remember(c, '${args['title'] ?? 'note'}', args['body'] as String?),
          '${args['title'] ?? 'note'}',
          args['body'] as String?,
        ),
        'life_graph' => formatGraph(await lifeGraph(c)),
        'web_search' => await _webSearch('${args['query'] ?? ''}'),
        _ => 'unknown tool $name',
      };
    } on Object catch (e) {
      return 'error: $e';
    }
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
    final r = await _http.get(
      Uri.https('api.you.com', '/v1/search', {'query': q, 'count': '5'}),
      headers: {'X-API-Key': youApiKey!},
    );
    if (r.statusCode >= 400) {
      return jsonEncode({
        'type': 'text',
        'text': 'web search failed (${r.statusCode})',
      });
    }
    final json = jsonDecode(r.body) as Map<String, dynamic>;
    final hits =
        ((json['results'] as Map<String, dynamic>?)?['web'] as List<dynamic>?) ??
        const [];
    if (hits.isEmpty) {
      return jsonEncode({'type': 'text', 'text': 'no results'});
    }
    return jsonEncode({
      'type': 'column',
      'children': [
        {'type': 'heading', 'text': q},
        for (final h in hits.take(5))
          {
            'type': 'link',
            'title': (h as Map<String, dynamic>)['title'] ?? '',
            'url': h['url'] ?? '',
            'snippet': h['description'] ?? '',
          },
      ],
    });
  }

  Future<String> _openRouterSearch(String query) async {
    final uri = AgentClient.completionsUri(Uri.parse(openRouterBaseUrl));
    final headers = {
      'content-type': 'application/json',
      'authorization': 'Bearer $openRouterApiKey',
      'HTTP-Referer': 'http://127.0.0.1:8090',
      'X-Title': 'Maia',
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
      return jsonEncode({
        'type': 'text',
        'text': text ?? 'no results',
      });
    }
    return jsonEncode({
      'type': 'column',
      'children': [
        {'type': 'heading', 'text': query},
        ...links,
      ],
    });
  }

  static String formatMemories(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) {
      return jsonEncode({'type': 'text', 'text': 'no memories'});
    }
    final timeline = {
      'type': 'timeline',
      'title': 'Memory',
      'children': [for (final row in rows) memoryPart(row)],
    };
    final markers = _markers(rows);
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
      'body': row['body'] == null
          ? ''
          : row['body'].toString().replaceAll(RegExp(r'\s+'), ' '),
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
      return jsonEncode({'type': 'text', 'text': 'empty graph'});
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
    final empty = payload.values
        .whereType<List<dynamic>>()
        .every((rows) => rows.isEmpty);
    if (empty) {
      return jsonEncode({'type': 'text', 'text': 'empty graph'});
    }
    return jsonEncode(payload);
  }

  static int _int(Object? v, int fallback) {
    if (v is int) return v.clamp(1, 40);
    if (v is num) return v.toInt().clamp(1, 40);
    return fallback;
  }

  static Map<String, dynamic> _info(
    String name,
    String description, {
    bool available = true,
  }) => {
    'name': name,
    'description': description,
    'available': available,
  };

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
      'snippet': content is String ? content : '',
    });
    if (links.length == 5) break;
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
