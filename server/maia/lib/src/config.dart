import 'dart:io';

/// Process configuration from the environment.
class Config {
  const Config({
    required this.port,
    required this.gelDsn,
    required this.gelTlsInsecure,
    required this.sessionSecret,
    required this.queriesDir,
    this.pgUrl,
    this.ollamaUrl,
    this.embeddingModel = 'nomic-embed-text',
    this.concludeModel = 'llama3.2:3b',
    this.sessionTtl = const Duration(days: 7),
    this.agentUrl,
    this.agentToken,
    this.agentModel = 'openclaw/default',
    this.chatProvider = 'auto',
    this.parasailChatModel = 'parasail-glm-53-flash',
    this.ollamaChatModel = 'llama3.2',
    this.geminiApiKey,
    this.geminiBaseUrl =
        'https://generativelanguage.googleapis.com/v1beta/openai',
    this.geminiChatModel = 'gemini-3-flash-preview',
    this.openrouterApiKey,
    this.openrouterBaseUrl = 'https://openrouter.ai/api/v1',
    this.openrouterChatModel = 'google/gemini-2.5-flash-lite',
    this.openrouterMaxTokens = 2048,
    this.youApiKey,
    this.connectPublicUrl = 'http://127.0.0.1:8788',
    this.connectSidecarUrl = 'http://127.0.0.1:8788',
    this.googleMapsApiKey,
    this.geocodeUserAgent = 'maia-api (local)',
    this.parasailApiKey,
    this.parasailBaseUrl = 'https://api.parasail.io/v1',
    this.parasailEmbedModel = 'parasail-bge-m3',
    this.internalSecret,
    this.pythonBin = 'python3',
    this.hackathonRoot,
    this.voiceUrl = 'http://127.0.0.1:8998',
    this.voiceBin,
    this.voiceWorkdir,
    this.voiceKeepAlive = const Duration(hours: 6),
  });

  factory Config.fromEnv([Map<String, String>? env]) {
    final e = env ?? Platform.environment;
    final secret = e['MAIA_SESSION_SECRET'];
    if (secret == null || secret.length < 32) {
      throw StateError(
        'MAIA_SESSION_SECRET must be set to at least 32 characters',
      );
    }
    final root = _blankToNull(e['HACKATHON_ROOT'] ?? e['REQUIEM_ROOT']);
    return Config(
      port: int.parse(e['MAIA_PORT'] ?? '8080'),
      gelDsn: e['GEL_DSN'] ?? 'gel://admin@127.0.0.1:5656/main',
      gelTlsInsecure:
          (e['GEL_CLIENT_TLS_SECURITY'] ?? 'insecure') == 'insecure',
      sessionSecret: secret,
      queriesDir: e['MAIA_QUERIES_DIR'] ?? _defaultQueriesDir(),
      pgUrl: e['MAIA_PG_URL'],
      ollamaUrl: e['OLLAMA_URL'],
      embeddingModel: e['MAIA_EMBEDDING_MODEL'] ?? 'nomic-embed-text',
      concludeModel: e['MAIA_CONCLUDE_MODEL'] ?? 'llama3.2:3b',
      agentUrl: e['MAIA_AGENT_URL'],
      agentToken: e['MAIA_AGENT_TOKEN'],
      agentModel: e['MAIA_AGENT_MODEL'] ?? 'openclaw/default',
      chatProvider: (e['MAIA_CHAT_PROVIDER'] ?? 'auto').toLowerCase(),
      parasailChatModel:
          e['PARASAIL_MODEL'] ??
          e['MAIA_PARASAIL_CHAT_MODEL'] ??
          'parasail-glm-53-flash',
      ollamaChatModel: e['MAIA_CHAT_MODEL'] ?? 'llama3.2',
      geminiApiKey: _blankToNull(
        e['GOOGLE_GEMINI_API_KEY'] ?? e['GEMINI_API_KEY'],
      ),
      geminiBaseUrl:
          e['GEMINI_BASE_URL'] ??
          'https://generativelanguage.googleapis.com/v1beta/openai',
      geminiChatModel: e['GEMINI_MODEL'] ?? 'gemini-3-flash-preview',
      openrouterApiKey: _blankToNull(
        e['OPENROUTER_API_KEY'] ?? e['OPEN_ROUTER_API_KEY'],
      ),
      openrouterBaseUrl: e['OPENROUTER_BASE_URL'] ?? 'https://openrouter.ai/api/v1',
      openrouterChatModel:
          e['OPENROUTER_MODEL'] ?? 'google/gemini-2.5-flash-lite',
      openrouterMaxTokens:
          int.tryParse(e['OPENROUTER_MAX_TOKENS'] ?? '') ?? 2048,
      youApiKey: _blankToNull(e['YDC_API_KEY'] ?? e['YOU_WEB_SEARCH_TOKEN']),
      connectPublicUrl:
          e['CONNECT_PUBLIC_URL'] ??
          'http://127.0.0.1:${e['CONNECT_PORT'] ?? '8788'}',
      connectSidecarUrl:
          'http://127.0.0.1:${e['CONNECT_PORT'] ?? '8788'}',
      googleMapsApiKey: _blankToNull(
        e['GOOGLE_MAPS_API_KEY'] ?? e['GEOCODING_API_KEY'],
      ),
      geocodeUserAgent:
          e['MAIA_GEOCODE_USER_AGENT'] ?? 'maia-api (self-hosted)',
      parasailApiKey: _blankToNull(e['PARASAIL_API_KEY']),
      parasailBaseUrl: e['PARASAIL_BASE_URL'] ?? 'https://api.parasail.io/v1',
      parasailEmbedModel: e['PARASAIL_EMBED_MODEL'] ?? 'parasail-bge-m3',
      internalSecret: _blankToNull(e['MAIA_INTERNAL_SECRET']),
      pythonBin: e['MAIA_PYTHON'] ??
          (e['VIRTUAL_ENV'] == null
              ? 'python3'
              : '${e['VIRTUAL_ENV']}/bin/python'),
      hackathonRoot: root,
      voiceUrl: e['VOICE_URL'] ?? 'http://127.0.0.1:8998',
      voiceBin: _blankToNull(e['VOICE_BIN']) ?? _defaultVoiceBin(root),
      voiceWorkdir:
          _blankToNull(e['VOICE_WORKDIR']) ??
          (root == null ? null : '$root/server/maia_voice'),
      voiceKeepAlive: Duration(
        seconds: int.tryParse(e['VOICE_KEEP_ALIVE_SEC'] ?? '') ?? 6 * 3600,
      ),
    );
  }

  final int port;
  final String gelDsn;
  final bool gelTlsInsecure;
  final String sessionSecret;

  /// Directory holding the named `.edgeql` queries (`schema/queries`).
  final String queriesDir;

  /// Raw backend Postgres for PGBoss. Null disables job enqueueing.
  final String? pgUrl;

  /// Ollama base URL for embeddings. Null disables semantic search.
  final String? ollamaUrl;
  final String embeddingModel;

  /// Small local model that reads a memory and proposes graph edges.
  /// Kept off the chat model so a conclusion does not evict the harness.
  final String concludeModel;
  final Duration sessionTtl;

  /// Optional OpenClaw gateway. Chat no longer requires this — Parasail
  /// and Ollama are first-class. `http://127.0.0.1:18789` when used.
  final String? agentUrl;
  final String? agentToken;

  /// Agent target. For OpenClaw this is an agent id, not a provider model.
  final String agentModel;

  /// `auto` | `openrouter` | `gemini` | `parasail` | `ollama` | `agent`.
  /// Auto prefers OpenRouter, then Gemini, then Parasail, then Ollama.
  final String chatProvider;
  final String parasailChatModel;
  final String ollamaChatModel;

  /// Gemini Developer API (OpenAI-compat at `/v1beta/openai`).
  final String? geminiApiKey;
  final String geminiBaseUrl;
  final String geminiChatModel;

  /// OpenRouter OpenAI-compat (`https://openrouter.ai/api/v1`).
  final String? openrouterApiKey;
  final String openrouterBaseUrl;
  final String openrouterChatModel;
  final int openrouterMaxTokens;

  /// You.com search key for the `web_search` chat tool.
  final String? youApiKey;

  /// Advertised Connect URL. Prefer the API proxy (`/one/authorize`) so
  /// a forwarded 8090 is enough; this is the loopback sidecar.
  final String connectPublicUrl;
  final String connectSidecarUrl;

  /// Google Geocoding key. Null means Nominatim (OpenStreetMap), which needs
  /// no key but is rate-limited to one request per second.
  final String? googleMapsApiKey;
  final String geocodeUserAgent;

  /// Parasail cloud embeddings. Null disables the cloud vector column.
  final String? parasailApiKey;
  final String parasailBaseUrl;
  final String parasailEmbedModel;

  /// Shared secret for Connect `userStore` callbacks. Not a user credential.
  final String? internalSecret;

  /// Python used to run ETL / weaver jobs.
  final String pythonBin;

  /// Maia repo root (`etl/` and `swarm/` live here).
  final String? hackathonRoot;

  /// PersonaVoice sidecar (PersonaPlex + local STT). Thinking is Parasail.
  final String voiceUrl;
  final String? voiceBin;
  final String? voiceWorkdir;
  final Duration voiceKeepAlive;

  static String? _defaultVoiceBin(String? root) {
    if (root == null) return null;
    final path = '$root/server/maia_voice/.venv/bin/maia-voice';
    return File(path).existsSync() ? path : null;
  }

  static String? _blankToNull(String? s) =>
      s == null || s.trim().isEmpty ? null : s.trim();

  static String _defaultQueriesDir() {
    // server/maia -> repo root -> schema/queries
    final here = Directory.current.path;
    return '$here/../../schema/queries';
  }
}
