import 'dart:async';
import 'dart:convert';

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
  PolarGridVoice(this.config);

  /// Process configuration. The key is never copied into a response.
  final Config config;

  final Set<WebSocketChannel> _upstream = {};

  /// True when a key is configured.
  bool get enabled => config.polargridApiKey != null;

  /// Upstream socket. Voice and persona are query params. The key is not.
  Uri get endpoint {
    return Uri(
      scheme: 'wss',
      host: 'api.${config.polargridRegion}.edge.polargrid.ai',
      path: '/v1/voice/personaplex',
      queryParameters: {
        'voice': config.polargridVoice,
        if (config.polargridPersona != null) 'persona': config.polargridPersona,
      },
    );
  }

  /// Status the Talk button can treat as a loaded engine.
  Map<String, dynamic> status() => {
    'available': enabled,
    'provider': 'polargrid',
    'url': Uri(
      scheme: 'wss',
      host: 'api.${config.polargridRegion}.edge.polargrid.ai',
      path: '/v1/voice/personaplex',
    ).toString(),
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
