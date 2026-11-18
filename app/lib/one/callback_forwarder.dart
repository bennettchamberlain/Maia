import 'dart:async';
import 'dart:io';

/// One always sends the browser to `127.0.0.1:8090`. When Maia itself is
/// on another machine, this process catches that redirect and forwards it
/// to the API, which already proxies to the connect sidecar.
class OneCallbackForwarder {
  new({this.port = 8090, HttpClient? httpClient})
    : _http = httpClient ?? HttpClient();

  static final instance = OneCallbackForwarder();

  final int port;
  final HttpClient _http;

  HttpServer? _server;
  Uri? _api;
  Future<void>? _starting;

  /// True when the API is already this machine on [port], so it owns the
  /// redirect and this process must leave the port alone.
  bool ownsCallback(Uri api) {
    final host = api.host == '127.0.0.1' || api.host == 'localhost';
    return host && _portOf(api) == port;
  }

  /// Bind while [api] is somewhere else. A local API on [port] stops us.
  Future<void> follow(Uri api) {
    _api = api;
    if (ownsCallback(api)) return close();
    if (_server != null) return Future<void>.value();
    return _starting ??= _bind();
  }

  /// The authorize URL the browser should open. Loopback when we are
  /// forwarding, so the grant cookie and the callback share one host.
  Future<Uri> browserUrl(Uri api, Uri authorize) async {
    await follow(api);
    if (_server == null || !authorize.path.startsWith('/one/')) {
      return authorize;
    }
    return authorize.replace(
      scheme: 'http',
      host: '127.0.0.1',
      port: _server!.port,
    );
  }

  Future<void> close() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _bind() async {
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      _server = server;
      server.listen((request) => unawaited(_onRequest(request)));
    } on SocketException {
      _server = null;
    } finally {
      _starting = null;
    }
  }

  Future<void> _onRequest(HttpRequest request) async {
    final api = _api;
    final path = request.uri.path;
    const allowed = {'/one/authorize', '/one/callback', '/one/done'};
    if (api == null || !allowed.contains(path)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final target = api.replace(
      path: path,
      queryParameters: request.uri.queryParameters,
    );
    try {
      final proxy = await _http.openUrl(request.method, target);
      proxy.followRedirects = false;
      final cookie = request.headers.value(HttpHeaders.cookieHeader);
      if (cookie != null) {
        proxy.headers.set(HttpHeaders.cookieHeader, cookie);
      }
      final type = request.headers.value(HttpHeaders.contentTypeHeader);
      if (type != null) {
        proxy.headers.set(HttpHeaders.contentTypeHeader, type);
      }
      final accept = request.headers.value(HttpHeaders.acceptHeader);
      if (accept != null) {
        proxy.headers.set(HttpHeaders.acceptHeader, accept);
      }
      if (request.contentLength >= 0) {
        proxy.contentLength = request.contentLength;
      }
      await proxy.addStream(request);
      final upstream = await proxy.close();
      request.response.statusCode = upstream.statusCode;
      upstream.headers.forEach((name, values) {
        final lower = name.toLowerCase();
        const keep = {'content-type', 'location', 'set-cookie'};
        if (!keep.contains(lower)) return;
        for (final value in values) {
          final next = lower == 'location' ? _rewriteLocation(value) : value;
          request.response.headers.add(name, next);
        }
      });
      await upstream.pipe(request.response);
    } on Object {
      try {
        final response = request.response
          ..statusCode = HttpStatus.badGateway
          ..headers.contentType = ContentType.html
          ..write('Maia could not reach the server to finish One.');
        await response.close();
      } on Object {
        // The browser already has whatever bytes went out.
      }
    }
  }

  String _rewriteLocation(String value) {
    final uri = Uri.tryParse(value);
    final api = _api;
    if (uri == null || !uri.hasScheme || api == null) return value;
    if (uri.host != api.host || _portOf(uri) != _portOf(api)) return value;
    final listen = _server?.port ?? port;
    return uri
        .replace(scheme: 'http', host: '127.0.0.1', port: listen)
        .toString();
  }

  int _portOf(Uri uri) {
    if (uri.hasPort) return uri.port;
    return uri.scheme == 'https' ? 443 : 80;
  }
}
