import 'package:gel/gel.dart' as gel;
import 'package:maia_api/src/agent.dart';
import 'package:maia_api/src/chat/tools.dart';
import 'package:maia_api/src/harness/harness.dart';

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
  String? Function()? steer,
}) async {
  final messages = [for (final m in frame) Map<String, dynamic>.from(m)];
  final used = <Map<String, dynamic>>[];
  final text = StringBuffer();
  var model = harness.model;
  var corrected = false;
  final tools = toolbox == null || harness.keepsOwnHistory
      ? null
      : toolbox.definitions;

  for (var round = 0; round < 6; round++) {
    final calls = <AgentToolCall>[];
    final roundText = StringBuffer();
    await for (final ev in harness.stream(messages, user: user, tools: tools)) {
      switch (ev) {
        case AgentText(text: final t):
          roundText.write(t);
          text.write(t);
          emit('delta', {'text': t});
        case AgentToolCall():
          calls.add(ev);
        case AgentDone(model: final usedModel, :final finishReason):
          model = usedModel ?? model;
          emit('finish', {'model': model, 'reason': finishReason});
      }
    }
    if (calls.isEmpty || toolbox == null) {
      if (!corrected &&
          toolbox != null &&
          looksLikePrintedToolCall(roundText.toString())) {
        corrected = true;
        text.clear();
        emit('replace', {'text': ''});
        messages.add({'role': 'assistant', 'content': roundText.toString()});
        messages.add({'role': 'user', 'content': nativeToolCorrection});
        continue;
      }
      final incoming = steer?.call();
      if (incoming != null) {
        messages.add({'role': 'user', 'content': incoming});
        continue;
      }
      break;
    }

    messages.add({
      'role': 'assistant',
      'content': text.isEmpty ? null : text.toString(),
      'tool_calls': [for (final c in calls) c.toWire()],
    });
    var steered = false;
    for (var i = 0; i < calls.length; i++) {
      if (i > 0) {
        final incoming = steer?.call();
        if (incoming != null) {
          for (final call in calls.skip(i)) {
            _skipped(messages, used, emit, call);
          }
          messages.add({'role': 'user', 'content': incoming});
          steered = true;
          break;
        }
      }
      final call = calls[i];
      final result = await toolbox.run(db, call.name, call.arguments);
      used.add({
        'name': call.name,
        'arguments': call.arguments,
        'result': result,
      });
      emit('tool', {
        'name': call.name,
        'arguments': call.arguments,
        'result': result,
      });
      messages.add({
        'role': 'tool',
        'tool_call_id': call.id,
        'tool_name': call.name,
        'content': result,
      });
    }
    final after = steered ? null : steer?.call();
    if (after != null) {
      messages.add({'role': 'user', 'content': after});
    }
  }

  return (text: text.toString(), tools: used, model: model);
}

void _skipped(
  List<Map<String, dynamic>> messages,
  List<Map<String, dynamic>> used,
  void Function(String event, Object data) emit,
  AgentToolCall call,
) {
  used.add({
    'name': call.name,
    'arguments': call.arguments,
    'result': skippedToolResult,
  });
  emit('tool', {
    'name': call.name,
    'arguments': call.arguments,
    'result': skippedToolResult,
  });
  messages.add({
    'role': 'tool',
    'tool_call_id': call.id,
    'tool_name': call.name,
    'content': skippedToolResult,
  });
}
