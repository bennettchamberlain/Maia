import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Reads a public file or page, and asks a vision model about an image
/// or a video. Private addresses are refused.
class Senses {
  Senses({
    http.Client? httpClient,
    this.apiKey,
    this.baseUrl = 'https://openrouter.ai/api/v1',
    this.model = 'google/gemini-2.5-flash',
    this.allowed,
  }) : _http = httpClient ?? http.Client();

  final String? apiKey;
  final String baseUrl;
  final String model;
  final http.Client _http;

  /// Test seam. Production resolves the host and rejects private ranges.
  final Future<bool> Function(Uri uri)? allowed;

  bool get visionReady => apiKey != null && apiKey!.isNotEmpty;

  Future<String> readFile(String raw, {String? ask}) async {
    final uri = _uri(raw);
    if (uri == null) return _text('Give an http or https url.');
    if (_looksImage(uri)) return describeImage(uri.toString(), ask: ask);
    if (_looksVideo(uri)) return describeVideo(uri.toString(), ask: ask);
    final response = await _fetch(uri);
    if (response == null) return _text('That address is not public.');
    if (response.statusCode >= 400) {
      return _text('Could not read the file (${response.statusCode}).');
    }
    final type = response.headers['content-type'] ?? '';
    if (type.startsWith('image/')) {
      return describeImage(uri.toString(), ask: ask);
    }
    if (type.startsWith('video/')) {
      return describeVideo(uri.toString(), ask: ask);
    }
    return _text(readablePage(response.body, type));
  }

  Future<String> readUrl(String raw) async {
    final uri = _uri(raw);
    if (uri == null) return _text('Give an http or https url.');
    final response = await _fetch(uri);
    if (response == null) return _text('That address is not public.');
    if (response.statusCode >= 400) {
      return _text('Could not read the page (${response.statusCode}).');
    }
    final type = response.headers['content-type'] ?? '';
    return _text(readablePage(response.body, type));
  }

  Future<String> describeImage(String raw, {String? ask}) => _describe(
    raw,
    ask: ask ?? 'Describe this image. Name what is in it and any text.',
    part: 'image_url',
  );

  Future<String> describeVideo(String raw, {String? ask}) => _describe(
    raw,
    ask: ask ?? 'Describe this video. What happens, in order, and any speech or on-screen text.',
    part: 'video_url',
  );

  Future<String> _describe(
    String raw, {
    required String ask,
    required String part,
  }) async {
    final uri = _uri(raw);
    if (uri == null) return _text('Give an http or https url.');
    if (!await _public(uri)) return _text('That address is not public.');
    if (!visionReady) return _text('Vision is not configured.');
    final response = await _http.post(
      Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions'),
      headers: {
        'content-type': 'application/json',
        'authorization': 'Bearer $apiKey',
      },
      body: jsonEncode({
        'model': model,
        'max_tokens': 500,
        'messages': [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': ask},
              {
                'type': part,
                part: {'url': uri.toString()},
              },
            ],
          },
        ],
      }),
    );
    if (response.statusCode >= 400) {
      return _text('Could not describe it (${response.statusCode}).');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      return _text('Could not describe it.');
    }
    final text = _answer(decoded);
    return _text(text ?? 'No description.');
  }

  Future<http.Response?> _fetch(Uri uri) async {
    var current = uri;
    for (var hop = 0; hop < 3; hop++) {
      if (!await _public(current)) return null;
      final request = http.Request('GET', current)..followRedirects = false;
      final streamed = await _http.send(request);
      final response = await http.Response.fromStream(streamed);
      if (response.statusCode >= 300 && response.statusCode < 400) {
        final location = response.headers['location'];
        if (location == null || location.isEmpty) return response;
        current = current.resolve(location);
        continue;
      }
      if (response.bodyBytes.length > 256 * 1024) {
        return http.Response(
          utf8.decode(response.bodyBytes.sublist(0, 256 * 1024)),
          response.statusCode,
          headers: response.headers,
        );
      }
      return response;
    }
    return http.Response('too many redirects', 310);
  }

  Future<bool> _public(Uri uri) async {
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    if (uri.host.isEmpty) return false;
    final gate = allowed;
    if (gate != null) return gate(uri);
    if (_blockedHost(uri.host)) return false;
    try {
      final addresses = await InternetAddress.lookup(uri.host);
      if (addresses.isEmpty) return false;
      return addresses.every(publicAddress);
    } on SocketException {
      return false;
    }
  }

  static Uri? _uri(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || !uri.hasScheme) return null;
    return uri;
  }

  static String _text(String text) =>
      jsonEncode({'type': 'text', 'text': text});
}

String? _answer(Object? decoded) {
  if (decoded is! Map) return null;
  final choices = decoded['choices'];
  if (choices is! List || choices.isEmpty) return null;
  final first = choices.first;
  if (first is! Map) return null;
  final message = first['message'];
  if (message is! Map) return null;
  final content = message['content'];
  if (content is! String) return null;
  final text = content.trim();
  return text.isEmpty ? null : text;
}

/// Visible text of an HTML page, or the body when it is already text.
String readablePage(String raw, String contentType) {
  var text = raw;
  final html =
      contentType.contains('html') ||
      raw.toLowerCase().contains('<html') ||
      raw.contains('<p>') ||
      raw.contains('<div');
  if (html) {
    text = text
        .replaceAll(
          RegExp('<script[\\s\\S]*?</script>', caseSensitive: false),
          ' ',
        )
        .replaceAll(
          RegExp('<style[\\s\\S]*?</style>', caseSensitive: false),
          ' ',
        )
        .replaceAll(RegExp('<[^>]+>'), ' ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');
  }
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.length <= 6000) return text;
  return text.substring(0, 6000);
}

bool publicAddress(InternetAddress ip) {
  if (ip.isLoopback || ip.isLinkLocal || ip.isMulticast) return false;
  final bytes = ip.rawAddress;
  if (ip.type == InternetAddressType.IPv4 && bytes.length >= 4) {
    final a = bytes[0];
    final b = bytes[1];
    if (a == 0 || a == 10 || a == 127) return false;
    if (a == 169 && b == 254) return false;
    if (a == 172 && b >= 16 && b <= 31) return false;
    if (a == 192 && b == 168) return false;
    if (a == 100 && b >= 64 && b <= 127) return false;
  }
  if (ip.type == InternetAddressType.IPv6 && bytes.isNotEmpty) {
    if (bytes[0] & 0xfe == 0xfc) return false;
  }
  return true;
}

bool _blockedHost(String host) {
  final name = host.toLowerCase();
  if (name == 'localhost' ||
      name.endsWith('.local') ||
      name.endsWith('.internal')) {
    return true;
  }
  final ip = InternetAddress.tryParse(name);
  if (ip == null) return false;
  return !publicAddress(ip);
}

bool _looksImage(Uri uri) {
  final path = uri.path.toLowerCase();
  return path.endsWith('.png') ||
      path.endsWith('.jpg') ||
      path.endsWith('.jpeg') ||
      path.endsWith('.gif') ||
      path.endsWith('.webp');
}

bool _looksVideo(Uri uri) {
  final path = uri.path.toLowerCase();
  return path.endsWith('.mp4') ||
      path.endsWith('.webm') ||
      path.endsWith('.mov') ||
      path.endsWith('.mkv');
}
