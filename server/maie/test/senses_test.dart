import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:maie_api/src/chat/senses.dart';
import 'package:test/test.dart';

void main() {
  test('a page is text, and a private host is refused', () async {
    final client = _Client((request) async {
      return http.Response(
        '<html><style>x{}</style><p>Hello &amp; welcome</p></html>',
        200,
        headers: {'content-type': 'text/html'},
      );
    });
    final senses = Senses(
      httpClient: client,
      allowed: (uri) async => uri.host == 'example.com',
    );
    final page = jsonDecode(await senses.readUrl('https://example.com/a'));
    expect(page['text'], 'Hello & welcome');
    final blocked = jsonDecode(await senses.readUrl('http://127.0.0.1/secret'));
    expect(blocked['text'], 'That address is not public.');
    expect(publicAddress(InternetAddress('10.1.2.3')), isFalse);
    expect(publicAddress(InternetAddress('8.8.8.8')), isTrue);
  });

  test('an image url is sent to the vision model as an image', () async {
    final bodies = <Map<String, dynamic>>[];
    final client = _Client((request) async {
      bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': 'A red door on a white wall.'},
            },
          ],
        }),
        200,
      );
    });
    final senses = Senses(
      httpClient: client,
      apiKey: 'sk-test',
      allowed: (_) async => true,
    );
    final image = jsonDecode(
      await senses.describeImage('https://cdn.example/door.png'),
    );
    expect(image['text'], 'A red door on a white wall.');
    final content =
        (bodies.single['messages'] as List).single['content'] as List;
    expect(content[1]['type'], 'image_url');
    expect(content[1]['image_url']['url'], 'https://cdn.example/door.png');
    final video = await senses.describeVideo('https://cdn.example/clip.mp4');
    expect(jsonDecode(video)['text'], 'A red door on a white wall.');
    final videoContent =
        (bodies.last['messages'] as List).single['content'] as List;
    expect(videoContent[1]['type'], 'video_url');
  });

  test('vision without a key says so', () async {
    final senses = Senses(allowed: (_) async => true);
    final text = jsonDecode(
      await senses.describeImage('https://cdn.example/door.png'),
    );
    expect(text['text'], 'Vision is not configured.');
  });
}

class _Client extends http.BaseClient {
  _Client(this.reply);
  final Future<http.Response> Function(http.Request request) reply;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await reply(request as http.Request);
    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
    );
  }
}
