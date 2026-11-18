import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:maia_api/src/config.dart';
import 'package:maia_api/src/voice/polargrid.dart';

/// Starts the local PersonaVoice process and asks it to load weights.
///
/// PolarGrid is first when a key is set *and* the edge answers. A dead
/// key, a down region, or a timeout falls through to the local sidecar.
/// If that binary is missing too, [start] returns `available: false`
/// instead of throwing so chat still types.
///
/// The HTTP port comes up before the 16 GB model. Local [start] waits
/// for the port, then kicks a background load and returns. The sidecar
/// keeps weights resident for [Config.voiceKeepAlive] after the last
/// touch.
class VoiceSupervisor {
  /// [polarCheck] is the PolarGrid probe. Tests inject it. Production
  /// hits `/v1/models` through [PolarGridVoice.reachable].
  VoiceSupervisor(
    this.config, {
    PolarGridVoice? polar,
    Future<bool> Function()? polarCheck,
  }) : polar = polar ?? PolarGridVoice(config),
       _polarCheck = polarCheck;

  final Config config;

  /// Hosted PersonaPlex. Idle until a client opens `/voice/live`.
  final PolarGridVoice polar;
  final Future<bool> Function()? _polarCheck;
  Process? _child;
  Future<void>? _spawn;
  DateTime? _polarAt;
  bool? _polarOk;

  Uri get _base => Uri.parse(config.voiceUrl);

  /// True when PolarGrid accepted this key within the last 20 seconds.
  Future<bool> polarReachable({bool fresh = false}) async {
    if (!polar.enabled) return false;
    final now = DateTime.now();
    if (!fresh &&
        _polarOk != null &&
        _polarAt != null &&
        now.difference(_polarAt!) < const Duration(seconds: 20)) {
      return _polarOk!;
    }
    try {
      _polarOk = _polarCheck != null
          ? await _polarCheck!()
          : await polar.reachable();
    } on Object {
      _polarOk = false;
    }
    _polarAt = now;
    return _polarOk!;
  }

  Future<Map<String, dynamic>?> peek() async {
    if (await polarReachable()) return polar.status();
    return _localPeek();
  }

  /// PolarGrid if it answers, else spawn the sidecar, else unavailable.
  Future<Map<String, dynamic>> start() async {
    if (await polarReachable(fresh: true)) return polar.status();
    try {
      return await _startLocal();
    } on Object {
      return _down(
        polar.enabled
            ? 'PolarGrid is unreachable and local PersonaPlex is not available.'
            : 'PersonaVoice is not available.',
      );
    }
  }

  Future<Map<String, dynamic>> stop() async {
    if (await polarReachable()) {
      await polar.close();
      return polar.status();
    }
    try {
      await http
          .post(
            Uri.parse('${config.voiceUrl}/api/engine'),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({'on': false}),
          )
          .timeout(const Duration(seconds: 20));
    } on Object {
      // Process may already be down.
    }
    return _wrap(await _localPeek());
  }

  Future<Map<String, dynamic>?> _localPeek() async {
    try {
      final r = await http
          .get(Uri.parse('${config.voiceUrl}/api/status'))
          .timeout(const Duration(milliseconds: 800));
      if (r.statusCode != 200) return null;
      final body = jsonDecode(r.body);
      return body is Map<String, dynamic> ? body : null;
    } on Object {
      return null;
    }
  }

  Future<Map<String, dynamic>> _startLocal() async {
    var remote = await _localPeek();
    if (remote == null) {
      await (_spawn ??= _spawnSidecar());
      remote = await _waitForPort();
    }
    if (remote == null) {
      throw StateError(
        'PersonaVoice did not bind ${_base.origin}. '
        'Is ${config.voiceBin} installed?',
      );
    }
    final engine = remote['engine'] is Map
        ? Map<String, dynamic>.from(remote['engine'] as Map)
        : const <String, dynamic>{};
    if (engine['loaded'] != true) {
      unawaited(_kickLoad());
      await Future<void>.delayed(const Duration(milliseconds: 250));
      remote = await _localPeek() ?? remote;
    } else {
      unawaited(_kickLoad());
    }
    return _wrap(remote);
  }

  Map<String, dynamic> _wrap(Map<String, dynamic>? remote) {
    final engine = remote?['engine'] is Map
        ? Map<String, dynamic>.from(remote!['engine'] as Map)
        : const <String, dynamic>{};
    return {
      'available': remote != null,
      'url': config.voiceUrl,
      'starting': engine['loading'] == true,
      if (remote != null) ...remote,
    };
  }

  Map<String, dynamic> _down(String reason) => {
    'available': false,
    'url': config.voiceUrl,
    'starting': false,
    'reason': reason,
    'engine': {'loaded': false, 'loading': false},
  };

  Future<void> _kickLoad() async {
    try {
      await http
          .post(
            Uri.parse('${config.voiceUrl}/api/engine'),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({'on': true}),
          )
          .timeout(const Duration(seconds: 8));
    } on Object {
      // Load continues on the sidecar; status polling sees it.
    }
  }

  Future<void> _spawnSidecar() async {
    final bin = config.voiceBin;
    if (bin == null || !File(bin).existsSync()) {
      throw StateError(
        'No maia-voice binary. Set VOICE_BIN or install the '
        'sidecar venv under server/maia_voice.',
      );
    }
    final state = Directory(
      '${Platform.environment['HOME']}/.local/state/maia-voice',
    );
    state.createSync(recursive: true);
    final log = File('${state.path}/sidecar.log');
    final sink = log.openWrite(mode: FileMode.append);
    final port = _base.hasPort ? _base.port : 8998;
    final env = Map<String, String>.from(Platform.environment)
      ..['VOICE_HOST'] = '0.0.0.0'
      ..['VOICE_PORT'] = '$port'
      ..['VOICE_AUTOLOAD'] = '1'
      ..['VOICE_KEEP_ALIVE_SEC'] = '${config.voiceKeepAlive.inSeconds}'
      ..['MAIA_API_URL'] =
          Platform.environment['MAIA_API_URL'] ??
          'http://127.0.0.1:${config.port}';
    var dead = false;
    _child = await Process.start(
      bin,
      const [],
      workingDirectory: config.voiceWorkdir,
      environment: env,
      mode: ProcessStartMode.normal,
    );
    _child!.stdout.listen(sink.add);
    _child!.stderr.listen(sink.add);
    unawaited(
      _child!.exitCode.then((code) {
        dead = true;
        _child = null;
        _spawn = null;
        sink.writeln('sidecar exited $code');
        unawaited(sink.close());
      }),
    );
    _spawnDead = () => dead;
  }

  bool Function() _spawnDead = () => false;

  Future<Map<String, dynamic>?> _waitForPort() async {
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (DateTime.now().isBefore(deadline)) {
      final remote = await _localPeek();
      if (remote != null) return remote;
      if (_spawnDead()) break;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return _localPeek();
  }
}
