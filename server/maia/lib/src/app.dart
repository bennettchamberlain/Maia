import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:gel/gel.dart' as gel;
import 'package:http/http.dart' as http;
import 'package:maia_api/src/agent.dart';
import 'package:maia_api/src/auth/api_key.dart';
import 'package:maia_api/src/auth/password.dart';
import 'package:maia_api/src/chat/prefs.dart';
import 'package:maia_api/src/chat/tools.dart';
import 'package:maia_api/src/chat/turn.dart';
import 'package:maia_api/src/auth/session_token.dart';
import 'package:maia_api/src/config.dart';
import 'package:maia_api/src/db.dart';
import 'package:maia_api/src/embeddings.dart';
import 'package:maia_api/src/one/catalog.dart';
import 'package:maia_api/src/one/extract.dart';
import 'package:maia_api/src/one/done_page.dart';
import 'package:maia_api/src/faults.dart';
import 'package:maia_api/src/geocoder.dart';
import 'package:maia_api/src/parasail_embeddings.dart';
import 'package:maia_api/src/graph/graph_block.dart';
import 'package:maia_api/src/harness/harness.dart';
import 'package:maia_api/src/library/store.dart';
import 'package:maia_api/src/jobs/dream_job.dart';
import 'package:maia_api/src/queries.dart';
import 'package:maia_api/src/timeline/summary.dart';
import 'package:maia_api/src/timeline/writer.dart';
import 'package:maia_api/src/voice/supervisor.dart';
import 'package:maia_jobs/maia_jobs.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

/// The HTTP surface. Routes are thin: decode, pick the caller, run a named
/// query as that caller, encode. No authorization logic lives here.
///
/// Three kinds of caller reach this process:
/// - the Flutter app with a session token (`/auth/signin`);
/// - machines with an API key (`sk_…`): the OpenClaw memory plugin, scripts;
/// - `/chat`, which talks to OpenRouter, Gemini, Parasail, or local
///   Ollama (OpenClaw optional) and runs host tools (memory, graph,
///   You.com) on this process.
class MaiaApp {
  MaiaApp({
    required this.config,
    required this.db,
    required this.queries,
    this.jobs,
    this.embeddings,
    this.cloudEmbeddings,
    this.agent,
    this.openrouterChat,
    this.geminiChat,
    this.parasailChat,
    this.ollamaChat,
    Geocoder? geocoder,
    Password? password,
  }) : _password = password ?? const Password(),
       _tokens = SessionToken(config.sessionSecret),
       faults = FaultLog(db),
       voice = VoiceSupervisor(config),
       geocoder =
           geocoder ??
           Geocoder(
             googleApiKey: config.googleMapsApiKey,
             userAgent: config.geocodeUserAgent,
           );

  final Config config;
  final Db db;
  final FaultLog faults;
  final OneCatalog oneCatalog = OneCatalog();
  final NamedQueries queries;
  final PgBossQueue? jobs;
  final Embeddings? embeddings;
  final ParasailEmbeddings? cloudEmbeddings;
  final AgentClient? agent;
  final AgentClient? openrouterChat;
  final AgentClient? geminiChat;
  final AgentClient? parasailChat;
  final AgentClient? ollamaChat;
  final Geocoder geocoder;
  final VoiceSupervisor voice;
  final Password _password;
  final SessionToken _tokens;
  final ApiKeys _apiKeys = const ApiKeys();
  final turns = TurnLanes();

  /// hash -> (person id, resolved at). Keeps machine callers off the
  /// credential table on every request.
  final _apiKeyCache = <String, (String, DateTime)>{};

  /// First account on a fresh box. Renames leftover `admin` to `maia`
  /// and sets password `maia-admin`.
  Future<void> ensureBootstrap() async {
    const handle = 'maia';
    final hash = _password.hash('maia-admin');
    await db.service.execute(
      r'''
      update Person
      filter .handle = 'admin'
        and not exists (select Person filter .handle = <str>$handle)
      set {
        handle := <str>$handle,
        display_name := 'Maia',
        is_superadmin := true,
      }
      ''',
      {'handle': handle},
    );
    await db.service.execute(
      r'''
      insert Person {
        handle := <str>$handle,
        display_name := 'Maia',
        is_superadmin := true,
      }
      unless conflict on .handle
      ''',
      {'handle': handle},
    );
    await db.service.execute(
      r'''
      with p := assert_exists((select Person filter .handle = <str>$handle))
      insert LocalCredential {
        person := p,
        password_hash := <str>$hash,
      }
      unless conflict on .person
      ''',
      {'handle': handle, 'hash': hash},
    );
    await db.service.execute(
      r'''
      update LocalCredential
      filter .person.handle = <str>$handle
      set {
        password_hash := <str>$hash,
        rotated_at := datetime_of_statement(),
      }
      ''',
      {'handle': handle, 'hash': hash},
    );
  }

  Handler get handler => const Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(_cors)
      .addMiddleware(_guard)
      .addHandler(_router.call);

  static const _corsHeaders = {
    'access-control-allow-origin': '*',
    'access-control-allow-headers':
        'authorization, content-type, x-api-key, x-maia-internal',
    'access-control-allow-methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
  };

  static Handler _cors(Handler inner) => (Request r) async {
    if (r.method == 'OPTIONS') {
      return Response.ok('', headers: _corsHeaders);
    }
    final res = await inner(r);
    return res.change(headers: {..._corsHeaders, ...res.headers});
  };

  Router get _router => Router()
    ..get('/health', _health)
    ..post('/auth/signin', _signIn)
    ..post('/faults', _authed(_faultReport))
    ..get('/me', _authed((r, c) => _one(c, 'me')))
    ..get('/me/api-keys', _authed(_apiKeysList))
    ..post('/me/api-keys', _authed(_apiKeysCreate))
    ..delete('/me/api-keys/<id>', _authed(_apiKeysRevoke))
    ..get('/memory', _authed(_memoryFeed))
    ..get('/memory/<id>', _authed(_memoryGet))
    ..post('/memory', _authed(_memoryUpsert))
    ..post('/memory/search', _authed(_memorySearch))
    ..post('/positions', _authed(_positions))
    ..get('/places/reverse', _authed(_placesReverse))
    ..get('/places/search', _authed(_placesSearch))
    ..get('/places/recent', _authed(_placesRecent))
    ..get('/presence/overlap/<other>', _authed(_presenceOverlap))
    ..get('/jobs', _authed(_jobsList))
    ..get('/graph', _authed((r, c) => _one(c, 'graph')))
    ..get('/chat/tools', _authed(_chatTools))
    ..get('/chat/search', _authed(_sessionSearch))
    ..post('/harness/consolidate', _authed(_consolidate))
    ..post('/harness/dream', _authed(_dreamNow))
    ..get('/dreams', _authed(_dreamList))
    ..get('/intents', _authed(_intentList))
    ..post('/intents', _authed(_intentCreate))
    ..post('/skills', _authed(_skillCreate))
    ..post('/skills/<id>/confirm', _authed(_skillConfirm))
    ..post('/harness/proposals/<id>/confirm', _authed(_proposalConfirm))
    ..post('/memory/<id>/promote', _authed(_memoryPromote))
    ..post('/work', _authed(_workStart))
    ..get('/voice/status', _authed(_voiceStatus))
    ..get('/voice/live', _authed(_voiceLive))
    ..post('/voice/start', _authed(_voiceStart))
    ..post('/voice/stop', _authed(_voiceStop))
    ..post('/voice/ask', _authed(_voiceAsk))
    ..post('/voice/say', _authed(_voiceSay))
    ..put('/chat/connections/<id>', _authed(_chatConnectionPut))
    ..delete('/chat/connections/<id>', _authed(_chatConnectionDelete))
    ..get('/chat/sessions', _authed(_chatSessions))
    ..post('/chat/sessions', _authed(_chatCreate))
    ..patch('/chat/sessions/<id>', _authed(_chatRename))
    ..post('/chat/sessions/<id>/close', _authed(_chatClose))
    ..post('/chat/sessions/<id>/fork', _authed(_chatFork))
    ..delete('/chat/sessions/<id>', _authed(_chatDelete))
    ..get('/chat/sessions/<id>/messages', _authed(_chatMessages))
    ..post('/chat/sessions/<id>/messages', _authed(_chatSend))
    ..post('/chat/sessions/<id>/steer', _authed(_chatSteer))
    ..get('/library', _authed(_libraryList))
    ..get('/files', _authed(_files))
    ..post('/files', _authed(_fileCreate))
    ..post('/files/<id>/append', _authed(_fileAppend))
    ..get('/timeline', _authed(_userTimeline))
    ..get('/timelines', _authed(_timelines))
    ..get('/timelines/<id>/entries', _authed(_timelineEntries))
    ..get('/timelines/<id>/feed', _authed(_timelineFeed))
    ..get('/graph/candidates', _authed(_weaveCandidates))
    ..post('/graph/entities', _authed(_graphEntity))
    ..post('/graph/edges', _authed(_graphEdge))
    ..patch('/graph/edges/<id>', _authed(_graphEdgeStatus))
    ..get('/one/authorize', _oneProxy)
    ..post('/one/authorize', _oneProxy)
    ..get('/one/callback', _oneProxy)
    ..post('/one/callback', _oneProxy)
    ..get('/one/done', _oneDone)
    ..post('/one/connect', _authed(_oneConnect))
    ..get('/one/connectors', _authed(_oneConnectors))
    ..get('/one/grant', _authed(_oneGrantGet))
    ..put('/one/grant', _authed(_oneGrantPut))
    ..delete('/one/grant', _authed(_oneGrantDelete))
    ..post('/one/sync', _authed(_oneSync))
    ..post('/one/accounts', _authed(_oneAccount))
    ..get('/one/cursors', _authed((r, c) => _many(c, 'sync_cursor_list')))
    ..put('/one/cursors', _authed(_syncCursorPut))
    ..post('/internal/one/grant', _internal(_internalGrant))
    ..post('/admin/people', _authed(_createPerson))
    // Companion Intelligence memory-plugin contract (OpenClaw's
    // `companionintelligence` plugin speaks exactly this).
    ..get('/api/health', _health)
    ..get('/api/memory/context', _authed(_ciContext))
    ..post('/api/memory/recall', _authed(_ciRecall))
    ..post('/api/memory/write', _authed(_ciWrite))
    ..post('/api/memory/turn', _authed(_ciTurn));

  Future<Response> _health(Request r) async {
    final chat = _resolveChat();
    return _json({
      'ok': true,
      'agent': chat == null ? null : await chat.ping(),
      'chat': {
        'provider': defaultChatLabel,
        'model': chat?.model,
        'openrouter': openrouterChat != null,
        'gemini': geminiChat != null,
        'parasail': parasailChat != null,
        'ollama': ollamaChat != null,
        'gateway': agent != null,
      },
      'embeddings': embeddings != null,
      'cloud_embeddings': cloudEmbeddings != null,
      'geocoder': geocoder.provider,
      'jobs': jobs != null,
      'voice': await _voicePeek(),
    });
  }

  String get defaultChatLabel {
    final c = _resolveChat();
    if (identical(c, openrouterChat)) return 'openrouter';
    if (identical(c, geminiChat)) return 'gemini';
    if (identical(c, parasailChat)) return 'parasail';
    if (identical(c, ollamaChat)) return 'ollama';
    if (identical(c, agent)) return 'agent';
    return 'off';
  }

  // ---- auth -----------------------------------------------------------------

  Future<Response> _signIn(Request r) async {
    final body = await _body(r);
    final handle = body['handle'] as String?;
    final password = body['password'] as String?;
    if (handle == null || password == null) {
      return _error(400, 'bad_request', 'handle and password required');
    }
    final row = await db.service.querySingleJSON(
      r'''
      select assert_single((select LocalCredential {
        password_hash,
        person: { id, handle, display_name, email, is_superadmin, created_at,
                  disabled_at }
      } filter .person.handle = <str>$handle))
      ''',
      {'handle': handle},
    );
    final cred = jsonDecode(row) as Map<String, dynamic>?;
    // Same refusal for unknown handle and wrong password.
    if (cred == null ||
        !_password.verify(password, cred['password_hash'] as String)) {
      return _error(401, 'invalid_credentials', 'sign-in refused');
    }
    final person = cred['person'] as Map<String, dynamic>;
    if (person['disabled_at'] != null) {
      return _error(401, 'invalid_credentials', 'sign-in refused');
    }
    final expires = DateTime.now().toUtc().add(config.sessionTtl);
    person.remove('disabled_at');
    return _json({
      'token': _tokens.issue(person['id'] as String, expires),
      'expires_at': expires.toIso8601String(),
      'person': person,
    });
  }

  /// Session token (`Authorization: Bearer <jwt-ish>`), or an API key in
  /// either `Authorization: Bearer sk_…` or `x-api-key: sk_…`.
  Handler _authed(
    Future<Response> Function(Request r, gel.Client caller) next,
  ) {
    return (Request r) async {
      final auth = r.headers['authorization'];
      var token = auth != null && auth.startsWith('Bearer ')
          ? auth.substring(7)
          : null;
      token ??= r.headers['x-api-key'];
      if (token == null) {
        return _error(401, 'unauthorized', 'missing token');
      }
      final personId = ApiKeys.looksLikeKey(token)
          ? await _resolveApiKey(token)
          : _tokens.verify(token);
      if (personId == null) {
        return _error(401, 'unauthorized', 'missing or expired token');
      }
      return next(r, db.asPerson(personId));
    };
  }

  Handler _internal(
    Future<Response> Function(Request r, gel.Client caller) next,
  ) {
    return (Request r) async {
      final secret = config.internalSecret;
      final got = r.headers['x-maia-internal'];
      if (secret == null || got == null || got != secret) {
        return _error(401, 'unauthorized', 'internal secret required');
      }
      final b = await _body(r);
      final personId = b['person_id'] as String?;
      if (personId == null) {
        return _error(400, 'bad_request', 'person_id required');
      }
      return next(
        r.change(context: {'internal_body': b}),
        db.asPerson(personId),
      );
    };
  }

  Future<String?> _resolveApiKey(String token) async {
    final hash = _apiKeys.hash(token);
    final cached = _apiKeyCache[hash];
    if (cached != null &&
        DateTime.now().difference(cached.$2) < const Duration(minutes: 1)) {
      return cached.$1;
    }
    final row = await db.service.querySingleJSON(
      r'''
      select assert_single((select ApiKey { person: { id, disabled_at }, revoked_at }
        filter .token_hash = <str>$hash))
      ''',
      {'hash': hash},
    );
    final key = jsonDecode(row) as Map<String, dynamic>?;
    if (key == null || key['revoked_at'] != null) return null;
    final person = key['person'] as Map<String, dynamic>;
    if (person['disabled_at'] != null) return null;
    final id = person['id'] as String;
    _apiKeyCache[hash] = (id, DateTime.now());
    unawaited(
      db.service
          .execute(
            r'update ApiKey filter .token_hash = <str>$hash '
            'set { last_used_at := datetime_of_statement() }',
            {'hash': hash},
          )
          .catchError((_) {}),
    );
    return id;
  }

  Future<Response> _apiKeysList(Request r, gel.Client c) async => Response.ok(
    await c.queryJSON(
      'select ApiKey { id, label, prefix, scopes, created_at, last_used_at, '
      'revoked_at } filter not exists .revoked_at order by .created_at desc',
    ),
    headers: _jsonHeaders,
  );

  Future<Response> _apiKeysCreate(Request r, gel.Client c) async {
    final b = await _body(r);
    final label = (b['label'] as String?)?.trim();
    if (label == null || label.isEmpty) {
      return _error(400, 'bad_request', 'label required');
    }
    final minted = _apiKeys.mint();
    final json = await c.querySingleJSON(
      r'''
      select (insert ApiKey {
        person := assert_exists(global current_person),
        label := <str>$label,
        token_hash := <str>$hash,
        prefix := <str>$prefix,
        scopes := <array<str>>$scopes,
      }) { id, label, prefix, scopes, created_at }
      ''',
      {
        'label': label,
        'hash': minted.hash,
        'prefix': minted.prefix,
        'scopes':
            (b['scopes'] as List<dynamic>?)?.cast<String>() ??
            const ['memory', 'chat'],
      },
    );
    final row = jsonDecode(json) as Map<String, dynamic>;
    // The only time the token is ever returned.
    return Response(
      201,
      body: jsonEncode({...row, 'token': minted.token}),
      headers: _jsonHeaders,
    );
  }

  Future<Response> _apiKeysRevoke(Request r, gel.Client c) async {
    await c.execute(
      r'update ApiKey filter .id = <uuid>$id '
      'set { revoked_at := datetime_of_statement() }',
      {'id': r.params['id']},
    );
    _apiKeyCache.clear();
    return Response(204);
  }

  // ---- memory ---------------------------------------------------------------

  Future<Response> _memoryFeed(Request r, gel.Client c) async {
    final before = r.url.queryParameters['before'];
    final limit = int.tryParse(r.url.queryParameters['limit'] ?? '') ?? 50;
    return _many(c, 'memory_feed', {
      'before': before == null ? null : DateTime.parse(before),
      'limit': limit.clamp(1, 200),
    });
  }

  Future<Response> _memoryGet(Request r, gel.Client c) =>
      _one(c, 'memory_get', {'id': r.params['id']});

  Future<Response> _memoryUpsert(Request r, gel.Client c) async {
    final b = await _body(r);
    final id = await _upsertMemory(
      c,
      kind: b['kind'] as String? ?? 'note',
      title: b['title'] as String?,
      body: b['body'] as String?,
      occurredAt: _occurredAt(b['occurred_at']),
      source: b['source'] as String? ?? 'app',
      sourceId:
          b['source_id'] as String? ?? _digest('${b['title']}${b['body']}'),
      account: b['account'] as String?,
    );
    final full = await c.querySingleJSON(queries['memory_get'], {'id': id});
    return Response.ok(full, headers: _jsonHeaders);
  }

  DateTime _occurredAt(Object? raw) {
    if (raw is String && raw.isNotEmpty) {
      final parsed = DateTime.tryParse(raw);
      if (parsed != null) return parsed.toUtc();
      final n = int.tryParse(raw);
      if (n != null) {
        final ms = n > 10000000000 ? n : n * 1000;
        return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
      }
    }
    return DateTime.now().toUtc();
  }

  /// Insert-or-update, then embed inline when Ollama is configured (so search
  /// works the moment a memory lands) and kick the `embed` job for anything
  /// the inline pass missed.
  Future<String> _upsertMemory(
    gel.Client c, {
    required String kind,
    required String? title,
    required String? body,
    required DateTime occurredAt,
    required String source,
    required String sourceId,
    String? account,
  }) async {
    final json = await c.querySingleJSON(queries['memory_upsert'], {
      'kind': kind,
      'title': title,
      'body': body,
      'occurred_at': occurredAt,
      'source': source,
      'source_id': sourceId,
    });
    final id = (jsonDecode(json) as Map<String, dynamic>)['id'] as String;
    var embedded = false;
    var cloudEmbedded = false;
    final text = [
      if (title != null) title,
      if (body != null) body,
    ].join('\n').trim();
    if (embeddings case final emb?) {
      try {
        final vector = await emb.embed(text);
        await c.execute(
          r'''
          update MemoryItem filter .id = <uuid>$id set {
            embedding := <Embedding><array<float32>>$vector,
            embedded_at := datetime_of_statement(),
            embedding_model := <str>$model,
          }
          ''',
          {'id': id, 'vector': vector, 'model': emb.model},
        );
        embedded = true;
      } on Object {
        embedded = false;
      }
    }
    if (cloudEmbeddings case final emb?) {
      try {
        final vector = await emb.embed(text);
        await c.execute(
          r'''
          update MemoryItem filter .id = <uuid>$id set {
            embedding_cloud := <EmbeddingCloud><array<float32>>$vector,
            embedded_cloud_at := datetime_of_statement(),
            embedding_cloud_model := <str>$model,
          }
          ''',
          {'id': id, 'vector': vector, 'model': emb.model},
        );
        cloudEmbedded = true;
      } on Object {
        cloudEmbedded = false;
      }
    }
    if (!embedded || (cloudEmbeddings != null && !cloudEmbedded)) {
      await _enqueue(c, 'embed', {'memory_id': id}, subjectId: id);
    }
    await _enqueueConclude(c, id);
    await _enqueueWeave(c, id);
    try {
      await TimelineWriter.recordConnector(
        c,
        source: source,
        sourceId: sourceId,
        title: title,
        body: body,
        at: occurredAt,
        account: account,
      );
    } on Object catch (e) {
      stderr.writeln('timeline: $e');
    }
    return id;
  }

  Future<Response> _memorySearch(Request r, gel.Client c) async {
    final b = await _body(r);
    final q = b['q'] as String?;
    if (q == null || q.trim().isEmpty) {
      return _error(400, 'bad_request', 'q required');
    }
    final limit = (b['limit'] as int? ?? 20).clamp(1, 100);
    return Response.ok(
      jsonEncode(await _searchMemory(c, q, limit)),
      headers: _jsonHeaders,
    );
  }

  /// Semantic when embeddings are on, keyword otherwise. Either way the
  /// result shape is the same, so callers never care.
  Future<List<Map<String, dynamic>>> _searchMemory(
    gel.Client c,
    String q,
    int limit,
  ) async {
    if (cloudEmbeddings case final emb?) {
      try {
        final vector = await emb.embed(q);
        final rows = jsonDecode(
          await c.queryJSON(queries['memory_search_cloud'], {
            'embedding': vector,
            'limit': limit,
          }),
        ) as List<dynamic>;
        if (rows.isNotEmpty) {
          return _touched(c, rows.cast<Map<String, dynamic>>());
        }
      } on Object {
        // fall through to local
      }
    }
    if (embeddings case final emb?) {
      try {
        final vector = await emb.embed(q);
        final rows = jsonDecode(
          await c.queryJSON(queries['memory_search'], {
            'embedding': vector,
            'limit': limit,
          }),
        ) as List<dynamic>;
        if (rows.isNotEmpty) {
          return _touched(c, rows.cast<Map<String, dynamic>>());
        }
      } on Object {
        // fall through to keywords
      }
    }
    final rows = jsonDecode(
      await c.queryJSON(queries['memory_text_search'], {
        'q': q.trim(),
        'limit': limit,
      }),
    ) as List<dynamic>;
    return _touched(c, rows.cast<Map<String, dynamic>>());
  }

  List<Map<String, dynamic>> _touched(
    gel.Client c,
    List<Map<String, dynamic>> rows,
  ) {
    final ids = [
      for (final row in rows)
        if (row['id'] is String) row['id'] as String,
    ];
    unawaited(noteRecall(c, ids));
    return rows;
  }

  // ---- positions / places / presence ----------------------------------------

  Future<Response> _positions(Request r, gel.Client c) async {
    final b = await _body(r);
    final points = b['points'] as List<dynamic>? ?? const [];
    if (points.isEmpty) return _json({'inserted': 0, 'places': 0});
    // The gel client JSON-encodes `json` arguments itself; pass the value.
    final inserted = await c.query(queries['position_insert_many'], {
      'points': points,
    });
    final places = await _attachPlaces(c, points.cast<Map<String, dynamic>>());
    await _enqueue(c, 'derive-presence', {
      'count': inserted.length,
    }, options: const SendOptions(singletonKey: 'presence'));
    return _json({'inserted': inserted.length, 'places': places});
  }

  /// Resolves the cells these points fall in to `Place`s (cache first, then
  /// the geocoder), links the positions, and upserts `Presence` per
  /// (day, place). Bounded to a handful of lookups per batch because
  /// Nominatim allows one request a second.
  Future<int> _attachPlaces(
    gel.Client c,
    List<Map<String, dynamic>> points,
  ) async {
    final byCell = <String, List<Map<String, dynamic>>>{};
    for (final p in points) {
      final lat = (p['lat'] as num).toDouble();
      final lng = (p['lng'] as num).toDouble();
      byCell.putIfAbsent(Geocoder.gridKey(lat, lng), () => []).add(p);
    }
    var resolved = 0;
    for (final entry in byCell.entries.take(6)) {
      final sample = entry.value.first;
      final lat = (sample['lat'] as num).toDouble();
      final lng = (sample['lng'] as num).toDouble();
      final place = await _placeFor(c, lat, lng);
      if (place == null) continue;
      resolved++;
      final placeId = place['id'] as String;
      const half = 0.0006; // ~65 m, matches the 3-decimal grid
      await c.execute(
        r'''
        update Position
        filter .owner.id = global current_person_id and not exists .place
          and .lat >= <float64>$lat0 and .lat <= <float64>$lat1
          and .lng >= <float64>$lng0 and .lng <= <float64>$lng1
        set { place := assert_exists((select Place filter .id = <uuid>$place)) }
        ''',
        {
          'lat0': lat - half,
          'lat1': lat + half,
          'lng0': lng - half,
          'lng1': lng + half,
          'place': placeId,
        },
      );
      // Presence: one row per (day, place).
      final byDay = <String, List<DateTime>>{};
      for (final p in entry.value) {
        final at = DateTime.parse(p['at'] as String).toUtc();
        byDay
            .putIfAbsent(at.toIso8601String().substring(0, 10), () => [])
            .add(at);
      }
      for (final d in byDay.entries) {
        d.value.sort();
        await c.execute(
          r'''
          insert Presence {
            owner := assert_exists(global current_person),
            day := <cal::local_date><str>$day,
            place := assert_exists((select Place filter .id = <uuid>$place)),
            first_seen := <datetime>$first,
            last_seen := <datetime>$last,
            sample_count := <int32>$n,
          }
          unless conflict on ((.owner, .day, .place))
          else (
            update Presence set {
              first_seen := min({.first_seen, <datetime>$first}),
              last_seen := max({.last_seen, <datetime>$last}),
              sample_count := .sample_count + <int32>$n,
              updated_at := datetime_of_statement(),
            }
          )
          ''',
          {
            'day': d.key,
            'place': placeId,
            'first': d.value.first,
            'last': d.value.last,
            'n': d.value.length,
          },
        );
      }
    }
    return resolved;
  }

  /// A `Place` within ~65 m of the point: an existing row if we have one,
  /// otherwise a fresh geocode. Null when the geocoder has nothing.
  Future<Map<String, dynamic>?> _placeFor(
    gel.Client c,
    double lat,
    double lng,
  ) async {
    const half = 0.0006;
    final hit = await c.querySingleJSON(
      r'''
      select assert_single((select Place { id, name, city, region, country, lat, lng }
        filter .lat >= <float64>$lat0 and .lat <= <float64>$lat1
           and .lng >= <float64>$lng0 and .lng <= <float64>$lng1
        order by (math::abs(.lat - <float64>$lat) + math::abs(.lng - <float64>$lng)) asc
        limit 1))
      ''',
      {
        'lat0': lat - half,
        'lat1': lat + half,
        'lng0': lng - half,
        'lng1': lng + half,
        'lat': lat,
        'lng': lng,
      },
    );
    if (hit != 'null') return jsonDecode(hit) as Map<String, dynamic>;
    final GeoPlace? geo;
    try {
      geo = await geocoder.reverse(lat, lng);
    } on Object {
      return null;
    }
    if (geo == null) return null;
    return _storePlace(c, geo, snapTo: (lat, lng));
  }

  /// Insert the geocoder's answer, or return the row that already has this
  /// provider id. `snapTo` records the queried coordinate rather than the
  /// provider's centroid so the ~65 m cache lookup finds it again.
  Future<Map<String, dynamic>> _storePlace(
    gel.Client c,
    GeoPlace geo, {
    (double, double)? snapTo,
  }) async {
    final json = await c.querySingleJSON(
      r'''
      select (
        insert Place {
          name := <str>$name,
          city := <optional str>$city,
          region := <optional str>$region,
          country := <optional str>$country,
          lat := <float64>$lat,
          lng := <float64>$lng,
          provider := <str>$provider,
          provider_id := <str>$provider_id,
        }
        unless conflict on ((.provider, .provider_id))
        else (select Place)
      ) { id, name, city, region, country, lat, lng }
      ''',
      {
        ...geo.toJson(),
        if (snapTo != null) ...{'lat': snapTo.$1, 'lng': snapTo.$2},
      },
    );
    return jsonDecode(json) as Map<String, dynamic>;
  }

  Future<Response> _placesReverse(Request r, gel.Client c) async {
    final lat = double.tryParse(r.url.queryParameters['lat'] ?? '');
    final lng = double.tryParse(r.url.queryParameters['lng'] ?? '');
    if (lat == null || lng == null) {
      return _error(400, 'bad_request', 'lat and lng required');
    }
    final place = await _placeFor(c, lat, lng);
    return place == null
        ? _error(404, 'not_found', 'no place for that point')
        : _json(place);
  }

  Future<Response> _placesSearch(Request r, gel.Client c) async {
    final q = r.url.queryParameters['q']?.trim();
    if (q == null || q.isEmpty) return _error(400, 'bad_request', 'q required');
    final results = await geocoder.search(q);
    final stored = <Map<String, dynamic>>[];
    for (final g in results) {
      stored.add(await _storePlace(c, g));
    }
    return _json(stored);
  }

  Future<Response> _placesRecent(Request r, gel.Client c) {
    final days = int.tryParse(r.url.queryParameters['days'] ?? '') ?? 30;
    return _many(c, 'places_recent', {
      'since': _localDate(
        DateTime.now().toUtc().subtract(Duration(days: days)),
      ),
      'limit': 200,
    });
  }

  Future<Response> _presenceOverlap(Request r, gel.Client c) =>
      _many(c, 'presence_overlap', {'other': r.params['other']});

  // ---- jobs -----------------------------------------------------------------

  Future<Response> _jobsList(Request r, gel.Client c) {
    final states = r.url.queryParameters['states']?.split(',');
    final limit = int.tryParse(r.url.queryParameters['limit'] ?? '') ?? 100;
    return _many(c, 'jobs_list', {
      'states': states,
      'limit': limit.clamp(1, 500),
    });
  }

  // ---- chat -----------------------------------------------------------------

  AgentClient? _resolveChat([String? want]) {
    final pick = (want ?? config.chatProvider).trim().toLowerCase();
    return switch (pick) {
      'openrouter' => openrouterChat,
      'gemini' => geminiChat,
      'parasail' => parasailChat,
      'ollama' => ollamaChat,
      'agent' => agent,
      _ => openrouterChat ?? geminiChat ?? parasailChat ?? ollamaChat ?? agent,
    };
  }

  ToolPrefsStore get _prefsStore => ToolPrefsStore(
    Directory('${config.hackathonRoot ?? Directory.current.path}/.secrets'),
  );

  ChatToolbox _toolboxFor(
    ToolPrefs prefs, {
    String? personId,
    String? sourceMessageId,
    bool connectors = false,
    String toolset = 'memory',
  }) => ChatToolbox(
    searchMemory: _searchMemory,
    recentMemory: (c, limit) async {
      final rows = jsonDecode(
        await c.queryJSON(queries['memory_feed'], {
          'before': null,
          'limit': limit,
        }),
      ) as List<dynamic>;
      return rows.cast<Map<String, dynamic>>();
    },
    getMemory: (c, id) async {
      if (id.isEmpty) return null;
      final row = await c.querySingleJSON(queries['memory_get'], {'id': id});
      if (row == 'null') return null;
      return jsonDecode(row) as Map<String, dynamic>;
    },
    remember: (c, title, body) => _upsertMemory(
      c,
      kind: 'note',
      title: title,
      body: body,
      occurredAt: DateTime.now().toUtc(),
      source: 'chat',
      sourceId: _digest(
        'chat:$title:$body:${DateTime.now().toIso8601String()}',
      ),
    ),
    lifeGraph: (c) async {
      final row = await c.querySingleJSON(queries['graph']);
      if (row == 'null') return null;
      return jsonDecode(row) as Map<String, dynamic>;
    },
    youApiKey: prefs.youKey ?? config.youApiKey,
    openRouterApiKey: config.openrouterApiKey,
    openRouterBaseUrl: config.openrouterBaseUrl,
    openRouterModel: config.openrouterChatModel,
    disabled: prefs.disabled,
    allow: toolset == 'work' ? workToolset : memoryToolset,
    connector: connectors && personId != null
        ? (args) => _useConnector(personId, args)
        : null,
    sessionSearch: (c, query, limit) => searchSessions(c, query, limit: limit),
    proposeSkill: (c, name, body) async {
      final id = await proposeSkill(
        c,
        name: name,
        body: body,
        messageId: sourceMessageId,
      );
      await _upsertMemory(
        c,
        kind: 'skill',
        title: name,
        body: body,
        occurredAt: DateTime.now().toUtc(),
        source: 'skill',
        sourceId: id,
      );
      return id;
    },
    createIntent: (c, phrase, instruction) =>
        createIntent(c, phrase: phrase, instruction: instruction),
    readLibrary: personId == null
        ? null
        : (kind, id) async {
            final body = await _library.read(
              personId: personId,
              kind: kind,
              id: id,
            );
            if (body != null && kind == 'files') {
              await _noteDocumentUse(db.asPerson(personId), id);
            }
            return body;
          },
  );

  Future<String> _useConnector(
    String personId,
    Map<String, dynamic> args,
  ) async {
    final platform = '${args['platform'] ?? ''}'.trim();
    if (platform.isEmpty) {
      return jsonEncode({'type': 'text', 'text': 'platform required'});
    }
    try {
      final res = await http
          .post(
            Uri.parse('${config.connectSidecarUrl}/api/one/act'),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({
              'person': personId,
              'platform': platform,
              'intent': args['intent'],
              'actionId': args['action_id'],
              'pathParams': args['path_params'],
              'query': args['query'],
              'body': args['body'],
              'encoding': args['encoding'],
              'headers': args['headers'],
            }),
          )
          .timeout(const Duration(seconds: 45));
      return _connectorResult(personId, platform, res.statusCode, res.body);
    } on Object catch (e) {
      return jsonEncode({'type': 'text', 'text': 'connector unavailable: $e'});
    }
  }

  Future<String> _connectorResult(
    String personId,
    String platform,
    int status,
    String body,
  ) async {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      decoded = null;
    }
    if (decoded is! Map) {
      return jsonEncode({
        'type': 'text',
        'text': 'One could not read $platform.',
      });
    }
    final map = Map<String, dynamic>.from(decoded);
    if (status >= 400 || map['error'] != null) {
      final error = '${map['error'] ?? 'failed'}';
      final text = error == 'reconnect_required'
          ? '$platform needs a reconnect in One.'
          : 'One could not read $platform ($error).';
      return jsonEncode({'type': 'text', 'text': text});
    }
    if (map['actions'] is List && map['data'] == null) {
      return jsonEncode({
        'type': 'text',
        'text': connectorActionPrompt(platform, map['actions']),
      });
    }
    if (map['ok'] != true || map['data'] == null) {
      final refusal = '${map['refusal'] ?? ''}'.trim();
      final text = refusal.isEmpty
          ? 'One returned nothing from $platform.'
          : 'One refused $platform ($refusal).';
      return jsonEncode({'type': 'text', 'text': text});
    }
    final rows = connectorCopies(platform, map['data']);
    if (rows.isEmpty) {
      return jsonEncode({
        'type': 'text',
        'text': 'One returned nothing to copy from $platform.',
      });
    }
    final caller = db.asPerson(personId);
    var copied = 0;
    for (final row in rows) {
      try {
        await _upsertMemory(
          caller,
          kind: row.kind,
          title: row.title,
          body: row.body,
          occurredAt: row.at,
          source: 'one:$platform',
          sourceId: row.sourceId,
        );
        copied++;
      } on Object catch (e) {
        stderr.writeln('connector: $e');
      }
    }
    final lines = [for (final row in rows) '- ${row.title}'];
    return jsonEncode({
      'type': 'text',
      'text': 'Copied $copied $platform rows into memory.\n${lines.join('\n')}',
    });
  }

  Future<List<String>> _connectedPlatforms(gel.Client c) async {
    try {
      final personId = await _personId(c);
      if (personId == null) return const [];
      final grant = await _grantMap(c);
      if (grant == null || grant['revoked_at'] != null) return const [];
      final view = await _oneAccountView(c, personId, grant);
      return [
        for (final row in view)
          if (row['platform'] != null && row['platform'].toString().isNotEmpty)
            row['platform'].toString(),
      ];
    } on Object {
      return const [];
    }
  }

  Future<String?> _personId(gel.Client c) async {
    final row = await c.querySingleJSON('select global current_person { id }');
    if (row == 'null') return null;
    return (jsonDecode(row) as Map<String, dynamic>)['id'] as String?;
  }

  Future<Response> _chatTools(Request r, gel.Client c) async {
    final personId = await _personId(c);
    final prefs = personId == null
        ? const ToolPrefs()
        : await _prefsStore.read(personId);
    final grantJson = await c.querySingleJSON(queries['one_grant_get']);
    final grant = grantJson == 'null'
        ? null
        : jsonDecode(grantJson) as Map<String, dynamic>;
    final oneUser = grant?['one_user_id'] as String? ?? '';
    final oneLive =
        grant != null &&
        grant['revoked_at'] == null &&
        oneUser.isNotEmpty &&
        !oneUser.startsWith('local:');
    final oneReady = await _connectReady();
    final accounts = oneLive && personId != null
        ? await _oneAccountView(c, personId, grant!)
        : const <Map<String, dynamic>>[];
    final box = _toolboxFor(
      prefs,
      personId: personId,
      connectors: accounts.isNotEmpty,
    );
    final youOn = box.webAvailable;
    final accountCount = accounts.length;
    final accountLabel = accountCount == 1
        ? '1 account connected'
        : '$accountCount accounts connected';
    return _json({
      'default_provider': defaultChatLabel,
      'providers': {
        'openrouter': {
          'available': openrouterChat != null,
          'model': openrouterChat?.model,
        },
        'gemini': {'available': geminiChat != null, 'model': geminiChat?.model},
        'parasail': {
          'available': parasailChat != null,
          'model': parasailChat?.model,
        },
        'ollama': {'available': ollamaChat != null, 'model': ollamaChat?.model},
        'agent': {'available': agent != null, 'model': agent?.model},
      },
      'tools': box.catalogFor(),
      'connections': [
        {
          'id': 'you',
          'label': 'You.com',
          'kind': 'key',
          'connected': youOn,
          'has_secret': youOn,
          'description':
              'Web search for the agent. Paste a You.com key or keep the '
              'server key from .env.',
        },
        {
          'id': 'one',
          'label': 'One Connect',
          'kind': 'oauth',
          'connected': oneLive,
          'ready': oneReady,
          'platforms': [for (final account in accounts) account['platform']],
          'accounts': accounts,
          'account_count': accountCount,
          'connected_at': oneLive ? grant!['connected_at'] : null,
          'authorize_url': personId == null
              ? null
              : '/one/authorize?person=$personId',
          'description': !oneReady
              ? 'One Connect is not configured. Create an app at '
                    'app.withone.ai/developers/connect and set ONE_CLIENT_ID '
                    'and ONE_CONNECT_KEY. Nothing is linked until you sign in there.'
              : oneLive
              ? '$accountLabel. One keeps the login. '
                    'The grant stays until you revoke it, so Maia does not '
                    'refresh a token. Each pull is checked against that grant.'
              : 'Sign in with One, then connect Slack, Linear, Gmail, or any '
                    'other app. Maia only lists accounts you actually grant.',
        },
        {
          'id': 'openrouter',
          'label': 'OpenRouter',
          'kind': 'inference',
          'connected': openrouterChat != null,
          'model': openrouterChat?.model,
          'description':
              'OpenRouter for chat. Set OPENROUTER_API_KEY on the server.',
        },
        {
          'id': 'gemini',
          'label': 'Gemini',
          'kind': 'inference',
          'connected': geminiChat != null,
          'model': geminiChat?.model,
          'description': 'Google Gemini for chat. Set GOOGLE_GEMINI_API_KEY on the server.',
        },
        {
          'id': 'parasail',
          'label': 'Parasail',
          'kind': 'inference',
          'connected': parasailChat != null,
          'model': parasailChat?.model,
          'description':
              'Cloud brain for chat. Set PARASAIL_API_KEY on the server.',
        },
        {
          'id': 'ollama',
          'label': 'Ollama',
          'kind': 'inference',
          'connected': ollamaChat != null,
          'model': ollamaChat?.model,
          'description': 'Local model on this machine.',
        },
        {
          'id': 'voice',
          'label': 'PersonaVoice',
          'kind': 'speech',
          ...await _voiceConnection(),
        },
      ],
    });
  }

  Future<Response> _chatConnectionPut(Request r, gel.Client c) async {
    final personId = await _personId(c);
    if (personId == null) return _error(401, 'unauthorized', 'no person');
    final id = r.params['id']!;
    final b = await _body(r);
    var prefs = await _prefsStore.read(personId);
    if (id == 'you') {
      final key = b['api_key'] as String?;
      if (key != null) prefs = prefs.copyWith(youKey: key);
      if (b['enabled'] is bool) {
        prefs = _setEnabled(prefs, 'web_search', b['enabled'] as bool);
      }
    } else if (id == 'one' ||
        id == 'openrouter' ||
        id == 'gemini' ||
        id == 'parasail' ||
        id == 'ollama' ||
        id == 'voice') {
      return _error(400, 'bad_request', 'use the dedicated action for $id');
    } else {
      if (b['enabled'] is! bool) {
        return _error(400, 'bad_request', 'enabled required');
      }
      prefs = _setEnabled(prefs, id, b['enabled'] as bool);
    }
    await _prefsStore.write(personId, prefs);
    return _chatTools(r, c);
  }

  Future<Response> _chatConnectionDelete(Request r, gel.Client c) async {
    final personId = await _personId(c);
    if (personId == null) return _error(401, 'unauthorized', 'no person');
    final id = r.params['id']!;
    if (id != 'you') {
      return _error(400, 'bad_request', 'can only clear the You.com key');
    }
    final prefs = await _prefsStore.read(personId);
    await _prefsStore.write(personId, prefs.copyWith(clearYouKey: true));
    return _chatTools(r, c);
  }

  static ToolPrefs _setEnabled(ToolPrefs prefs, String name, bool on) {
    final next = {...prefs.disabled};
    if (on) {
      next.remove(name);
    } else {
      next.add(name);
    }
    return prefs.copyWith(disabled: next);
  }

  Future<Response> _chatSessions(Request r, gel.Client c) =>
      _many(c, 'chat_sessions', {'limit': 100});

  Future<Response> _chatCreate(Request r, gel.Client c) async {
    final b = await _body(r);
    final json = await c.querySingleJSON(
      r'''
      select (insert ChatSession {
        owner := assert_exists(global current_person),
        title := <optional str>$title,
      }) {
        id, title, title_locked, topics, agent_session_key, created_at,
        last_message_at, first_message_at := min(.messages.created_at),
        message_count := 0
      }
      ''',
      {'title': (b['title'] as String?)?.trim()},
    );
    return Response(201, body: json, headers: _jsonHeaders);
  }

  Future<Response> _chatDelete(Request r, gel.Client c) async {
    await c.execute(r'delete ChatSession filter .id = <uuid>$id', {
      'id': r.params['id'],
    });
    return Response(204);
  }

  Future<Response> _chatRename(Request r, gel.Client c) async {
    final b = await _body(r);
    final title = (b['title'] as String?)?.trim();
    if (title == null || title.isEmpty) {
      return _error(400, 'bad_request', 'title required');
    }
    final id = r.params['id']!;
    await c.execute(
      r'''
      update ChatSession filter .id = <uuid>$id set {
        title := <str>$title,
        title_locked := true,
      }
      ''',
      {'id': id, 'title': title},
    );
    try {
      await TimelineWriter.renameSpans(c, sessionId: id, title: title);
      await _touchChat(c, id);
    } on Object catch (e) {
      stderr.writeln('timeline: $e');
    }
    return _sessionResponse(c, id);
  }

  Future<Response> _chatClose(Request r, gel.Client c) async {
    final id = r.params['id']!;
    final raw = jsonDecode(
      await c.querySingleJSON(
        r'''
        select ChatSession {
          id,
          title,
          title_locked,
          summarized_through_seq,
          messages: {
            id, role, content, seq, created_at, tool_calls,
          } order by .seq,
        }
        filter .id = <uuid>$id
        ''',
        {'id': id},
      ),
    );
    if (raw is! Map<String, dynamic>) {
      return _error(404, 'not_found', 'no such chat');
    }
    final messages = (raw['messages'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
    final latest = messages.isEmpty ? 0 : (messages.last['seq'] as num).toInt();
    final times = [
      for (final message in messages)
        if (DateTime.tryParse('${message['created_at']}') case final at?) at,
    ];
    final calls = <Map<String, dynamic>>[
      for (final message in messages) ..._toolCallMaps(message['tool_calls']),
    ];
    String? modelText;
    final summarized = (raw['summarized_through_seq'] as num?)?.toInt() ?? 0;
    final harness = _resolveChat(null);
    if (harness != null && latest > summarized) {
      try {
        final transcript = _transcript(messages);
        modelText = await harness.complete([
          {'role': 'system', 'content': sessionSummaryPrompt},
          {'role': 'user', 'content': transcript},
        ]);
      } on Object {
        modelText = null;
      }
    }
    final plan = planSessionClose(
      titleLocked: raw['title_locked'] == true,
      summarizedThrough: summarized,
      latestSeq: latest,
      modelText: modelText,
      times: times,
      toolCalls: calls,
    );
    if (plan.apply) {
      final title = plan.title ?? raw['title'] as String?;
      await c.execute(
        r'''
        update ChatSession filter .id = <uuid>$id set {
          title := <optional str>$title,
          topics := <array<str>>$topics,
          summarized_through_seq := <int32>$seq,
        }
        ''',
        {'id': id, 'title': title, 'topics': plan.topics, 'seq': latest},
      );
      final spanStart = plan.startedAt ?? DateTime.now().toUtc();
      final spanEnd = plan.endedAt ?? spanStart;
      try {
        await TimelineWriter.applySession(
          c,
          sessionId: id,
          title: title,
          topics: plan.topics,
          started: spanStart,
          ended: spanEnd,
          connectors: plan.connectors,
        );
      } on Object catch (e) {
        stderr.writeln('timeline: $e');
      }
      final summary = [
        if (title != null) title,
        ...plan.topics,
        _transcript(messages),
      ].join('\n');
      await _upsertMemory(
        c,
        kind: 'session',
        title: title,
        body: summary.length > 6000 ? summary.substring(0, 6000) : summary,
        occurredAt: spanEnd,
        source: 'chat-session',
        sourceId: id,
      );
      final wording = harnessWording(title, plan.topics);
      if (wording.isNotEmpty) {
        try {
          final proposal = await recordHarnessProposal(
            c,
            sessionId: id,
            wording: wording,
          );
          await _upsertMemory(
            c,
            kind: 'note',
            title: title ?? 'Harness line',
            body: wording,
            occurredAt: spanEnd,
            source: 'harness-proposal',
            sourceId: proposal,
          );
        } on Object catch (e) {
          stderr.writeln('harness: $e');
        }
      }
    }
    try {
      await scorePreviousProposal(
        c,
        sessionId: id,
        score: proposalScore(calls),
      );
    } on Object catch (e) {
      stderr.writeln('harness: $e');
    }
    return _sessionResponse(c, id);
  }

  Future<Response> _chatFork(Request r, gel.Client c) async {
    final b = await _body(r);
    final messageId = (b['message_id'] as String?)?.trim();
    if (messageId == null || messageId.isEmpty) {
      return _error(400, 'bad_request', 'message_id required');
    }
    final sessionId = r.params['id']!;
    final listed = jsonDecode(
      await c.queryJSON(queries['chat_messages'], {
        'session': sessionId,
        'limit': 500,
      }),
    );
    if (listed is! List) return _error(404, 'not_found', 'no such chat');
    final messages = listed.cast<Map<String, dynamic>>();
    final through = messagesThrough(messages, messageId);
    if (through.isEmpty) {
      return _error(404, 'not_found', 'no such message');
    }
    final selection = (b['selection'] as String?)?.trim() ?? '';
    var seed = selection;
    if (seed.isEmpty) {
      Map<String, dynamic>? userLine;
      for (final message in through) {
        if (message['role'] == 'user') {
          userLine = message;
          break;
        }
      }
      seed = (userLine ?? through.first)['content'] as String? ?? 'Fork';
    }
    final created = jsonDecode(
      await c.querySingleJSON(
        r'''
        select (
          insert ChatSession {
            owner := assert_exists(global current_person),
            title := <optional str>$title,
            forked_from := assert_single((
              select ChatMessage filter .id = <uuid>$message
            )),
          }
        ) { id }
        ''',
        {'title': titleFromPassage(seed), 'message': messageId},
      ),
    );
    if (created is! Map || created['id'] is! String) {
      return _error(500, 'fork_failed', 'could not fork');
    }
    final id = created['id'] as String;
    for (final message in through) {
      await _appendMessage(
        c,
        id,
        message['role'] as String? ?? 'user',
        message['content'] as String? ?? '',
        toolCalls: _toolCallMaps(message['tool_calls']),
        model: message['model'] as String?,
      );
    }
    final whole = (through.last['content'] as String?)?.trim() ?? '';
    if (selection.isNotEmpty && selection != whole) {
      await _appendMessage(c, id, 'quote', selection);
    }
    try {
      await _touchChat(c, id);
    } on Object catch (e) {
      stderr.writeln('timeline: $e');
    }
    return _sessionResponse(c, id, status: 201);
  }

  PersonLibrary get _library =>
      PersonLibrary(Directory('${config.dataDir}/library'));

  Future<Response> _libraryList(Request r, gel.Client c) async {
    final personId = await _personId(c);
    if (personId == null) return _json(LibrarySnapshot.empty.toJson());
    final index = await _sessionIndex(c, personId);
    return _json({
      ..._library.snapshot(personId).toJson(),
      if (index.isNotEmpty) 'index': index,
    });
  }

  Future<String> _sessionIndex(gel.Client c, String personId) async {
    try {
      await _mirrorLibrary(c, personId);
      final titles = <String>[];
      final raw = jsonDecode(
        await c.queryJSON(queries['user_timeline'], {'limit': 8}),
      );
      if (raw is List) {
        for (final row in raw) {
          if (row is Map && row['title'] is String) {
            titles.add(row['title'] as String);
          }
        }
      }
      return loadIndex(_library.snapshot(personId), timeline: titles);
    } on Object catch (e) {
      stderr.writeln('library: $e');
      return '';
    }
  }

  Future<void> _mirrorLibrary(gel.Client c, String personId) async {
    for (final skill in await activeSkills(c)) {
      final id = skill['id'];
      if (id is! String) continue;
      await _library.putIfAbsent(
        personId: personId,
        kind: 'skills',
        id: id,
        name: '${skill['name'] ?? ''}',
        body: '${skill['body'] ?? ''}',
      );
    }
    final docs = jsonDecode(
      await c.queryJSON(queries['documents'], {'limit': 40}),
    );
    if (docs is! List) return;
    for (final doc in docs) {
      if (doc is! Map) continue;
      final id = doc['id'];
      if (id is! String) continue;
      await _library.putIfAbsent(
        personId: personId,
        kind: 'files',
        id: id,
        name: '${doc['title'] ?? 'Untitled'}',
        body: '${doc['body'] ?? ''}',
      );
      final uses = (doc['use_count'] as num?)?.toInt();
      if (uses != null) {
        _library.setUses(personId: personId, id: id, uses: uses);
      }
    }
  }

  Future<void> _noteDocumentUse(gel.Client c, String id) async {
    if (!_uuid.hasMatch(id)) return;
    try {
      await c.execute(
        r'''
        update Document filter .id = <uuid>$id set {
          use_count := .use_count + 1,
          last_opened_at := datetime_of_statement(),
        }
        ''',
        {'id': id},
      );
    } on Object catch (e) {
      stderr.writeln('library: $e');
    }
  }

  Future<Response> _files(Request r, gel.Client c) =>
      _many(c, 'documents', {'limit': 100});

  Future<Response> _fileCreate(Request r, gel.Client c) async {
    final b = await _body(r);
    final body = (b['body'] as String?)?.trim();
    if (body == null || body.isEmpty) {
      return _error(400, 'bad_request', 'body required');
    }
    final requested = (b['title'] as String?)?.trim();
    final title = requested == null || requested.isEmpty
        ? titleFromPassage(body)
        : requested;
    final now = DateTime.now().toUtc();
    final citation = fileCitation(
      sessionId: b['session_id'] as String?,
      messageId: b['message_id'] as String?,
      at: now,
    );
    final stored = appendPassage(body: '', passage: body, citation: citation);
    final created = jsonDecode(
      await c.querySingleJSON(
        r'''
        select (
          insert Document {
            owner := assert_exists(global current_person),
            title := <str>$title,
            body := <str>$body,
            use_count := 1,
            last_opened_at := datetime_of_statement(),
          }
        ) { id, title, body, created_at }
        ''',
        {'title': title, 'body': stored},
      ),
    );
    if (created is! Map || created['id'] is! String) {
      return _error(500, 'file_failed', 'could not create file');
    }
    final id = created['id'] as String;
    final owner = await _personId(c);
    if (owner != null) {
      await _library.write(
        personId: owner,
        kind: 'files',
        id: id,
        name: title,
        body: stored,
        bump: true,
      );
    }
    await _upsertMemory(
      c,
      kind: 'file',
      title: title,
      body: stored,
      occurredAt: now,
      source: 'file',
      sourceId: id,
    );
    try {
      await TimelineWriter.recordFile(
        c,
        documentId: id,
        title: title,
        body: stored,
        started: now,
        ended: now,
      );
    } on Object catch (e) {
      stderr.writeln('timeline: $e');
    }
    return Response(201, body: jsonEncode(created), headers: _jsonHeaders);
  }

  Future<Response> _fileAppend(Request r, gel.Client c) async {
    final b = await _body(r);
    final text = (b['text'] as String?)?.trim();
    if (text == null || text.isEmpty) {
      return _error(400, 'bad_request', 'text required');
    }
    final id = r.params['id']!;
    final existing = jsonDecode(
      await c.querySingleJSON(
        r'''
        select Document { id, title, body, created_at }
        filter .id = <uuid>$id
        ''',
        {'id': id},
      ),
    );
    if (existing is! Map<String, dynamic>) {
      return _error(404, 'not_found', 'no such file');
    }
    final now = DateTime.now().toUtc();
    final body = appendPassage(
      body: existing['body'] as String? ?? '',
      passage: text,
      citation: fileCitation(
        sessionId: b['session_id'] as String?,
        messageId: b['message_id'] as String?,
        at: now,
      ),
    );
    final updated = jsonDecode(
      await c.querySingleJSON(
        r'''
        select (
          update Document filter .id = <uuid>$id set {
            body := <str>$body,
            use_count := .use_count + 1,
            last_opened_at := datetime_of_statement(),
            updated_at := datetime_of_statement(),
          }
        ) { id, title, body, created_at }
        ''',
        {'id': id, 'body': body},
      ),
    );
    final title = existing['title'] as String? ?? 'Untitled';
    final owner = await _personId(c);
    if (owner != null) {
      await _library.write(
        personId: owner,
        kind: 'files',
        id: id,
        name: title,
        body: body,
        bump: true,
      );
    }
    await _upsertMemory(
      c,
      kind: 'file',
      title: title,
      body: body,
      occurredAt: now,
      source: 'file',
      sourceId: id,
    );
    final started = DateTime.tryParse('${existing['created_at']}') ?? now;
    try {
      await TimelineWriter.recordFile(
        c,
        documentId: id,
        title: title,
        body: body,
        started: started,
        ended: now,
      );
    } on Object catch (e) {
      stderr.writeln('timeline: $e');
    }
    return Response.ok(jsonEncode(updated), headers: _jsonHeaders);
  }

  Future<Response> _userTimeline(Request r, gel.Client c) async {
    try {
      await TimelineWriter.backfillSessions(c);
    } on Object catch (e) {
      stderr.writeln('timeline: $e');
    }
    final meta = await c.querySingleJSON(queries['user_timeline_meta']);
    final entries = await c.queryJSON(queries['user_timeline'], {'limit': 200});
    final timeline = meta == 'null' ? null : jsonDecode(meta);
    return _json({'timeline': timeline, 'entries': jsonDecode(entries)});
  }

  Future<Response> _timelines(Request r, gel.Client c) =>
      _many(c, 'timelines', {'limit': 100});

  Future<Response> _timelineEntries(Request r, gel.Client c) {
    final after = r.url.queryParameters['after'];
    final parsed = after == null ? null : DateTime.tryParse(after);
    return _many(c, 'timeline_entries', {
      'timeline': r.params['id'],
      'after': parsed ?? DateTime.utc(1970),
      'limit': 200,
    });
  }

  /// Newest first, for the memory page. Agents keep the ascending cursor.
  Future<Response> _timelineFeed(Request r, gel.Client c) {
    final limit = int.tryParse(r.url.queryParameters['limit'] ?? '') ?? 200;
    return _many(c, 'timeline_feed', {
      'timeline': r.params['id'],
      'limit': limit.clamp(1, 200),
    });
  }

  Future<Response> _sessionResponse(
    gel.Client c,
    String id, {
    int status = 200,
  }) async {
    final json = await c.querySingleJSON(
      r'''
      select ChatSession {
        id,
        title,
        title_locked,
        topics,
        agent_session_key,
        created_at,
        last_message_at,
        first_message_at := min(.messages.created_at),
        message_count := count(.messages),
      }
      filter .id = <uuid>$id
      ''',
      {'id': id},
    );
    if (json == 'null') return _error(404, 'not_found', 'no such chat');
    return Response(status, body: json, headers: _jsonHeaders);
  }

  Future<void> _touchChat(gel.Client c, String sessionId) async {
    try {
      await TimelineWriter.touchSession(c, sessionId);
    } on Object catch (e) {
      stderr.writeln('timeline: $e');
    }
  }

  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  static List<Map<String, dynamic>> _toolCallMaps(Object? raw) {
    var value = raw;
    if (value is String && value.isNotEmpty) {
      try {
        value = jsonDecode(value);
      } on FormatException {
        return const [];
      }
    }
    if (value is! List) return const [];
    return [
      for (final item in value)
        if (item is Map) Map<String, dynamic>.from(item),
    ];
  }

  static String _transcript(List<Map<String, dynamic>> messages) {
    final lines = <String>[
      for (final message in messages)
        if (message['role'] == 'user' || message['role'] == 'assistant')
          '${message['role']}: ${message['content']}',
    ];
    final text = lines.join('\n');
    return text.length > 12000 ? text.substring(text.length - 12000) : text;
  }

  Future<Response> _chatMessages(Request r, gel.Client c) =>
      _many(c, 'chat_messages', {'session': r.params['id'], 'limit': 500});

  /// One turn. Stores the user message, streams the harness reply as SSE
  /// (`delta`, `tool`, `done`, `error` events), stores the assistant
  /// message when the stream ends. Host tools run for Parasail / Ollama.
  Future<Response> _chatSend(Request r, gel.Client c) async {
    final b = await _body(r);
    final harness = _resolveChat(b['provider'] as String?);
    if (harness == null) {
      return _error(
        503,
        'agent_unavailable',
        'No chat model. Set OPENROUTER_API_KEY, GOOGLE_GEMINI_API_KEY, PARASAIL_API_KEY, or OLLAMA_URL.',
      );
    }
    final sessionId = r.params['id']!;
    final content = (b['content'] as String?)?.trim();
    if (content == null || content.isEmpty) {
      return _error(400, 'bad_request', 'content required');
    }
    final sessionJson = await c.querySingleJSON(
      r'''
      select assert_single((select ChatSession { id, title, agent_session_key,
        person := .owner { handle, display_name } }
        filter .id = <uuid>$id))
      ''',
      {'id': sessionId},
    );
    if (sessionJson == 'null') return _error(404, 'not_found', 'no such chat');
    final session = jsonDecode(sessionJson) as Map<String, dynamic>;
    final person = session['person'] as Map<String, dynamic>;

    final userMsg = await _appendMessage(c, sessionId, 'user', content);
    if (session['title'] == null) {
      await c.execute(
        r'update ChatSession filter .id = <uuid>$id set { title := <str>$t }',
        {'id': sessionId, 't': _titleFrom(content)},
      );
    }

    // What the harness sees. OpenClaw keeps its own transcript per `user`,
    // so it gets the system frame and the new turn only.
    final personId = await _personId(c);
    final hostTools = !harness.keepsOwnHistory;
    final platforms = hostTools
        ? await _connectedPlatforms(c)
        : const <String>[];
    final toolset = b['toolset'] == 'work' ? 'work' : 'memory';
    final extra = hostTools
        ? harnessContext(
            compaction: await _folded(c, sessionId),
            intents: matchingIntents(await activeIntents(c), content),
            skills: await activeSkills(c),
            library: personId == null ? null : await _sessionIndex(c, personId),
          )
        : '';
    final frame = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': chatPrompt(
          name: '${person['display_name'] ?? person['handle']}',
          handle: '${person['handle']}',
          now: DateTime.now(),
          screen: b['screen'] as String?,
          connectors: platforms,
          extra: extra,
        ),
      },
    ];
    if (harness.keepsOwnHistory) {
      frame.add({'role': 'user', 'content': content});
    } else {
      final history = jsonDecode(
        await c.queryJSON(queries['chat_messages'], {
          'session': sessionId,
          'limit': 60,
        }),
      ) as List<dynamic>;
      final split = splitForCompaction(history.cast<Map<String, dynamic>>());
      for (final m in split.kept) {
        frame.add({'role': m['role'], 'content': m['content']});
      }
    }

    final out = StreamController<List<int>>();
    void emit(String event, Object data) {
      if (out.isClosed) return;
      out.add(utf8.encode('event: $event\ndata: ${jsonEncode(data)}\n\n'));
    }

    final lane = turns.begin(sessionId);
    lane.onStored = (message) => emit('user', message);
    unawaited(() async {
      emit('user', userMsg);
      try {
        final turn = await runChatTurn(
          harness: harness,
          frame: frame,
          toolbox: hostTools
              ? _toolboxFor(
                  await _prefsStore.read(personId ?? ''),
                  personId: personId,
                  sourceMessageId: userMsg['id'] as String?,
                  connectors: platforms.isNotEmpty,
                  toolset: toolset,
                )
              : null,
          db: c,
          emit: emit,
          user: 'conv:${session['agent_session_key']}',
          steer: lane.take,
        );
        final reply = turn.text.trim();
        final assistant = await _appendMessage(
          c,
          sessionId,
          'assistant',
          reply.isEmpty ? '(no reply)' : reply,
          toolCalls: turn.tools.isEmpty ? null : turn.tools,
          model: turn.model,
        );
        emit('done', {'message': assistant});
        await _touchChat(c, sessionId);
      } on Object catch (e, st) {
        final person = await _personId(c);
        final summary = 'The reply did not finish. Try again.';
        final ref = await faults.write(
          kind: 'server',
          action: 'chat send',
          summary: summary,
          detail: '$e\n$st',
          route: r.requestedUri.path,
          client: r.headers['user-agent'],
          personId: person,
        );
        emit('error', {
          'message': ref == null ? summary : '$summary Reference $ref.',
        });
      } finally {
        turns.end(sessionId, lane);
        await out.close();
      }
    }());

    return Response.ok(
      out.stream,
      headers: const {
        'content-type': 'text/event-stream',
        'cache-control': 'no-cache',
        'connection': 'keep-alive',
        'x-accel-buffering': 'no',
      },
      context: const {'shelf.io.buffer_output': false},
    );
  }

  Future<Map<String, dynamic>> _appendMessage(
    gel.Client c,
    String sessionId,
    String role,
    String content, {
    List<Map<String, dynamic>>? toolCalls,
    String? model,
  }) async {
    final json = await c.querySingleJSON(
      r'''
      with
        s := assert_exists((select ChatSession filter .id = <uuid>$session)),
        next := (max(s.messages.seq) ?? 0) + 1,
        m := (insert ChatMessage {
          owner := assert_exists(global current_person),
          session := s,
          role := <str>$role,
          content := <str>$content,
          tool_calls := <optional json>$tool_calls,
          model := <optional str>$model,
          seq := <int32>next,
        }),
        _ := (update s set { last_message_at := m.created_at })
      select m { id, role, content, tool_calls, model, seq, created_at }
      ''',
      {
        'session': sessionId,
        'role': role,
        'content': content,
        'tool_calls': toolCalls,
        'model': model,
      },
    );
    return jsonDecode(json) as Map<String, dynamic>;
  }

  Future<String> _folded(gel.Client c, String sessionId) async {
    final listed = jsonDecode(
      await c.queryJSON(queries['chat_messages'], {
        'session': sessionId,
        'limit': 80,
      }),
    );
    if (listed is! List) return '';
    final split = splitForCompaction(listed.cast<Map<String, dynamic>>());
    final stored = await sessionCompaction(c, sessionId);
    final previous = '${stored?['compaction'] ?? ''}';
    if (split.older.isEmpty) return previous;
    final through = (split.older.last['seq'] as num?)?.toInt() ?? 0;
    final already = (stored?['compacted_through_seq'] as num?)?.toInt() ?? 0;
    if (through <= already && previous.isNotEmpty) return previous;
    final text = extractiveCompaction(split.older);
    if (text.isEmpty) return previous;
    await storeCompaction(
      c,
      sessionId: sessionId,
      text: text,
      throughSeq: through,
    );
    return text;
  }

  Future<Response> _sessionSearch(Request r, gel.Client c) async {
    final q = r.url.queryParameters['q']?.trim() ?? '';
    if (q.isEmpty) return _error(400, 'bad_request', 'q required');
    return _json({'messages': await searchSessions(c, q)});
  }

  Future<Response> _consolidate(Request r, gel.Client c) async =>
      _json(await consolidate(c));

  Future<Response> _dreamNow(Request r, gel.Client c) async {
    final key = config.youApiKey;
    final out = await dream(
      c,
      search: key == null || key.isEmpty
          ? null
          : (topic) => youResearch(key, topic),
    );
    final owner = await _personId(c);
    if (owner != null) {
      final topics = out['topics'];
      final named = topics is List ? topics.join(', ') : '';
      await _library.write(
        personId: owner,
        kind: 'turns',
        id: 'night-${dreamDay(DateTime.now())}',
        name: 'Night',
        body: 'Proposed ${out['proposed']} curated rows. Researched $named.',
      );
    }
    return _json(out);
  }

  Future<Response> _dreamList(Request r, gel.Client c) async =>
      _json({'dreams': await recentDreams(c)});

  Future<Response> _intentList(Request r, gel.Client c) async =>
      _json({'intents': await activeIntents(c)});

  Future<Response> _intentCreate(Request r, gel.Client c) async {
    final b = await _body(r);
    final phrase = (b['phrase'] as String?)?.trim() ?? '';
    final instruction = (b['instruction'] as String?)?.trim() ?? '';
    if (phrase.isEmpty || instruction.isEmpty) {
      return _error(400, 'bad_request', 'phrase and instruction required');
    }
    final id = await createIntent(c, phrase: phrase, instruction: instruction);
    return _json({'id': id, 'status': 'active'});
  }

  Future<Response> _skillCreate(Request r, gel.Client c) async {
    final b = await _body(r);
    final name = (b['name'] as String?)?.trim() ?? '';
    final body = (b['body'] as String?)?.trim() ?? '';
    if (name.isEmpty || body.isEmpty) {
      return _error(400, 'bad_request', 'name and body required');
    }
    final id = await proposeSkill(c, name: name, body: body);
    return _json({'id': id, 'status': 'proposed'});
  }

  Future<Response> _skillConfirm(Request r, gel.Client c) async {
    final ok = await confirmSkill(c, r.params['id']!);
    if (!ok) return _error(404, 'not_found', 'no proposed skill');
    final owner = await _personId(c);
    if (owner != null) {
      final row = await c.querySingleJSON(
        r'''
        select Skill { id, name, body }
        filter .id = <uuid>$id
        ''',
        {'id': r.params['id']},
      );
      if (row != 'null') {
        final skill = jsonDecode(row) as Map<String, dynamic>;
        await _library.write(
          personId: owner,
          kind: 'skills',
          id: '${skill['id']}',
          name: '${skill['name'] ?? ''}',
          body: '${skill['body'] ?? ''}',
        );
      }
    }
    return _json({'ok': true});
  }

  Future<Response> _proposalConfirm(Request r, gel.Client c) async {
    final ok = await confirmHarnessProposal(c, r.params['id']!);
    if (!ok) return _error(404, 'not_found', 'no proposed harness line');
    return _json({'ok': true});
  }

  Future<Response> _memoryPromote(Request r, gel.Client c) async {
    final ok = await promoteMemory(c, r.params['id']!);
    if (!ok) return _error(404, 'not_found', 'no proposed memory');
    return _json({'ok': true, 'tier': 'curated'});
  }

  Future<Response> _workStart(Request r, gel.Client c) async {
    final b = await _body(r);
    final goal = (b['goal'] as String?)?.trim() ?? '';
    if (goal.isEmpty) return _error(400, 'bad_request', 'goal required');
    final id = await createWork(c, goal);
    final personId = await _personId(c);
    if (personId != null) unawaited(_runWork(personId, id, goal));
    return _json({'id': id, 'state': 'created'});
  }

  Future<void> _runWork(String personId, String id, String goal) async {
    final caller = db.asPerson(personId);
    final model = _resolveChat(null);
    if (model == null) {
      await finishWork(caller, id: id, result: 'No chat model.', ok: false);
      return;
    }
    final prefs = await _prefsStore.read(personId);
    final platforms = await _connectedPlatforms(caller);
    final box = _toolboxFor(
      prefs,
      personId: personId,
      connectors: platforms.isNotEmpty,
      toolset: 'work',
    );
    final index = await _sessionIndex(caller, personId);
    try {
      final turn = await runChatTurn(
        harness: model,
        frame: [
          {
            'role': 'system',
            'content':
                'Do this piece of work with the work tools. '
                'Save a note only if the person would want it kept.'
                '${index.isEmpty ? '' : '\n\n$index'}',
          },
          {'role': 'user', 'content': goal},
        ],
        toolbox: box,
        db: caller,
        emit: (String _, Object _) {},
      );
      final text = turn.text.trim();
      final result = text.isEmpty ? '(no result)' : text;
      await finishWork(caller, id: id, result: result, ok: true);
      await _recordTurn(personId, id, goal, result);
    } on Object catch (e) {
      await finishWork(caller, id: id, result: '$e', ok: false);
      await _recordTurn(personId, id, goal, '$e');
    }
  }

  Future<void> _recordTurn(
    String personId,
    String id,
    String name,
    String body,
  ) async {
    try {
      await _library.write(
        personId: personId,
        kind: 'turns',
        id: id,
        name: name,
        body: body,
      );
    } on Object catch (e) {
      stderr.writeln('library: $e');
    }
  }

  Future<Response> _chatSteer(Request r, gel.Client c) async {
    final lane = turns.current(r.params['id']!);
    if (lane == null) {
      return _error(409, 'no_turn', 'No reply is in progress.');
    }
    final b = await _body(r);
    final content = (b['content'] as String?)?.trim();
    if (content == null || content.isEmpty) {
      return _error(400, 'bad_request', 'content required');
    }
    final userMsg = await _appendMessage(c, r.params['id']!, 'user', content);
    lane.offer(content, stored: userMsg);
    return _json({'steered': true, 'message': userMsg});
  }

  static String _titleFrom(String content) {
    final oneLine = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length <= 60 ? oneLine : '${oneLine.substring(0, 57)}…';
  }

  // ---- Companion Intelligence memory-plugin contract -----------------------

  /// L0 profile block: who the user is, where they have been, what is recent.
  Future<Response> _ciContext(Request r, gel.Client c) async {
    final me = jsonDecode(
      await c.querySingleJSON(queries['me']),
    ) as Map<String, dynamic>?;
    final recent = jsonDecode(
      await c.queryJSON(queries['memory_feed'], {'before': null, 'limit': 8}),
    ) as List<dynamic>;
    final places = jsonDecode(
      await c.queryJSON(queries['places_recent'], {
        'since': _localDate(
          DateTime.now().toUtc().subtract(const Duration(days: 14)),
        ),
        'limit': 12,
      }),
    ) as List<dynamic>;
    final lines = <String>[
      '# Maia memory profile',
      if (me != null)
        'User: ${me['display_name'] ?? me['handle']} (handle ${me['handle']})',
      'Now: ${DateTime.now().toIso8601String()}',
    ];
    if (places.isNotEmpty) {
      lines.add('Recent places (last 14 days):');
      for (final p in places.cast<Map<String, dynamic>>()) {
        final place = p['place'] as Map<String, dynamic>;
        lines.add(
          '- ${p['day']}: ${place['name']}'
          '${place['city'] != null ? ', ${place['city']}' : ''}',
        );
      }
    }
    if (recent.isNotEmpty) {
      lines.add('Recent memories:');
      for (final m in recent.cast<Map<String, dynamic>>()) {
        lines.add(_memoryLine(m));
      }
    }
    final graph = await _lifeGraph(c);
    if (graph.isNotEmpty) lines.add(graph);
    return _json({'block': lines.join('\n')});
  }

  Future<Response> _ciRecall(Request r, gel.Client c) async {
    final b = await _body(r);
    final q = (b['query'] as String?)?.trim();
    if (q == null || q.isEmpty) return _json({'block': ''});
    final limit = (b['maxResults'] as int? ?? 8).clamp(1, 20);
    final rows = await _searchMemory(c, q, limit);
    final block = rows.isEmpty
        ? 'No memories matched "$q".'
        : rows.map(_memoryLine).join('\n');
    return _json({'block': block, 'count': rows.length});
  }

  Future<Response> _ciWrite(Request r, gel.Client c) async {
    final b = await _body(r);
    final content = (b['content'] as String?)?.trim();
    if (content == null || content.isEmpty) {
      return _error(400, 'bad_request', 'content required');
    }
    final id = await _upsertMemory(
      c,
      kind: 'note',
      title: (b['title'] as String?)?.trim() ?? _titleFrom(content),
      body: content,
      occurredAt: DateTime.now().toUtc(),
      source: (b['source'] as String?) ?? 'openclaw',
      sourceId: _digest(content),
    );
    return _json({'ok': true, 'id': id});
  }

  /// Passive capture: the plugin posts each completed exchange. Stored as
  /// one `conversation` memory per exchange, deduped by content hash.
  Future<Response> _ciTurn(Request r, gel.Client c) async {
    final b = await _body(r);
    final messages = (b['messages'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>()
        .where((m) => m['role'] == 'user' || m['role'] == 'assistant')
        .toList();
    if (messages.isEmpty) return _json({'ok': true, 'stored': 0});
    final platform = b['platform'] as String? ?? 'openclaw';
    final sessionId = b['sessionId'] as String? ?? '';
    final transcript = messages
        .map((m) => '${m['role']}: ${(m['content'] as String).trim()}')
        .join('\n\n');
    final firstUser = messages.firstWhere(
      (m) => m['role'] == 'user',
      orElse: () => messages.first,
    );
    final id = await _upsertMemory(
      c,
      kind: 'conversation',
      title: _titleFrom(firstUser['content'] as String),
      body: transcript,
      occurredAt: DateTime.now().toUtc(),
      source: 'openclaw:$platform',
      sourceId: _digest('$sessionId\n$transcript'),
    );
    return _json({'ok': true, 'stored': 1, 'id': id});
  }

  static String _memoryLine(Map<String, dynamic> m) {
    final when = (m['occurred_at'] as String).substring(0, 10);
    final body = (m['body'] as String?)?.replaceAll(RegExp(r'\s+'), ' ');
    final snippet = body == null
        ? ''
        : ': ${body.length > 220 ? '${body.substring(0, 217)}…' : body}';
    final place = m['place'] as Map<String, dynamic>?;
    final where = place == null ? '' : ' @ ${place['name']}';
    return '- [$when ${m['kind']}] ${m['title'] ?? '(untitled)'}$where$snippet';
  }

  // ---- One Connect + weave graph -------------------------------------------

  Future<Map<String, dynamic>?> _voicePeek() => voice.peek();

  Future<Map<String, dynamic>> _voiceConnection() async {
    final remote = await _voicePeek();
    final brain = remote?['brain'] is Map
        ? Map<String, dynamic>.from(remote!['brain'] as Map)
        : const <String, dynamic>{};
    final engine = remote?['engine'] is Map
        ? Map<String, dynamic>.from(remote!['engine'] as Map)
        : const <String, dynamic>{};
    if (remote?['provider'] == 'polargrid') {
      return {
        'connected': true,
        'ready': true,
        'model': 'personaplex',
        'description':
            'PolarGrid PersonaPlex. Talk opens the call. The key stays '
            'on this server.',
      };
    }
    final loaded = engine['loaded'] == true;
    final loading = engine['loading'] == true;
    final model = brain['model'] as String?;
    final keep = remote?['keep_until'] as String?;
    final polarDown = config.polargridApiKey != null && remote == null;
    return {
      'connected': remote != null,
      'ready': loaded,
      'model': model,
      'connected_at': keep,
      'description': remote == null
          ? polarDown
                ? 'PolarGrid is down. Press Talk to start PersonaPlex on '
                      'this machine, or keep chatting without it.'
                : 'Local mouth and ears. Press Start — this machine loads '
                      'PersonaPlex and keeps it warm for six hours. Chat still '
                      'speaks on the phone without it.'
          : loading
          ? 'Loading weights. First start is the long one; after that it '
                'stays resident for six hours.'
          : loaded
          ? 'Warm'
                '${keep == null ? '' : ' until $keep'}'
                '${model == null ? '' : ' · $model'}.'
          : 'Sidecar is up. Press Load to put PersonaPlex on the GPU.',
    };
  }

  Future<Response> _voiceStatus(Request r, gel.Client c) async {
    final remote = await _voicePeek();
    return _json({
      'available': remote != null,
      'url': config.voiceUrl,
      if (remote != null) ...remote,
    });
  }

  Future<Response> _voiceLive(Request r, gel.Client _) async {
    if (await voice.polarReachable()) {
      return voice.polar.handle(r);
    }
    return _error(
      503,
      'voice_unavailable',
      voice.polar.enabled
          ? 'PolarGrid is down. Start local PersonaPlex or keep chatting.'
          : 'Voice is not live.',
    );
  }

  Future<Response> _voiceStart(Request r, gel.Client c) async {
    try {
      return _json(await voice.start());
    } on StateError catch (e) {
      return _error(503, 'voice_unavailable', e.message);
    }
  }

  Future<Response> _voiceStop(Request r, gel.Client c) async {
    return _json(await voice.stop());
  }

  Future<Response> _voiceAsk(Request r, gel.Client c) async {
    final b = await _body(r);
    final text = (b['text'] as String?)?.trim() ?? '';
    if (text.isEmpty) return _error(400, 'bad_request', 'text required');
    if (await voice.polarReachable()) return _polarSay(text);
    return _voicePost('/api/ask', {'text': text});
  }

  Future<Response> _voiceSay(Request r, gel.Client c) async {
    final b = await _body(r);
    final text = (b['text'] as String?)?.trim() ?? '';
    if (text.isEmpty) return _error(400, 'bad_request', 'text required');
    if (await voice.polarReachable()) return _polarSay(text);
    return _voicePost('/api/say', {
      'text': text,
      'interrupt': b['interrupt'] == true,
    });
  }

  Response _polarSay(String text) => _json({
    'ok': true,
    'provider': 'polargrid',
    'spoken': voice.polar.say(text),
  });

  Future<Response> _voicePost(String path, Map<String, dynamic> body) async {
    try {
      final res = await http
          .post(
            Uri.parse('${config.voiceUrl}$path'),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 60));
      return Response(res.statusCode, body: res.body, headers: _jsonHeaders);
    } on Object {
      return _error(
        503,
        'voice_unavailable',
        'PersonaVoice is not running on ${config.voiceUrl}',
      );
    }
  }

  Future<bool> _connectReady() async {
    try {
      final r = await http
          .get(Uri.parse('${config.connectSidecarUrl}/health'))
          .timeout(const Duration(seconds: 2));
      if (r.statusCode != 200) return false;
      final body = jsonDecode(r.body);
      return body is Map && body['connect'] == true;
    } on Object {
      return false;
    }
  }

  /// Browser hits the same host as the Flutter API (usually forwarded 8090).
  /// We pass the OAuth dance through to the Connect sidecar on loopback.
  ///
  /// One's local redirect is HTTP (`127.0.0.1:8090/one/callback`). The
  /// state cookie is SameSite=Lax and only Secure on https, so the
  /// callback completes in dev without TLS.
  Future<Response> _oneProxy(Request r) async {
    final action = r.url.pathSegments.isEmpty
        ? 'authorize'
        : r.url.pathSegments.last;
    final public = r.requestedUri;
    final target = Uri.parse('${config.connectSidecarUrl}/api/one/$action')
        .replace(query: public.query);
    try {
      final req = http.Request(r.method, target)
        ..followRedirects = false
        ..headers.addAll({
          'accept': r.headers['accept'] ?? '*/*',
          'x-forwarded-proto': public.scheme,
          'x-forwarded-host': public.authority,
          if (r.headers['content-type'] != null)
            'content-type': r.headers['content-type']!,
          if (r.headers['cookie'] != null) 'cookie': r.headers['cookie']!,
        })
        ..bodyBytes = await r.read().fold<List<int>>(
          <int>[],
          (a, b) => a..addAll(b),
        );
      final res = await req.send().timeout(const Duration(seconds: 30));
      final bytes = await res.stream.toBytes();
      final cookies = [
        for (final cookie in _oneSplitCookies(
          res.headersSplitValues['set-cookie'] ?? const <String>[],
        ))
          _oneCookieForBrowser(cookie, public),
      ];
      final location = _oneLocationForBrowser(res.headers['location'], public);
      return Response(
        res.statusCode,
        body: bytes,
        headers: {
          if (res.headers['content-type'] != null)
            'content-type': res.headers['content-type']!,
          if (location != null) 'location': location,
          if (cookies.isNotEmpty) 'set-cookie': cookies,
        },
      );
    } on Object catch (e) {
      return Response(
        503,
        body:
            '<!doctype html><meta charset="utf-8"><title>One Connect</title>'
            '<body style="font:16px/1.4 system-ui;max-width:36rem;margin:3rem auto">'
            '<h1>One Connect is not reachable</h1>'
            '<p>Maia could not reach the Connect sidecar. '
            'This is not a 8788 link — stay on this host. $e</p></body>',
        headers: const {'content-type': 'text/html; charset=utf-8'},
      );
    }
  }

  Iterable<String> _oneSplitCookies(Iterable<String> raw) sync* {
    final next = RegExp(r',(?=[A-Za-z0-9_]+=)');
    for (final cookie in raw) {
      yield* cookie.split(next);
    }
  }

  String _oneCookieForBrowser(String cookie, Uri public) {
    var out = cookie.replaceAll('Path=/api/one', 'Path=/one');
    if (public.scheme != 'https') {
      out = out.replaceAll(RegExp(r';\s*Secure\b', caseSensitive: false), '');
    }
    return out;
  }

  String? _oneLocationForBrowser(String? location, Uri public) {
    if (location == null || location.isEmpty) return null;
    final uri = Uri.tryParse(location);
    if (uri == null || !uri.hasScheme) return location;
    final sidecar = Uri.parse(config.connectSidecarUrl);
    if (uri.host != sidecar.host || uri.port != sidecar.port) return location;
    return uri
        .replace(
          scheme: public.scheme,
          host: public.host,
          port: public.hasPort ? public.port : null,
        )
        .toString();
  }

  Future<Response> _oneConnectors(Request r, gel.Client c) async {
    try {
      return _json(await oneCatalog.snapshot());
    } on Object catch (e, st) {
      final summary = 'The connector list is not available right now.';
      final ref = await faults.write(
        kind: 'server',
        action: 'one connectors',
        summary: summary,
        detail: '$e\n$st',
        route: r.requestedUri.path,
        client: r.headers['user-agent'],
        personId: await _personId(c),
      );
      return _error(502, 'catalog_unavailable', summary, ref: ref);
    }
  }

  /// Opens One's hosted page. A [platform] focuses that one connector.
  Future<Response> _oneConnect(Request r, gel.Client c) async {
    final personId = await _personId(c);
    if (personId == null) return _error(401, 'unauthorized', 'no person');
    if (!await _connectReady()) {
      return _json({
        'mode': 'unconfigured',
        'message':
            'One Connect needs ONE_CLIENT_ID and ONE_CONNECT_KEY from '
            'app.withone.ai/developers/connect. No accounts are linked yet.',
      });
    }
    final b = await _body(r);
    final platform = (b['platform'] as String?)?.trim();
    final slug = platform == null || platform.isEmpty
        ? ''
        : Uri.encodeComponent(platform);
    final focus = slug.isEmpty ? '' : '&connector=$slug#one_connector=$slug';
    return _json({
      'mode': 'oauth',
      'authorize_url': '/one/authorize?person=$personId$focus',
    });
  }

  Future<void> _enqueueEtl(
    gel.Client c,
    String personId,
    List<String> platforms,
  ) async {
    final token = _jobToken(personId);
    for (final platform in platforms) {
      await _enqueue(c, 'etl', {
        'person_id': personId,
        'platform': platform,
        'token': token,
      }, options: SendOptions(singletonKey: '$personId:$platform'));
    }
  }

  /// Short-lived bearer so a background job writes as this person.
  /// Napalm policies still apply. The jobs page stores no token.
  String _jobToken(String personId) => _tokens.issue(
    personId,
    DateTime.now().toUtc().add(const Duration(hours: 6)),
  );

  Future<Response> _oneGrantGet(Request r, gel.Client c) =>
      _one(c, 'one_grant_get');

  Future<Response> _oneGrantPut(Request r, gel.Client c) async {
    final personId = await _personId(c);
    if (personId == null) return _error(401, 'unauthorized', 'no person');
    final b = await _body(r);
    final userId = _connectReference(b);
    if (userId == null) {
      return _error(400, 'bad_request', 'one_user_id required');
    }
    final platforms = (b['platforms'] as List<dynamic>? ?? const [])
        .map((e) => e.toString())
        .toList();
    final json = await c.querySingleJSON(
      queries['one_grant_upsert'],
      _grantArgs(b, userId: userId, platforms: platforms),
    );
    await _enqueueEtl(c, personId, platforms);
    return Response.ok(json, headers: _jsonHeaders);
  }

  Future<Response> _oneGrantDelete(Request r, gel.Client c) async {
    await c.execute(r'''
      update OneGrant
      filter .owner = global current_person
      set { revoked_at := datetime_of_statement() }
      ''');
    return _json({'ok': true});
  }

  Future<Response> _internalGrant(Request r, gel.Client c) async {
    final b =
        (r.context['internal_body'] as Map<String, dynamic>?) ?? await _body(r);
    if (b['revoked'] == true) return _oneGrantDelete(r, c);
    if (b['lookup'] == true) return _oneGrantGet(r, c);
    final userId = _connectReference(b);
    if (userId == null) {
      return _error(400, 'bad_request', 'one_user_id required');
    }
    final platforms = b.containsKey('platforms')
        ? (b['platforms'] as List<dynamic>? ?? const [])
              .map((e) => e.toString())
              .toList()
        : _platformList((await _grantMap(c))?['platforms']);
    final personId = b['person_id'] as String?;
    final json = await c.querySingleJSON(
      queries['one_grant_upsert'],
      _grantArgs(b, userId: userId, platforms: platforms),
    );
    if (b.containsKey('connections')) {
      await _rememberPlatformGrants(c, b['connections']);
    }
    if (personId != null && platforms.isNotEmpty) {
      await _enqueueEtl(c, personId, platforms);
    }
    return Response.ok(json, headers: _jsonHeaders);
  }

  Future<Response> _oneSync(Request r, gel.Client c) async {
    final personId = await _personId(c);
    if (personId == null) return _error(401, 'unauthorized', 'no person');
    final b = await _body(r);
    final requested = b['platforms'] as List<dynamic>?;
    final platforms = requested == null
        ? await _syncingPlatforms(c, personId)
        : requested
              .map((e) => e.toString())
              .where((p) => p.isNotEmpty)
              .toList();
    if (platforms.isEmpty) {
      return _error(409, 'not_connected', 'no One accounts to sync');
    }
    await _enqueueEtl(c, personId, platforms);
    return _json({'enqueued': platforms});
  }

  /// Turn syncing for one platform on or off. Adding a platform One has
  /// not granted yet returns the hosted connect URL for that connector.
  Future<Response> _oneAccount(Request r, gel.Client c) async {
    final personId = await _personId(c);
    if (personId == null) return _error(401, 'unauthorized', 'no person');
    final b = await _body(r);
    final platform = (b['platform'] as String?)?.trim().toLowerCase() ?? '';
    if (platform.isEmpty) {
      return _error(400, 'bad_request', 'platform required');
    }
    final syncing = b['syncing'] != false;
    final grant = await _grantMap(c);
    final oneUser = grant?['one_user_id'] as String? ?? '';
    final real =
        grant != null &&
        grant['revoked_at'] == null &&
        oneUser.isNotEmpty &&
        !oneUser.startsWith('local:');
    final ignored = await _ignoredPlatforms(c);
    if (!syncing) {
      ignored.add(platform);
      await _writeIgnored(c, ignored);
      if (real) {
        final platforms = _platformList(grant!['platforms'])..remove(platform);
        await _saveGrantPlatforms(c, grant!, platforms);
      }
      return _json({'ok': true, 'platform': platform, 'syncing': false});
    }
    ignored.remove(platform);
    await _writeIgnored(c, ignored);
    final live = real ? await _liveOneAccounts(personId) : null;
    final granted = live?.any((row) => row['platform'] == platform) ?? false;
    if (!real || !granted) {
      if (!await _connectReady()) {
        return _json({
          'mode': 'unconfigured',
          'message':
              'One Connect needs ONE_CLIENT_ID and ONE_CONNECT_KEY before '
              'a new account can be added.',
        });
      }
      return _json({
        'mode': 'oauth',
        'authorize_url':
            '/one/authorize?person=$personId&connector=${Uri.encodeComponent(platform)}#one_connector=${Uri.encodeComponent(platform)}',
      });
    }
    final platforms = _platformList(grant!['platforms']);
    if (!platforms.contains(platform)) platforms.add(platform);
    await _saveGrantPlatforms(c, grant!, platforms);
    await _enqueueEtl(c, personId, [platform]);
    return _json({'ok': true, 'platform': platform, 'syncing': true});
  }

  Future<List<Map<String, dynamic>>> _oneAccountView(
    gel.Client c,
    String personId,
    Map<String, dynamic> grant,
  ) async {
    final ignored = await _ignoredPlatforms(c);
    final live = await _liveOneAccounts(personId);
    if (live == null) {
      final stored = await _storedGrants(c);
      if (stored.isNotEmpty) {
        return [
          for (final row in stored)
            if (!ignored.contains(row['platform'])) {...row, 'syncing': true},
        ];
      }
      return [
        for (final platform in _platformList(grant['platforms']))
          if (!ignored.contains(platform))
            {'platform': platform, 'name': platform, 'syncing': true},
      ];
    }
    return [
      for (final row in live)
        {
          'platform': row['platform'],
          'name': row['name'] ?? row['platform'],
          'access': row['access'] is Map
              ? (row['access']['policy'] ?? '').toString()
              : (row['access'] ?? '').toString(),
          'syncing': !ignored.contains(row['platform']),
        },
    ];
  }

  Future<List<String>> _syncingPlatforms(gel.Client c, String personId) async {
    final grant = await _grantMap(c);
    final oneUser = grant?['one_user_id'] as String? ?? '';
    if (grant == null ||
        grant['revoked_at'] != null ||
        oneUser.isEmpty ||
        oneUser.startsWith('local:')) {
      return const [];
    }
    final view = await _oneAccountView(c, personId, grant);
    return [
      for (final account in view)
        if (account['syncing'] == true) account['platform'].toString(),
    ];
  }

  Future<Map<String, dynamic>?> _grantMap(gel.Client c) async {
    final raw = await c.querySingleJSON(queries['one_grant_get']);
    if (raw == 'null') return null;
    final decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  Future<List<Map<String, dynamic>>> _storedGrants(gel.Client c) async {
    final decoded = jsonDecode(await c.queryJSON(queries['sync_cursor_list']));
    if (decoded is! List) return const [];
    return [
      for (final row in decoded)
        if (row is Map && row['endpoint'] == 'grant') ..._grantAccount(row),
    ];
  }

  List<Map<String, dynamic>> _grantAccount(Map<dynamic, dynamic> row) {
    final platform = row['platform']?.toString() ?? '';
    if (platform.isEmpty || platform == 'one') return const [];
    final cursor = _jsonMap(row['cursor']);
    final access = cursor['access'];
    return [
      {
        'platform': platform,
        'name': (cursor['name'] ?? platform).toString(),
        'access': access is Map
            ? (access['policy'] ?? '').toString()
            : (access ?? '').toString(),
      },
    ];
  }

  Map<String, dynamic> _jsonMap(Object? raw) {
    if (raw is String && raw.isNotEmpty) {
      try {
        return _jsonMap(jsonDecode(raw));
      } on FormatException {
        return const {};
      }
    }
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return const {};
  }

  List<String> _platformList(Object? raw) => [
    for (final item in raw is List ? raw : const <Object?>[])
      if (item != null && item.toString().isNotEmpty) item.toString(),
  ];

  Future<Set<String>> _ignoredPlatforms(gel.Client c) async {
    final decoded = jsonDecode(await c.queryJSON(queries['sync_cursor_list']));
    if (decoded is! List) return {};
    for (final row in decoded) {
      if (row is! Map) continue;
      if (row['platform'] == 'one' && row['endpoint'] == 'ignored') {
        return _stringSet(row['cursor']);
      }
    }
    return {};
  }

  Set<String> _stringSet(Object? cursor) {
    if (cursor is String && cursor.isNotEmpty) {
      try {
        return _stringSet(jsonDecode(cursor));
      } on FormatException {
        return {};
      }
    }
    if (cursor is List) {
      return {
        for (final item in cursor)
          if (item.toString().isNotEmpty) item.toString(),
      };
    }
    return {};
  }

  Future<void> _writeIgnored(gel.Client c, Set<String> ignored) async {
    await c.querySingleJSON(queries['sync_cursor_upsert'], {
      'platform': 'one',
      'endpoint': 'ignored',
      'cursor': jsonEncode(ignored.toList()..sort()),
      'last_error': null,
    });
  }

  String? _connectReference(Map<String, dynamic> source) {
    final reference = source['reference'];
    if (reference is String && reference.isNotEmpty) return reference;
    final id = source['one_user_id'];
    if (id is String && id.isNotEmpty) return id;
    return null;
  }

  Map<String, dynamic> _grantArgs(
    Map<String, dynamic> source, {
    required String userId,
    required List<String> platforms,
  }) => {
    'one_user_id': userId,
    'space_id': source['space_id'],
    'platforms': platforms,
  };

  /// One cursor per platform. The cursor holds the connection key and the
  /// access the person granted. The OAuth token stays at One.
  Future<void> _rememberPlatformGrants(gel.Client c, Object? raw) async {
    final platforms = <String>[];
    if (raw is List) {
      for (final row in raw) {
        if (row is! Map) continue;
        final platform = row['platform']?.toString() ?? '';
        if (platform.isEmpty) continue;
        platforms.add(platform);
        await c.querySingleJSON(queries['sync_cursor_upsert'], {
          'platform': platform,
          'endpoint': 'grant',
          'cursor': jsonEncode({
            'key': row['key'],
            'name': row['name'] ?? platform,
            'access': row['access'],
          }),
          'last_error': null,
        });
      }
    }
    await c.queryJSON(
      r'''
      delete SyncCursor
      filter .owner = global current_person
        and .endpoint = 'grant'
        and .platform not in array_unpack(<array<str>>$platforms)
      ''',
      {'platforms': platforms},
    );
  }

  Future<Response> _oneDone(Request r) async {
    final failed = r.url.queryParameters['one_connect'] == 'error';
    final title = failed ? 'One did not connect' : 'Maia has the grant';
    final text = failed
        ? 'That attempt did not finish. Go back to Maia and try the account again.'
        : 'Each account you authorized is stored on this Maia. Close this tab and return to the app.';
    return Response.ok(
      oneDoneHtml(title: title, text: text),
      headers: const {'content-type': 'text/html; charset=utf-8'},
    );
  }

  Future<void> _saveGrantPlatforms(
    gel.Client c,
    Map<String, dynamic> grant,
    List<String> platforms,
  ) async {
    await c.querySingleJSON(
      queries['one_grant_upsert'],
      _grantArgs(
        grant,
        userId: grant['one_user_id'] as String,
        platforms: platforms,
      ),
    );
  }

  Future<List<Map<String, dynamic>>?> _liveOneAccounts(String personId) async {
    if (!await _connectReady()) return null;
    try {
      final res = await http
          .get(
            Uri.parse(
              '${config.connectSidecarUrl}/api/one/connections?person=$personId',
            ),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body);
      final rows = body is Map ? body['accounts'] : null;
      if (rows is! List) return const [];
      return [
        for (final row in rows)
          if (row is Map) Map<String, dynamic>.from(row),
      ];
    } on Object {
      return null;
    }
  }

  Future<Response> _syncCursorPut(Request r, gel.Client c) async {
    final b = await _body(r);
    final platform = b['platform'] as String?;
    final endpoint = b['endpoint'] as String?;
    if (platform == null || endpoint == null) {
      return _error(400, 'bad_request', 'platform and endpoint required');
    }
    return Response.ok(
      await c.querySingleJSON(queries['sync_cursor_upsert'], {
        'platform': platform,
        'endpoint': endpoint,
        'cursor': b['cursor'] == null ? null : jsonEncode(b['cursor']),
        'last_error': b['last_error'],
      }),
      headers: _jsonHeaders,
    );
  }

  Future<Response> _weaveCandidates(Request r, gel.Client c) async {
    final limit = int.tryParse(r.url.queryParameters['limit'] ?? '') ?? 40;
    final offset = int.tryParse(r.url.queryParameters['offset'] ?? '') ?? 0;
    return Response.ok(
      await c.querySingleJSON(queries['weave_candidates'], {
        'limit': limit.clamp(1, 200),
        'offset': offset.clamp(0, 5000),
      }),
      headers: _jsonHeaders,
    );
  }

  Future<Response> _graphEntity(Request r, gel.Client c) async {
    final b = await _body(r);
    final name = b['name'] as String?;
    final type = b['type'] as String? ?? 'entity';
    if (name == null || name.trim().isEmpty) {
      return _error(400, 'bad_request', 'name required');
    }
    final json = await c.querySingleJSON(
      r'''
      select (
        insert Entity {
          owner := assert_exists(global current_person),
          name := <str>$name,
          summary := <optional str>$summary,
          kind := <EntityKind><str>$kind,
        }
        unless conflict on ((.owner, .kind, .name))
        else (
          update Entity set {
            summary := (<optional str>$summary) ?? .summary,
            updated_at := datetime_of_statement(),
          }
        )
      ) { id, name, summary, kind }
      ''',
      {
        'name': name.trim(),
        'summary': b['summary'],
        'kind': b['kind'] as String? ?? 'concept',
      },
    );
    if (type != 'entity') {
      // Typed life objects reuse the concluder upserts via name+type.
      await c.querySingleJSON(
        type == 'goal'
            ? r'''
              select (
                insert Goal {
                  owner := assert_exists(global current_person),
                  name := <str>$name,
                  summary := <optional str>$summary,
                }
                unless conflict on ((.owner, .name))
                else (update Goal set {
                  summary := (<optional str>$summary) ?? .summary,
                })
              ) { id, name, summary }
              '''
            : type == 'project'
            ? r'''
              select (
                insert Project {
                  owner := assert_exists(global current_person),
                  name := <str>$name,
                  summary := <optional str>$summary,
                }
                unless conflict on ((.owner, .name))
                else (update Project set {
                  summary := (<optional str>$summary) ?? .summary,
                })
              ) { id, name, summary }
              '''
            : type == 'habit'
            ? r'''
              select (
                insert Habit {
                  owner := assert_exists(global current_person),
                  name := <str>$name,
                  summary := <optional str>$summary,
                }
                unless conflict on ((.owner, .name))
                else (update Habit set {
                  summary := (<optional str>$summary) ?? .summary,
                })
              ) { id, name, summary }
              '''
            : r'select { id := <str>$name }',
        {'name': name.trim(), 'summary': b['summary']},
      );
    }
    return Response.ok(json, headers: _jsonHeaders);
  }

  Future<Response> _graphEdge(Request r, gel.Client c) async {
    final b = await _body(r);
    final source = b['source_name'] as String? ?? b['source'] as String?;
    final target = b['target_name'] as String? ?? b['target'] as String?;
    final kind = b['kind'] as String?;
    if (source == null || target == null || kind == null) {
      return _error(400, 'bad_request', 'source, target, kind required');
    }
    final sourceId = await _thingId(c, source);
    final targetId = await _thingId(c, target);
    if (sourceId == null || targetId == null) {
      return _error(404, 'not_found', 'source or target thing missing');
    }
    final evidence = (b['evidence'] as List<dynamic>? ?? const [])
        .map((e) => e.toString())
        .join(',');
    final status = b['status'] as String? ?? 'proposed';
    final json = await c.querySingleJSON(
      r'''
      select (
        insert Edge {
          owner := assert_exists(global current_person),
          source := assert_single((select Thing filter .id = <uuid>$source)),
          target := assert_single((select Thing filter .id = <uuid>$target)),
          kind := <EdgeKind><str>$kind,
          status := <EdgeStatus><str>$status,
          evidence := <optional str>$evidence,
        }
        unless conflict on ((.owner, .source, .target, .kind))
          else (
          update Edge set {
            evidence := (<optional str>$evidence) ?? .evidence,
            status := (
              EdgeStatus.verified
              if (<str>$status = 'verified' or .status = EdgeStatus.verified)
              else .status
            ),
            updated_at := datetime_of_statement(),
          }
        )
      ) {
        id, kind, status, evidence,
        source: { id, name },
        target: { id, name },
      }
      ''',
      {
        'source': sourceId,
        'target': targetId,
        'kind': kind,
        'status': status,
        'evidence': evidence.isEmpty ? null : evidence,
      },
    );
    return Response.ok(json, headers: _jsonHeaders);
  }

  Future<Response> _graphEdgeStatus(Request r, gel.Client c) async {
    final b = await _body(r);
    final status = b['status'] as String?;
    if (status == null) return _error(400, 'bad_request', 'status required');
    final json = await c.querySingleJSON(queries['edge_set_status'], {
      'id': r.params['id'],
      'status': status,
      'evidence': b['evidence'],
    });
    return json == 'null'
        ? _error(404, 'not_found', 'edge not found')
        : Response.ok(json, headers: _jsonHeaders);
  }

  Future<String?> _thingId(gel.Client c, String name) async {
    final rows = jsonDecode(
      await c.queryJSON(
        r'''
        select Thing { id }
        filter str_lower(.name) = str_lower(<str>$name)
        ''',
        {'name': name},
      ),
    ) as List<dynamic>;
    if (rows.length != 1) return null;
    return (rows.first as Map<String, dynamic>)['id'] as String;
  }

  // ---- admin ----------------------------------------------------------------

  /// Superadmin creates an account. The Person insert is policy-gated, so a
  /// non-superadmin caller gets an AccessPolicyError -> 403.
  Future<Response> _createPerson(Request r, gel.Client c) async {
    final b = await _body(r);
    final handle = b['handle'] as String?;
    final password = b['password'] as String?;
    if (handle == null || password == null || password.length < 8) {
      return _error(400, 'bad_request', 'handle and password (8+) required');
    }
    final person = await c.querySingleJSON(
      r'''
      select (insert Person {
        handle := <str>$handle,
        display_name := <optional str>$display_name,
        email := <optional str>$email,
      }) { id, handle, display_name, email, is_superadmin, created_at }
      ''',
      {
        'handle': handle,
        'display_name': b['display_name'],
        'email': b['email'],
      },
    );
    final id = (jsonDecode(person) as Map<String, dynamic>)['id'] as String;
    await db.service.execute(
      r'''
      insert LocalCredential {
        person := assert_exists((select Person filter .id = <uuid>$id)),
        password_hash := <str>$hash,
      }
      ''',
      {'id': id, 'hash': _password.hash(password)},
    );
    return Response(201, body: person, headers: _jsonHeaders);
  }

  // ---- helpers --------------------------------------------------------------

  /// The profile still works when the graph query is unavailable.
  Future<String> _lifeGraph(gel.Client c) async {
    try {
      final raw = jsonDecode(await c.querySingleJSON(queries['graph']));
      if (raw is! Map) return '';
      return lifeGraphBlock(raw.cast<String, dynamic>());
    } on Object {
      return '';
    }
  }

  Future<void> _enqueueWeave(gel.Client c, String memoryId) async {
    if (jobs == null) return;
    final me = jsonDecode(
      await c.querySingleJSON('select global current_person { id }'),
    );
    if (me is! Map) return;
    await _enqueue(
      c,
      'weave',
      {
        'memory_id': memoryId,
        'person_id': me['id'],
        'token': _jobToken(me['id'] as String),
      },
      subjectId: memoryId,
      options: SendOptions(
        singletonKey: me['id'] as String,
        startAfter: const Duration(seconds: 20),
      ),
    );
  }

  Future<void> _enqueueConclude(gel.Client c, String memoryId) async {
    if (jobs == null) return;
    final me = jsonDecode(
      await c.querySingleJSON('select global current_person { id }'),
    );
    if (me is! Map) return;
    await _enqueue(
      c,
      'conclude',
      {'memory_id': memoryId, 'person_id': me['id']},
      subjectId: memoryId,
      options: SendOptions(singletonKey: memoryId),
    );
  }

  /// Sends to PGBoss and mirrors a `JobRecord` as the caller, so the jobs
  /// page is policy-scoped like everything else. The worker updates the
  /// record by `pgboss_id` as it runs. A singleton that is already queued
  /// returns null from PGBoss and gets no second record.
  Future<void> _enqueue(
    gel.Client c,
    String name,
    Map<String, dynamic> data, {
    String? subjectId,
    SendOptions options = const SendOptions(),
  }) async {
    final q = jobs;
    if (q == null) return;
    final id = await q.send(name, data, options);
    if (id == null) return;
    await c.execute(
      r'''
      insert JobRecord {
        owner := assert_exists(global current_person),
        name := <str>$name,
        state := JobState.created,
        pgboss_id := <uuid>$pgboss_id,
        subject := (select Owned filter .id = <optional uuid>$subject limit 1),
      }
      ''',
      {'name': name, 'pgboss_id': id, 'subject': subjectId},
    );
  }

  Future<Response> _many(
    gel.Client c,
    String name, [
    Map<String, dynamic>? v,
  ]) async =>
      Response.ok(await c.queryJSON(queries[name], v), headers: _jsonHeaders);

  Future<Response> _one(
    gel.Client c,
    String name, [
    Map<String, dynamic>? v,
  ]) async {
    final json = await c.querySingleJSON(queries[name], v);
    return json == 'null'
        ? _error(404, 'not_found', 'not found')
        : Response.ok(json, headers: _jsonHeaders);
  }

  static String _digest(String s) =>
      sha1.convert(utf8.encode(s)).toString().substring(0, 24);

  static String _localDate(DateTime d) => d.toIso8601String().substring(0, 10);

  static const _jsonHeaders = {'content-type': 'application/json'};

  static Response _json(Object body) =>
      Response.ok(jsonEncode(body), headers: _jsonHeaders);

  static Response _error(
    int status,
    String code,
    String message, {
    String? ref,
  }) => Response(
    status,
    body: jsonEncode({
      'code': code,
      'message': message,
      if (ref != null) 'ref': ref,
    }),
    headers: _jsonHeaders,
  );

  /// Caught failures: short line back, raw error in ClientFault.
  Handler _guard(Handler inner) => (Request r) async {
    try {
      return await inner(r);
    } on gel.AccessPolicyError catch (e, st) {
      return _recorded(r, 403, 'forbidden', e, st);
    } on gel.ConstraintViolationError catch (e, st) {
      return _recorded(r, 409, 'conflict', e, st);
    } on gel.InvalidArgumentError catch (e, st) {
      return _recorded(r, 400, 'bad_request', e, st);
    } on gel.CardinalityViolationError catch (e, st) {
      return _recorded(r, 404, 'not_found', e, st);
    } on FormatException catch (e, st) {
      return _recorded(r, 400, 'bad_request', e, st);
    } on Object catch (e, st) {
      return _recorded(r, 500, 'server_error', e, st);
    }
  };

  Future<Response> _recorded(
    Request r,
    int status,
    String code,
    Object error,
    StackTrace stack,
  ) async {
    final summary = friendlyFault(status);
    final ref = await faults.write(
      kind: 'server',
      action: '${r.method} ${r.requestedUri.path}',
      summary: summary,
      detail: '$error\n$stack',
      route: r.requestedUri.path,
      client: r.headers['user-agent'],
      personId: await _callerId(r),
    );
    return _error(status, code, summary, ref: ref);
  }

  Future<Response> _faultReport(Request r, gel.Client c) async {
    final body = await _body(r);
    final action = (body['action'] as String?)?.trim() ?? '';
    final detail = (body['detail'] as String?)?.trim() ?? '';
    if (action.isEmpty || detail.isEmpty) {
      return _error(400, 'bad_request', 'action and detail required');
    }
    final summary = 'Something went wrong. Try again.';
    final ref = await faults.write(
      kind: 'client',
      action: action,
      summary: summary,
      detail: detail,
      route: r.requestedUri.path,
      client: (body['client'] as String?) ?? r.headers['user-agent'],
      personId: await _personId(c),
    );
    return _json({'ref': ref, 'message': summary});
  }

  Future<String?> _callerId(Request r) async {
    final auth = r.headers['authorization'];
    var token = auth != null && auth.startsWith('Bearer ')
        ? auth.substring(7)
        : null;
    token ??= r.headers['x-api-key'];
    if (token == null) return null;
    if (ApiKeys.looksLikeKey(token)) return _resolveApiKey(token);
    return _tokens.verify(token);
  }

  static Future<Map<String, dynamic>> _body(Request r) async {
    final text = await r.readAsString();
    if (text.isEmpty) return const {};
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : const {};
  }
}
