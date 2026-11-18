import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maia_app/one/callback_forwarder.dart';

void main() {
  test('a local API on the callback port is left alone', () async {
    final forwarder = OneCallbackForwarder();
    final opened = await forwarder.browserUrl(
      Uri.parse('http://127.0.0.1:8090/'),
      Uri.parse('http://127.0.0.1:8090/one/authorize?person=abc'),
    );
    expect(opened.host, '127.0.0.1');
    expect(opened.port, 8090);
    expect(opened.path, '/one/authorize');
    expect(
      forwarder.ownsCallback(Uri.parse('http://localhost:8090/')),
      isTrue,
    );
    await forwarder.close();
  });

  test('callback on this Mac is forwarded to the remote API', () async {
    final api = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final seen = <String>[];
    api.listen((request) async {
      seen
        ..add('${request.uri.path}?${request.uri.query}')
        ..add(request.headers.value(HttpHeaders.cookieHeader) ?? '');
      request.response
        ..statusCode = HttpStatus.found
        ..headers.add(
          'set-cookie',
          'one_state=abc; Path=/one; HttpOnly; SameSite=Lax',
        )
        ..headers.set(
          'location',
          'http://127.0.0.1:${api.port}/one/done',
        );
      await request.response.close();
    });

    final forwarder = OneCallbackForwarder(port: 0);
    addTearDown(() async {
      await forwarder.close();
      await api.close(force: true);
    });

    final apiUri = Uri.parse('http://127.0.0.1:${api.port}/');
    final opened = await forwarder.browserUrl(
      apiUri,
      Uri.parse('http://127.0.0.1:${api.port}/one/authorize?person=abc'),
    );
    expect(opened.host, '127.0.0.1');
    expect(opened.port, isNot(api.port));
    expect(opened.path, '/one/authorize');
    expect(opened.queryParameters['person'], 'abc');

    final client = HttpClient();
    addTearDown(client.close);
    final hit = await client.getUrl(
      Uri.parse(
        'http://127.0.0.1:${opened.port}/one/callback?code=x&state=y',
      ),
    );
    hit.followRedirects = false;
    hit.headers.set(HttpHeaders.cookieHeader, 'one_state=abc');
    final response = await hit.close();
    expect(response.statusCode, HttpStatus.found);
    expect(
      response.headers.value('location'),
      'http://127.0.0.1:${opened.port}/one/done',
    );
    expect(response.headers.value('set-cookie'), contains('one_state=abc'));
    expect(seen, [
      '/one/callback?code=x&state=y',
      'one_state=abc',
    ]);
  });
}
