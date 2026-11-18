import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:maia_api/src/config.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// PolarGrid's hosted PersonaPlex.
///
/// The API key stays on this process. A client opens `/voice/live` and
/// the binary frames are forwarded as PolarGrid defines them: `0x01`
/// audio, `0x02` text, `0x03` control.
class PolarGridVoice {
  /// Reads the key, region, and voice off [config].
  PolarGridVoice(this.config) : _region = config.polargridRegion;

  /// Process configuration. The key is never copied into a response.
  final Config config;

  final Set<WebSocketChannel> _upstream = {};
  String _region;

  /// True when a key is configured. Does not mean the edge is reachable.
  bool get enabled => config.polargridApiKey != null;

  /// Region last seen answering. Starts as [Config.polargridRegion].
  String get region => _region;

  /// Edge used for `/v1/models` and the PersonaPlex socket.
  Uri get edge => Uri(scheme: 'https', host: 'api.$_region.edge.polargrid.ai');

  /// Upstream socket. Voice and persona are query params. The key is not.
  Uri get endpoint {
    return Uri(
      scheme: 'wss',
      host: 'api.$_region.edge.polargrid.ai',
      path: '/v1/voice/personaplex',
      queryParameters: {
        'voice': config.polargridVoice,
        if (config.polargridPersona != null) 'persona': config.polargridPersona,
      },
    );
  }

  /// True when some PolarGrid edge accepts this key.
  ///
  /// Tries the pinned region, then the autorouter. PersonaPlex is a
  /// separate WebSocket; `/v1/models` is the cheap liveness check.
  Future<bool> reachable({http.Client? client, Duration? timeout}) async {
    if (!enabled) return false;
    final httpClient = client ?? http.Client();
    final owns = client == null;
    final limit = timeout ?? const Duration(seconds: 3);
    try {
      if (await _modelsOk(httpClient, _region, limit)) return true;
      final routed = await _autoroute(httpClient, limit);
      if (routed == null || routed == _region) return false;
      if (!await _modelsOk(httpClient, routed, limit)) return false;
      _region = routed;
      return true;
    } on Object {
      return false;
    } finally {
      if (owns) httpClient.close();
    }
  }

  Future<bool> _modelsOk(
    http.Client client,
    String region,
    Duration timeout,
  ) async {
    try {
      final response = await client
          .get(
            Uri(
              scheme: 'https',
              host: 'api.$region.edge.polargrid.ai',
              path: '/v1/models',
            ),
            headers: {'authorization': 'Bearer ${config.polargridApiKey}'},
          )
          .timeout(timeout);
      return response.statusCode == 200;
    } on Object {
      return false;
    }
  }

  Future<String?> _autoroute(http.Client client, Duration timeout) async {
    try {
      final response = await client
          .get(Uri.parse('https://autorouter.polargrid.ai/v1/route'))
          .timeout(timeout);
      if (response.statusCode != 200) return null;
      final body = jsonDecode(response.body);
      if (body is Map && body['region'] is String) {
        return body['region'] as String;
      }
    } on Object {
      // Stay on the pinned region.
    }
    return null;
  }

  /// Status the Talk button can treat as a loaded engine.
  Map<String, dynamic> status() => {
    'available': enabled,
    'provider': 'polargrid',
    'url': edge.replace(scheme: 'wss', path: '/v1/voice/personaplex').toString(),
    'starting': false,
    'engine': {'loaded': enabled, 'loading': false, 'model': 'personaplex'},
    'brain': {'provider': 'polargrid', 'model': 'personaplex'},
  };

  /// Upgrade [request] and bridge it to PolarGrid.
  Response handle(Request request) {
    final handler = webSocketHandler((client, _) {
      unawaited(_bridge(client));
    });
    final response = handler(request);
    if (response is! Response) {
      throw StateError('voice upgrade did not finish');
    }
    return response;
  }

  Future<void> _bridge(WebSocketChannel client) async {
    final WebSocketChannel upstream;
    try {
      upstream = WebSocketChannel.connect(
        endpoint,
        protocols: ['bearer.${config.polargridApiKey}'],
      );
      await upstream.ready;
    } on Object {
      await _closeQuiet(client.sink);
      return;
    }
    _upstream.add(upstream);
    final done = Completer<void>();
    void finish() {
      _upstream.remove(upstream);
      if (!done.isCompleted) done.complete();
    }

    upstream.stream.listen(
      client.sink.add,
      onError: (Object _, StackTrace _) => finish(),
      onDone: finish,
    );
    client.stream.listen(
      upstream.sink.add,
      onError: (Object _, StackTrace _) => finish(),
      onDone: finish,
    );
    await done.future;
    await _closeQuiet(client.sink);
    await _closeQuiet(upstream.sink);
  }

  /// Inject [text] into every open call. False when no call is up.
  bool say(String text) {
    if (_upstream.isEmpty || text.isEmpty) return false;
    final frame = <int>[0x02, ...utf8.encode(text)];
    for (final socket in _upstream) {
      socket.sink.add(frame);
    }
    return true;
  }

  /// Close every open PolarGrid call.
  Future<void> close() async {
    final open = List<WebSocketChannel>.of(_upstream);
    _upstream.clear();
    for (final socket in open) {
      await _closeQuiet(socket.sink);
    }
  }

  Future<void> _closeQuiet(WebSocketSink sink) async {
    try {
      await sink.close();
    } on Object {
      // The peer already hung up.
    }
  }
}
