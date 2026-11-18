import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:maia_api_client/maia_api_client.dart';
import 'package:maia_models/maia_models.dart';

/// A second client of the Maia server the desktop app already uses.
///
/// `setup` makes the `eval` person and checks that two connections see the
/// same session while the desktop person does not. `send` runs one turn on
/// a fresh session belonging to that person.
Future<void> main(List<String> args) async {
  final command = args.isEmpty ? 'setup' : args.first;
  final flags = _flags(args.skip(1).toList());
  try {
    switch (command) {
      case 'setup':
        await _setup(flags);
      case 'send':
        final text = flags.rest.join(' ').trim();
        if (text.isEmpty) {
          stderr.writeln('send needs the message');
          exitCode = 64;
          return;
        }
        await _send(flags, text);
      default:
        stderr.writeln(
          'use: chat_eval setup [--url URI] | send [--url URI] <message>',
        );
        exitCode = 64;
    }
  } on MaiaApiException catch (e) {
    stderr.writeln('server ${e.statusCode}: ${e.message}');
    exitCode = 1;
  }
}

final _local = File('evals/chat/client.local');

class _Flags {
  _Flags(this.url, this.handle, this.session, this.rest);

  final String? url;
  final String handle;
  final String? session;
  final List<String> rest;
}

_Flags _flags(List<String> args) {
  String? url;
  String? session;
  var handle = 'eval';
  final rest = <String>[];
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--url' && i + 1 < args.length) {
      url = args[++i];
    } else if (a == '--handle' && i + 1 < args.length) {
      handle = args[++i];
    } else if (a == '--session' && i + 1 < args.length) {
      session = args[++i];
    } else {
      rest.add(a);
    }
  }
  return _Flags(url, handle, session, rest);
}

Future<void> _setup(_Flags flags) async {
  final saved = _readLocal();
  final url = _normalise(
    flags.url ?? saved['MAIA_EVAL_URL'] ?? await _desktopUrl(),
  );
  if (url == null) {
    stderr.writeln(
      'No server URL. Pass --url, or sign the desktop app into one.',
    );
    exitCode = 64;
    return;
  }
  final health = await _health(url);
  final handle = flags.handle;
  final savedPassword = saved['MAIA_EVAL_HANDLE'] == handle
      ? saved['MAIA_EVAL_PASSWORD']
      : null;
  final password = savedPassword ?? _password();

  final first = _client(url);
  Session session;
  try {
    session = await first.api.signIn(handle: handle, password: password);
    first.token = session.token;
  } on MaiaApiException catch (e) {
    if (e.statusCode != 401 || savedPassword != null) rethrow;
    await _createPerson(url, handle, password);
    session = await first.api.signIn(handle: handle, password: password);
    first.token = session.token;
  }

  final second = _client(url);
  final again = await second.api.signIn(handle: handle, password: password);
  second.token = again.token;

  final probe = await first.api.chatCreate(title: 'eval-probe');
  final seen = await second.api.chatSessions();
  if (!seen.any((s) => s.id == probe.id)) {
    throw StateError(
      'Second client did not see the session the first created.',
    );
  }

  final desktop = _client(url);
  final owner = await desktop.api.signIn(
    handle: 'maia',
    password: 'maia-admin',
  );
  desktop.token = owner.token;
  final theirs = await desktop.api.chatSessions();
  if (theirs.any((s) => s.id == probe.id)) {
    throw StateError('The desktop person can see the eval session.');
  }
  await first.api.chatDelete(probe.id);

  await _writeLocal(url, handle, password);
  final chat = health['chat'];
  final provider = chat is Map ? chat['provider'] : null;
  stdout.writeln('server $url');
  stdout.writeln('client ${session.person.handle} (${session.person.id})');
  stdout.writeln('second client sees the same session');
  stdout.writeln('desktop person ${owner.person.handle} does not');
  stdout.writeln('chat provider ${provider ?? 'unknown'}');
}

Future<void> _send(_Flags flags, String text) async {
  final saved = _readLocal();
  final url = _normalise(flags.url ?? saved['MAIA_EVAL_URL']);
  final handle = flags.handle;
  final password = saved['MAIA_EVAL_PASSWORD'];
  if (url == null || password == null || saved['MAIA_EVAL_HANDLE'] != handle) {
    stderr.writeln('Run setup first.');
    exitCode = 64;
    return;
  }
  final client = _client(url);
  final session = await client.api.signIn(handle: handle, password: password);
  client.token = session.token;
  final chatId = flags.session ?? (await client.api.chatCreate()).id;
  final events = <String>[];
  String? failed;
  await for (final ev in client.api.chatSend(chatId, text)) {
    switch (ev) {
      case ChatUserStored():
        events.add('user');
      case ChatDelta(:final text):
        events.add('delta');
        stdout.write(text);
      case ChatFinished():
        events.add('finish');
      case ChatToolUsed(:final call):
        final result = call.result ?? '';
        final bad =
            result.startsWith('error:') ||
            result.contains('web search failed') ||
            result.contains('web search is not configured') ||
            result.contains('INVALID_ARGUMENT') ||
            result.contains('thought_signature');
        events.add(bad ? 'tool ${call.name} error' : 'tool ${call.name}');
        if (bad && failed == null) failed = result;
      case ChatDone():
        events.add('done');
      case ChatFailed(:final message):
        events.add('error');
        failed = message;
    }
  }
  stdout.writeln();
  stdout.writeln('http 200');
  stdout.writeln('session $chatId');
  stdout.writeln('wire ${events.join(' ')}');
  if (failed != null) {
    stderr.writeln(failed);
    exitCode = 1;
  }
}

class _Held {
  _Held(String url) {
    api = MaiaApiClient(baseUrl: Uri.parse(url), tokenProvider: () => token);
  }

  late final MaiaApiClient api;
  String? token;
}

_Held _client(String url) => _Held(url);

Future<Map<String, dynamic>> _health(String url) async {
  final res = await http.get(Uri.parse('${url}health'));
  if (res.statusCode != 200) {
    throw StateError('health ${res.statusCode} from $url');
  }
  final body = jsonDecode(res.body);
  if (body is! Map<String, dynamic> || body['ok'] != true) {
    throw StateError('health from $url is not ok');
  }
  return body;
}

Future<void> _createPerson(String url, String handle, String password) async {
  final admin = _client(url);
  final session = await admin.api.signIn(
    handle: 'maia',
    password: 'maia-admin',
  );
  admin.token = session.token;
  final res = await http.post(
    Uri.parse('${url}admin/people'),
    headers: {
      'content-type': 'application/json',
      'authorization': 'Bearer ${admin.token}',
    },
    body: jsonEncode({
      'handle': handle,
      'password': password,
      'display_name': 'Eval',
    }),
  );
  if (res.statusCode != 201) {
    throw StateError(
      'Could not create $handle (${res.statusCode}). '
      'The person may already exist without a saved password.',
    );
  }
}

Future<String?> _desktopUrl() async {
  final home = Platform.environment['HOME'];
  if (home == null) return null;
  final plist = File(
    '$home/Library/Containers/com.maia.app.dev/Data/Library/Preferences/com.maia.app.dev.plist',
  );
  if (!plist.existsSync()) return null;
  final result = await Process.run('defaults', [
    'read',
    plist.path,
    'flutter.maia.server_url',
  ]);
  if (result.exitCode != 0) return null;
  final url = (result.stdout as String).trim();
  return url.isEmpty ? null : url;
}

Map<String, String> _readLocal() {
  final file = _local.existsSync() ? _local : File('client.local');
  if (!file.existsSync()) return {};
  final out = <String, String>{};
  for (final line in file.readAsLinesSync()) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final eq = trimmed.indexOf('=');
    if (eq <= 0) continue;
    out[trimmed.substring(0, eq)] = trimmed.substring(eq + 1);
  }
  return out;
}

Future<void> _writeLocal(String url, String handle, String password) async {
  final file = Directory.current.path.endsWith('evals/chat')
      ? File('client.local')
      : _local;
  await file.parent.create(recursive: true);
  await file.writeAsString(
    'MAIA_EVAL_URL=$url\nMAIA_EVAL_HANDLE=$handle\nMAIA_EVAL_PASSWORD=$password\n',
  );
  if (!Platform.isWindows) {
    await Process.run('chmod', ['600', file.path]);
  }
}

String? _normalise(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  var s = raw.trim();
  if (!s.contains('://')) s = 'http://$s';
  if (!s.endsWith('/')) s = '$s/';
  return s;
}

String _password() {
  const alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final random = Random.secure();
  return List.generate(
    24,
    (_) => alphabet[random.nextInt(alphabet.length)],
  ).join();
}
