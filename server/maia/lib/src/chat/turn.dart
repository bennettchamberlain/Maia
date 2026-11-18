import 'package:gel/gel.dart' as gel;
import 'package:maia_api/src/agent.dart';
import 'package:maia_api/src/chat/tools.dart';
import 'package:maia_api/src/harness/harness.dart';

/// One reply: a short loop of next steps. Each step reads the tools that
/// are available right then, runs at most one of them, then looks again.
/// OpenClaw keeps its own tools; host tools run for the other providers.
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
  String? lastKey;

  for (var round = 0; round < chatStepBudget; round++) {
    final hostTools = toolbox != null && !harness.keepsOwnHistory;
    final offered = hostTools ? toolbox.definitions : null;
    final names = offered == null ? const <String>[] : toolNames(offered);
    final request = [for (final m in messages) Map<String, dynamic>.from(m)];
    if (hostTools) {
      request.add({
        'role': 'user',
        'content': nextStepNote(
          tools: names,
          step: round,
          budget: chatStepBudget,
        ),
      });
    }
    final calls = <AgentToolCall>[];
    final roundText = StringBuffer();
    await for (final ev in harness.stream(
      request,
      user: user,
      tools: offered != null && offered.isNotEmpty ? offered : null,
    )) {
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
      'content': roundText.isEmpty ? null : roundText.toString(),
      'tool_calls': [for (final c in calls) c.toWire()],
    });
    final spoken = steer?.call();
    if (spoken != null) {
      for (final pending in calls) {
        _record(messages, used, emit, pending, skippedToolResult);
      }
      messages.add({'role': 'user', 'content': spoken});
      continue;
    }
    final call = calls.first;
    final key = '${call.name}\n${call.arguments}';
    if (key == lastKey) break;
    lastKey = key;
    final result = names.contains(call.name)
        ? await toolbox.run(db, call.name, call.arguments)
        : 'Tool ${call.name} is not available. '
              'Tools now: ${names.isEmpty ? 'none' : names.join(', ')}.';
    _record(messages, used, emit, call, result);
    for (final extra in calls.skip(1)) {
      _record(messages, used, emit, extra, heldStepResult);
    }
    final incoming = steer?.call();
    if (incoming != null) {
      messages.add({'role': 'user', 'content': incoming});
    }
  }

  return (text: text.toString(), tools: used, model: model);
}

void _record(
  List<Map<String, dynamic>> messages,
  List<Map<String, dynamic>> used,
  void Function(String event, Object data) emit,
  AgentToolCall call,
  String result,
) {
  used.add({'name': call.name, 'arguments': call.arguments, 'result': result});
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
