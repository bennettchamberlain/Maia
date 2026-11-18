import 'package:gel/gel.dart' as gel;
import 'package:maia_api/src/agent.dart';
import 'package:maia_api/src/chat/tools.dart';

/// One model round-trip plus tool calls, streamed to the client as SSE
/// payloads (`delta`, `tool`). OpenClaw keeps its own tools; host tools
/// run only for Parasail / Ollama.
Future<({String text, List<Map<String, dynamic>> tools, String? model})>
runChatTurn({
  required AgentClient harness,
  required List<Map<String, dynamic>> frame,
  required ChatToolbox? toolbox,
  required gel.Client db,
  required void Function(String event, Object data) emit,
  String? user,
}) async {
  final messages = [for (final m in frame) Map<String, dynamic>.from(m)];
  final used = <Map<String, dynamic>>[];
  final text = StringBuffer();
  var model = harness.model;
  final tools = toolbox == null || harness.keepsOwnHistory
      ? null
      : toolbox.definitions;

  for (var round = 0; round < 6; round++) {
    final calls = <AgentToolCall>[];
    await for (final ev in harness.stream(messages, user: user, tools: tools)) {
      switch (ev) {
        case AgentText(text: final t):
          text.write(t);
          emit('delta', {'text': t});
        case AgentToolCall():
          calls.add(ev);
        case AgentDone(model: final usedModel, :final finishReason):
          model = usedModel ?? model;
          emit('finish', {'model': model, 'reason': finishReason});
      }
    }
    if (calls.isEmpty || toolbox == null) break;

    messages.add({
      'role': 'assistant',
      'content': text.isEmpty ? null : text.toString(),
      'tool_calls': [for (final c in calls) c.toWire()],
    });
    for (final call in calls) {
      final result = await toolbox.run(db, call.name, call.arguments);
      used.add({
        'name': call.name,
        'arguments': call.arguments,
        'result': result,
        'call_id': call.id,
        if (call.extra != null) 'extra': call.extra,
        if (call.functionExtra != null) 'function_extra': call.functionExtra,
      });
      emit('tool', {
        'name': call.name,
        'arguments': call.arguments,
        'result': result,
      });
      messages.add({
        'role': 'tool',
        'tool_call_id': call.id,
        'content': result,
      });
    }
  }

  return (text: text.toString(), tools: used, model: model);
}

/// OpenAI messages for a stored transcript.
///
/// Plain rows stay `{role, content}`. An assistant row is replayed with its
/// `tool_calls` only when one of them still has a thought signature. Older
/// rows that stored the tool result and not the signature stay as text, so
/// a chat from before this fix is not turned into an unsigned function call.
List<Map<String, dynamic>> replayChatHistory(
  List<Map<String, dynamic>> history,
) {
  final frame = <Map<String, dynamic>>[];
  for (final message in history) {
    final role = message['role'];
    if (role != 'user' && role != 'assistant') continue;
    final tools = message['tool_calls'];
    if (role == 'assistant' && tools is List && _replayable(tools)) {
      // The signature was attached when the model asked for the tool, before
      // it wrote the reply. The reply is its own assistant message after
      // the tool results.
      frame.add({
        'role': 'assistant',
        'content': null,
        'tool_calls': [
          for (final raw in tools)
            if (raw is Map &&
                Map<String, dynamic>.from(raw)['call_id'] is String)
              _wireFromStored(Map<String, dynamic>.from(raw)),
        ],
      });
      for (final raw in tools) {
        if (raw is! Map) continue;
        final tool = Map<String, dynamic>.from(raw);
        final id = tool['call_id'];
        if (id is! String || id.isEmpty) continue;
        frame.add({
          'role': 'tool',
          'tool_call_id': id,
          'content': tool['result'] ?? '',
        });
      }
      final content = message['content'];
      if (content is String &&
          content.trim().isNotEmpty &&
          content != '(no reply)') {
        frame.add({'role': 'assistant', 'content': content});
      }
      continue;
    }
    frame.add({'role': role, 'content': message['content']});
  }
  return frame;
}

bool _replayable(List<dynamic> tools) {
  for (final raw in tools) {
    if (raw is! Map) continue;
    final tool = Map<String, dynamic>.from(raw);
    if (tool['call_id'] is! String) continue;
    if (_hasSignature(tool['extra']) || _hasSignature(tool['function_extra'])) {
      return true;
    }
  }
  return false;
}

bool _hasSignature(Object? value) {
  if (value is Map) {
    for (final entry in value.entries) {
      final key = entry.key.toString();
      if ((key == 'thought_signature' || key == 'thoughtSignature') &&
          entry.value is String &&
          (entry.value as String).isNotEmpty) {
        return true;
      }
      if (_hasSignature(entry.value)) return true;
    }
  } else if (value is List) {
    for (final item in value) {
      if (_hasSignature(item)) return true;
    }
  }
  return false;
}

Map<String, dynamic> _wireFromStored(Map<String, dynamic> tool) {
  final functionExtra = tool['function_extra'];
  final extra = tool['extra'];
  return {
    'id': tool['call_id'],
    'type': 'function',
    'function': {
      'name': tool['name'],
      'arguments': tool['arguments'] ?? '',
      if (functionExtra is Map) ...Map<String, dynamic>.from(functionExtra),
    },
    if (extra is Map) ...Map<String, dynamic>.from(extra),
  };
}
