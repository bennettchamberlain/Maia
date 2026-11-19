import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maie_api_client/maie_api_client.dart';
import 'package:test/test.dart';

void main() {
  MaieApiClient client(http.Client inner, {String? token}) => MaieApiClient(
    baseUrl: Uri.parse('http://localhost:8080/'),
    tokenProvider: () => token,
    httpClient: inner,
  );

  test('sends bearer token and parses feed', () async {
    final c = client(
      MockClient((req) async {
        expect(req.headers['authorization'], 'Bearer tok');
        expect(req.url.path, '/memory');
        return http.Response(
          jsonEncode([
            {
              'id': '1',
              'kind': 'note',
              'occurred_at': '2026-10-19T00:00:00Z',
              'source': 's',
            },
          ]),
          200,
        );
      }),
      token: 'tok',
    );
    final feed = await c.memoryFeed();
    expect(feed.single.kind, 'note');
  });

  test('hides a raw error and keeps the reference', () {
    const raw = MaieApiException(
      400,
      'Function call is missing a thought_signature',
      code: 'bad_request',
      ref: 'ab12cd34',
    );
    expect(
      raw.shown,
      'Something went wrong. Try again. Reference ab12cd34.',
    );
    const plain = MaieApiException(400, 'content required');
    expect(plain.shown, 'content required');
  });

  test('maps errors to MaieApiException', () async {
    final c = client(
      MockClient(
        (_) async => http.Response(
          jsonEncode({'code': 'unauthorized', 'message': 'no'}),
          401,
        ),
      ),
    );
    expect(
      c.me(),
      throwsA(
        isA<MaieApiException>().having(
          (e) => e.isUnauthorized,
          'unauth',
          true,
        ),
      ),
    );
  });
}
