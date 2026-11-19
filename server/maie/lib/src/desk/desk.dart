import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One instabox invocation. [stdin] may be a secret. Do not log the command.
class DeskCommand {
  const DeskCommand(this.args, {this.stdin, this.env, this.timeout});

  final List<String> args;
  final String? stdin;
  final Map<String, String>? env;
  final Duration? timeout;
}

class DeskOutput {
  const DeskOutput(this.code, this.stdout, this.stderr);

  final int code;
  final String stdout;
  final String stderr;
}

typedef DeskCall = Future<DeskOutput> Function(DeskCommand command);

/// The person's desktop. One machine, asleep until a task wakes it.
/// Their instabox account pays for the time it runs.
class ComputerDesk {
  ComputerDesk({DeskCall? call, this.bin = 'instabox'}) : _call = call ?? spawn;

  final DeskCall _call;
  final String bin;

  static String machineName(String personId) {
    final hex = personId.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
    final tail = hex.padRight(12, '0').substring(0, 12);
    return 'maie$tail';
  }

  /// Wakes [personId]'s machine and runs [task] on it.
  /// [files] maps a cred_ handle to the real value. The value goes to the
  /// machine on stdin. The task text only names the file.
  Future<String> run({
    required String personId,
    required String task,
    String? apiKey,
    Map<String, String> files = const {},
  }) async {
    final name = machineName(personId);
    final env = apiKey == null || apiKey.isEmpty
        ? null
        : <String, String>{'INSTABOX_API_KEY': apiKey};
    final ready = await _ensure(name, personId, env);
    if (ready.startsWith('Could not')) return ready;
    for (final entry in files.entries) {
      final path = '\$HOME/.maie/vault/${entry.key}';
      final script =
          'umask 077; mkdir -p "\$HOME/.maie/vault"; '
          'cat > "$path"; chmod 600 "$path"';
      final wrote = await _call(
        DeskCommand(
          [bin, 'exec', name, '--stdin', '--', 'bash', '-lc', script],
          stdin: entry.value,
          env: env,
          timeout: const Duration(seconds: 60),
        ),
      );
      if (wrote.code != 0) {
        return '$ready Could not place ${entry.key} in the desktop.';
      }
    }
    final hidden = _hide(task, files.keys);
    final agent = await _call(
      DeskCommand(
        [bin, 'agent', 'prompt', name, '-f', '--json', '--', hidden],
        env: env,
        timeout: const Duration(minutes: 3),
      ),
    );
    final body = _agentText(agent);
    final bill = apiKey == null || apiKey.isEmpty
        ? ' The charge is on the instabox account configured for this '
              'server until they store their own key in the vault under '
              'the name instabox.'
        : ' Their instabox account pays for the time it runs.';
    return '$ready$bill $body';
  }

  Future<String> _ensure(
    String name,
    String personId,
    Map<String, String>? env,
  ) async {
    final got = await _call(
      DeskCommand(
        [bin, 'get', name, '--json'],
        env: env,
        timeout: const Duration(seconds: 20),
      ),
    );
    if (_missing(got)) {
      final created = await _call(
        DeskCommand(
          [
            bin,
            'create',
            '--name',
            name,
            '--template',
            'agent-browser',
            '--meta',
            'maie_person=$personId',
            '--json',
          ],
          env: env,
          timeout: const Duration(minutes: 3),
        ),
      );
      if (created.code != 0) return 'Could not start the desktop.';
      return 'Started $name. It sleeps when idle and wakes for the next task.';
    }
    final status = _status(got.stdout);
    if (status.contains('stop')) {
      final started = await _call(
        DeskCommand(
          [bin, 'start', name],
          env: env,
          timeout: const Duration(minutes: 2),
        ),
      );
      if (started.code != 0) return 'Could not start the desktop.';
      return 'Woke $name. It is the same desktop as last time.';
    }
    if (status.contains('suspend') || status.contains('paus')) {
      final woke = await _call(
        DeskCommand(
          [bin, 'wake', name],
          env: env,
          timeout: const Duration(minutes: 2),
        ),
      );
      if (woke.code != 0) {
        final resumed = await _call(
          DeskCommand(
            [bin, 'resume', name],
            env: env,
            timeout: const Duration(minutes: 2),
          ),
        );
        if (resumed.code != 0) return 'Could not wake the desktop.';
      }
      return 'Woke $name. It is the same desktop as last time.';
    }
    return '$name is already awake. It is the same desktop as last time.';
  }

  static String _hide(String task, Iterable<String> handles) {
    var text = task;
    for (final handle in handles) {
      text = text.replaceAll(
        handle,
        'the file \$HOME/.maie/vault/$handle '
        '(do not print or repeat its contents)',
      );
    }
    return text;
  }

  static bool _missing(DeskOutput out) {
    if (out.code == 4) return true;
    final blob = '${out.stdout} ${out.stderr}'.toLowerCase();
    return blob.contains('not_found') || blob.contains('not found');
  }

  static String _status(String stdout) {
    Object? decoded;
    try {
      decoded = jsonDecode(stdout);
    } on FormatException {
      return stdout.toLowerCase();
    }
    if (decoded is! Map) return '';
    final state = decoded['state'] ?? decoded['status'];
    if (state is String) return state.toLowerCase();
    if (state is Map) {
      final inner = state['status'] ?? state['name'] ?? state['phase'];
      if (inner is String) return inner.toLowerCase();
    }
    return '';
  }

  static String _agentText(DeskOutput out) {
    Object? decoded;
    try {
      decoded = jsonDecode(out.stdout);
    } on FormatException {
      decoded = null;
    }
    if (decoded is Map) {
      final text = decoded['text'] ?? decoded['result'] ?? decoded['message'];
      if (text is String && text.trim().isNotEmpty) return text.trim();
    }
    final raw = out.stdout.trim();
    if (raw.isNotEmpty) {
      return raw.length > 2000 ? raw.substring(0, 2000) : raw;
    }
    return out.code == 0
        ? 'The desktop finished with no output.'
        : 'The desktop agent failed.';
  }

  static Future<DeskOutput> spawn(DeskCommand command) async {
    final merged = Map<String, String>.from(Platform.environment);
    final extra = command.env;
    if (extra != null) merged.addAll(extra);
    final proc = await Process.start(
      command.args.first,
      command.args.sublist(1),
      environment: merged,
    );
    final stdin = command.stdin;
    if (stdin != null) proc.stdin.add(utf8.encode(stdin));
    await proc.stdin.close();
    final out = StringBuffer();
    final err = StringBuffer();
    final stdoutSub = proc.stdout.transform(utf8.decoder).listen(out.write);
    final stderrSub = proc.stderr.transform(utf8.decoder).listen(err.write);
    final limit = command.timeout ?? const Duration(seconds: 30);
    final code = await proc.exitCode.timeout(
      limit,
      onTimeout: () {
        proc.kill();
        return -1;
      },
    );
    await stdoutSub.cancel();
    await stderrSub.cancel();
    return DeskOutput(code, out.toString(), err.toString());
  }
}
