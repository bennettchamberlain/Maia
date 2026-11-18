import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// One streamed increment from the harness.
sealed class AgentEvent {
  const AgentEvent();
}

/// Assistant text delta.
final class AgentText extends AgentEvent {
  const AgentText(this.text);
  final String text;
}

/// A tool the model invoked.
///
/// [extra] is everything on the tool-call object besides `index`, `id`,
/// `type`, and `function`. [functionExtra] is everything on `function`
/// besides `name` and `arguments`. Gemini's OpenAI stream puts
/// `thought_signature` at `extra_content.google` on the tool call. The same
/// object also arrives as a sibling of `tool_calls` (a thought part, or the
/// chunk after the call). The follow-up request is rejected if the first
/// function call does not carry it back.
final class AgentToolCall extends AgentEvent {
  const AgentToolCall(
    this.id,
    this.name,
    this.arguments, {
    this.extra,
    this.functionExtra,
  });
  final String id;
  final String name;
  final String arguments;
  final Map<String, dynamic>? extra;
  final Map<String, dynamic>? functionExtra;

  /// OpenAI tool-call object, including provider fields such as a signature.
  Map<String, dynamic> toWire() => {
    'id': id,
    'type': 'function',
    'function': {
      'name': name,
      'arguments': arguments,
      if (functionExtra != null) ...functionExtra!,
    },
    if (extra != null) ...extra!,
  };
}

typedef _PendingTool = ({
  String id,
  String name,
  StringBuffer args,
  Map<String, dynamic> extra,
  Map<String, dynamic> functionExtra,
});

const _deltaOwn = {'role', 'content', 'tool_calls', 'refusal', 'function_call'};

/// Copies [from] into [into] only for keys [into] does not already have.
void _fillMissing(Map<String, dynamic> into, Map<String, dynamic> from) {
  for (final entry in from.entries) {
    if (entry.value == null || into.containsKey(entry.key)) continue;
    into[entry.key] = entry.value;
  }
}

int _toolSlot(Map<String, dynamic> call, Map<int, _PendingTool> buffers) {
  final raw = call['index'];
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  final id = call['id'] as String?;
  if (id != null) {
    for (final entry in buffers.entries) {
      if (entry.value.id == id) return entry.key;
    }
    if (buffers.length == 1) {
      final only = buffers.entries.first;
      final pending = only.value;
      final placeholder =
          pending.id == 'call_${only.key}' && pending.name.isEmpty;
      if (placeholder) return only.key;
    }
    if (buffers.isEmpty) return 0;
    var maxIndex = 0;
    for (final key in buffers.keys) {
      if (key > maxIndex) maxIndex = key;
    }
    return maxIndex + 1;
  }
  if (buffers.isEmpty) return 0;
  var maxIndex = 0;
  for (final key in buffers.keys) {
    if (key > maxIndex) maxIndex = key;
  }
  return maxIndex;
}

/// Puts a signature that arrived outside `tool_calls` onto the first call
/// that does not already have that field. Gemini validates the first
/// function call in the step.
void _attachCarriedSignature(
  Map<int, _PendingTool> buffers,
  Map<String, dynamic> carried,
) {
  if (carried.isEmpty || buffers.isEmpty) return;
  var firstKey = buffers.keys.first;
  for (final key in buffers.keys) {
    if (key < firstKey) firstKey = key;
  }
  _fillMissing(buffers[firstKey]!.extra, carried);
}

/// Copies provider fields from one streamed tool-call chunk onto [into].
/// Nested maps merge. `index`, `id`, `type`, and `function` are not extra.
void mergeToolExtra(Map<String, dynamic> into, Map<String, dynamic> chunk) {
  for (final entry in chunk.entries) {
    if (entry.key == 'index' ||
        entry.key == 'id' ||
        entry.key == 'type' ||
        entry.key == 'function') {
      continue;
    }
    final next = entry.value;
    final current = into[entry.key];
    if (current is Map && next is Map) {
      mergeToolExtra(
        current.cast<String, dynamic>(),
        next.cast<String, dynamic>(),
      );
    } else if (next != null) {
      into[entry.key] = next;
    }
  }
}

/// Terminal event. `model` is whatever the harness reports it used.
final class AgentDone extends AgentEvent {
  const AgentDone({this.model, this.finishReason});
  final String? model;
  final String? finishReason;
}

/// Client for an OpenAI-compatible `/v1/chat/completions` endpoint.
///
/// Parasail (`https://api.parasail.io/v1`), Ollama (`http://127.0.0.1:11434`),
/// and OpenClaw (`http://127.0.0.1:18789`) all speak this. OpenClaw is the
/// only one that keeps its own transcript (`model` starts with `openclaw`).
class AgentClient {
  AgentClient({
    required Uri baseUrl,
    required this.model,
    String? token,
    http.Client? httpClient,
    this.timeout = const Duration(minutes: 5),
  }) : _baseUrl = baseUrl,
       _token = token,
       _http = httpClient ?? http.Client();

  final Uri _baseUrl;
  final String model;
  final String? _token;
  final http.Client _http;
  final Duration timeout;

  Map<String, String> get _headers => {
    'content-type': 'application/json',
    'accept': 'text/event-stream',
    if (_token != null) 'authorization': 'Bearer $_token',
  };

  /// True when the harness keeps its own transcript per `user` (OpenClaw
  /// derives a stable session from the OpenAI `user` field). Then only the
  /// new turn is sent; a generic harness gets the whole history.
  bool get keepsOwnHistory => model.startsWith('openclaw');

  /// `https://api.parasail.io/v1` + `chat/completions` must keep `/v1`.
  /// Gemini's OpenAI-compat root is `/v1beta/openai`, same idea.
  /// `Uri.resolve` drops the last segment when the path has no trailing slash.
  static Uri _join(Uri base, String child) {
    final s = base.toString();
    return Uri.parse(s.endsWith('/') ? '$s$child' : '$s/$child');
  }

  static bool _openaiRoot(Uri base) {
    final segs = base.pathSegments.where((s) => s.isNotEmpty);
    if (segs.isEmpty) return false;
    final last = segs.last;
    return last == 'v1' || last == 'openai';
  }

  static Uri completionsUri(Uri base) {
    if (_openaiRoot(base)) return _join(base, 'chat/completions');
    return _join(base, 'v1/chat/completions');
  }

  static Uri modelsUri(Uri base) {
    if (_openaiRoot(base)) return _join(base, 'models');
    return _join(base, 'v1/models');
  }

  /// Streams a turn. `messages` is in OpenAI shape. `user` is the
  /// conversation key (`conv:<session id>`), reused for the whole chat.
  /// `tools` is the OpenAI tools array; omitted for OpenClaw.
  Stream<AgentEvent> stream(
    List<Map<String, dynamic>> messages, {
    String? user,
    List<Map<String, dynamic>>? tools,
  }) async* {
    Future<http.StreamedResponse> send({required bool withTools}) {
      final req = http.Request('POST', completionsUri(_baseUrl))
        ..headers.addAll(_headers)
        ..body = jsonEncode({
          'model': model,
          'messages': messages,
          'stream': true,
          if (user != null) 'user': user,
          if (withTools && tools != null && tools.isNotEmpty) 'tools': tools,
        });
      return _http.send(req).timeout(timeout);
    }

    var res = await send(withTools: tools != null && tools.isNotEmpty);
    if (res.statusCode == 400 && tools != null && tools.isNotEmpty) {
      final body = await res.stream.bytesToString();
      final lower = body.toLowerCase();
      // A missing thought_signature mentions "tools" but is not "this
      // model has no tools". Retrying without tools sends the same
      // unsigned function call again.
      if (lower.contains('thought_signature') ||
          lower.contains('thought signature')) {
        throw AgentException(res.statusCode, body);
      }
      if (lower.contains('tool')) {
        res = await send(withTools: false);
      } else {
        throw AgentException(res.statusCode, body);
      }
    }
    if (res.statusCode != 200) {
      final body = await res.stream.bytesToString();
      throw AgentException(res.statusCode, body);
    }
    final toolBuffers = <int, _PendingTool>{};
    final carried = <String, dynamic>{};
    String? modelUsed;
    String? finish;
    await for (final line
        in res.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .timeout(timeout)) {
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data.isEmpty) continue;
      if (data == '[DONE]') break;
      final Map<String, dynamic> chunk;
      try {
        chunk = jsonDecode(data) as Map<String, dynamic>;
      } on FormatException {
        continue;
      }
      modelUsed = chunk['model'] as String? ?? modelUsed;
      final choices = chunk['choices'] as List<dynamic>? ?? const [];
      for (final c in choices) {
        final choice = c as Map<String, dynamic>;
        finish = choice['finish_reason'] as String? ?? finish;
        final delta =
            (choice['delta'] ?? choice['message']) as Map<String, dynamic>?;
        if (delta == null) continue;
        final content = delta['content'];
        if (content is String && content.isNotEmpty) {
          yield AgentText(content);
        }
        final aside = <String, dynamic>{};
        mergeToolExtra(aside, {
          for (final entry in delta.entries)
            if (!_deltaOwn.contains(entry.key)) entry.key: entry.value,
        });
        if (aside.isNotEmpty) mergeToolExtra(carried, aside);
        final calls = delta['tool_calls'] as List<dynamic>?;
        if (calls != null) {
          for (final tc in calls) {
            final call = tc as Map<String, dynamic>;
            final idx = _toolSlot(call, toolBuffers);
            final fn = call['function'] as Map<String, dynamic>? ?? const {};
            final existing = toolBuffers[idx];
            final id = call['id'] as String? ?? existing?.id ?? 'call_$idx';
            final name = fn['name'] as String? ?? existing?.name ?? '';
            final buf = existing?.args ?? StringBuffer();
            final args = fn['arguments'];
            if (args is String) buf.write(args);
            final extra = existing?.extra ?? <String, dynamic>{};
            mergeToolExtra(extra, call);
            final functionExtra =
                existing?.functionExtra ?? <String, dynamic>{};
            mergeToolExtra(functionExtra, {
              for (final entry in fn.entries)
                if (entry.key != 'name' && entry.key != 'arguments')
                  entry.key: entry.value,
            });
            toolBuffers[idx] = (
              id: id,
              name: name,
              args: buf,
              extra: extra,
              functionExtra: functionExtra,
            );
          }
        }
        _attachCarriedSignature(toolBuffers, carried);
      }
    }
    _attachCarriedSignature(toolBuffers, carried);
    for (final b in toolBuffers.values) {
      yield AgentToolCall(
        b.id,
        b.name,
        b.args.toString(),
        extra: b.extra.isEmpty ? null : b.extra,
        functionExtra: b.functionExtra.isEmpty ? null : b.functionExtra,
      );
    }
    yield AgentDone(model: modelUsed, finishReason: finish);
  }

  /// Non-streaming convenience for internal callers (titles, summaries).
  Future<String> complete(
    List<Map<String, dynamic>> messages, {
    String? user,
  }) async {
    final buf = StringBuffer();
    await for (final ev in stream(messages, user: user)) {
      if (ev is AgentText) buf.write(ev.text);
    }
    return buf.toString();
  }

  /// `GET /v1/models`; used by `/health` to report whether the harness is up.
  Future<bool> ping() async {
    try {
      final r = await _http
          .get(
            modelsUri(_baseUrl),
            headers: {if (_token != null) 'authorization': 'Bearer $_token'},
          )
          .timeout(const Duration(seconds: 3));
      return r.statusCode == 200;
    } on Object {
      return false;
    }
  }
}

class AgentException implements Exception {
  AgentException(this.status, this.body);
  final int status;
  final String body;

  @override
  String toString() => 'agent $status: $body';
}
