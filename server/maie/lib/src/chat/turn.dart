import 'dart:convert';

import 'package:gel/gel.dart' as gel;
import 'package:maie_api/src/agent.dart';
import 'package:maie_api/src/chat/graphs.dart';
import 'package:maie_api/src/chat/ladder.dart';
import 'package:maie_api/src/chat/tools.dart';
import 'package:maie_api/src/harness/harness.dart';
import 'package:maie_api/src/one/extract.dart';

/// One reply: a loop of next steps. Each step reads the tools that are
/// available right then, runs every call from that step, then looks again.
/// The loop stops when the model answers, when the same call comes back,
/// or when the step budget is spent. OpenClaw keeps its own tools; host
/// tools run for the other providers.
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
  var memoryChecked = false;
  var graphDone = false;
  var followUp = false;
  var missing = false;
  final executed = <String>{};
  final opening = _latestUser(messages);
  final tools = toolbox;
  final book = tools != null && !harness.keepsOwnHistory && opening != null
      ? playbookFor(opening)
      : null;
  if (book != null && tools != null && opening != null) {
    final checkpoint = await runGraph(
      book: book,
      ask: opening,
      call: (tool, arguments) => tools.run(db, tool, arguments),
    );
    _commitGraph(messages, used, emit, checkpoint);
    messages.add({'role': 'system', 'content': checkpoint.note});
    missing = checkpoint.needsAnotherWay;
    followUp = asksToChange(opening) || missing;
    graphDone = !followUp;
    memoryChecked = true;
  }

  for (var round = 0; round < chatStepBudget; round++) {
    final hostTools = toolbox != null && !harness.keepsOwnHistory;
    final offered = !hostTools || graphDone
        ? null
        : followUp
        ? [
            for (final tool in toolbox.definitions)
              if (tool['function'] is Map &&
                  (tool['function'] as Map)['name'] == 'connector')
                tool,
          ]
        : toolbox.definitions;
    final names = offered == null ? const <String>[] : toolNames(offered);
    final request = modelFrame(messages);
    if (hostTools && used.isNotEmpty) {
      request.add({
        'role': 'system',
        'content': followUp
            ? (missing ? graphMissingCue : graphChangeCue)
            : graphDone
            ? graphAnswerCue
            : answerCue,
      });
    }
    final calls = <AgentToolCall>[];
    final roundText = StringBuffer();
    final spoken = StringBuffer();
    var spokenEmitted = 0;
    await for (final ev in harness.stream(
      request,
      user: user,
      tools: offered != null && offered.isNotEmpty ? offered : null,
    )) {
      switch (ev) {
        case AgentText(text: final t):
          roundText.write(t);
          spoken.write(t);
          final safe = publicChatText(spoken.toString());
          if (safe.length > spokenEmitted) {
            final chunk = safe.substring(spokenEmitted);
            text.write(chunk);
            emit('delta', {'text': chunk});
            spokenEmitted = safe.length;
          }
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
    final steered = steer?.call();
    if (steered != null) {
      for (final pending in calls) {
        _record(messages, used, emit, pending, skippedToolResult);
      }
      messages.add({'role': 'user', 'content': steered});
      continue;
    }
    var ran = false;
    var repeated = false;
    for (final call in calls) {
      final key = '${call.name}\n${call.arguments}';
      if (executed.contains(key)) {
        repeated = true;
        continue;
      }
      if (names.contains(call.name) &&
          consultMemoryFirst(call.name) &&
          !memoryChecked &&
          toolbox.isOn('memory_search')) {
        memoryChecked = true;
        final query = _latestUser(messages) ?? '';
        final memory = await toolbox.run(
          db,
          'memory_search',
          jsonEncode({'query': query, 'limit': 6}),
        );
        used.add({
          'name': 'memory_search',
          'arguments': jsonEncode({'query': query}),
          'result': memory,
        });
        emit('tool', {
          'name': 'memory_search',
          'arguments': jsonEncode({'query': query}),
          'result': memory,
        });
        if (!runAlongsideEmptyMemory(call.name, memory)) {
          _record(messages, used, emit, call, memoryFirstNote(query, memory));
          ran = true;
          continue;
        }
      }
      executed.add(key);
      ran = true;
      var result = names.contains(call.name)
          ? await toolbox.run(db, call.name, call.arguments)
          : 'Tool ${call.name} is not available. '
                'Tools now: ${names.isEmpty ? 'none' : names.join(', ')}.';
      if (call.name == 'sync' &&
          result.contains('Nothing is pulling') &&
          names.contains('connector')) {
        final platform = _syncPlatform(call.arguments);
        if (platform.isNotEmpty) {
          final reading = await toolbox.run(
            db,
            'connector',
            jsonEncode({
              'platform': platform,
              'intent': _latestUser(messages) ?? 'list recent records',
            }),
          );
          used.add({
            'name': 'connector',
            'arguments': jsonEncode({'platform': platform}),
            'result': reading,
          });
          emit('tool', {
            'name': 'connector',
            'arguments': jsonEncode({'platform': platform}),
            'result': reading,
          });
          result = '$result\n$reading';
        }
      }
      _record(messages, used, emit, call, result);
    }
    if (!ran && repeated) break;
    final incoming = steer?.call();
    if (incoming != null) {
      messages.add({'role': 'user', 'content': incoming});
    }
  }

  if (toolbox != null &&
      !harness.keepsOwnHistory &&
      used.isNotEmpty &&
      text.toString().trim().isEmpty) {
    final request = [
      ...modelFrame(messages),
      {'role': 'system', 'content': graphDone ? graphAnswerCue : answerCue},
    ];
    final answerSpoken = StringBuffer();
    var answerEmitted = 0;
    await for (final ev in harness.stream(request, user: user)) {
      switch (ev) {
        case AgentText(text: final t):
          answerSpoken.write(t);
          final safe = publicChatText(answerSpoken.toString());
          if (safe.length > answerEmitted) {
            final chunk = safe.substring(answerEmitted);
            text.write(chunk);
            emit('delta', {'text': chunk});
            answerEmitted = safe.length;
          }
        case AgentToolCall():
          break;
        case AgentDone(model: final usedModel, :final finishReason):
          model = usedModel ?? model;
          emit('finish', {'model': model, 'reason': finishReason});
      }
    }
  }

  return (text: text.toString(), tools: used, model: model);
}

void _commitGraph(
  List<Map<String, dynamic>> messages,
  List<Map<String, dynamic>> used,
  void Function(String event, Object data) emit,
  GraphCheckpoint checkpoint,
) {
  for (final wave in checkpoint.waves) {
    messages.add({
      'role': 'assistant',
      'content': null,
      'tool_calls': [
        for (final call in wave)
          {
            'id': call.id,
            'type': 'function',
            'function': {'name': call.tool, 'arguments': call.arguments},
          },
      ],
    });
    for (final call in wave) {
      used.add({
        'name': call.tool,
        'arguments': call.arguments,
        'result': call.result,
      });
      emit('tool', {
        'name': call.tool,
        'arguments': call.arguments,
        'result': call.result,
      });
      messages.add({
        'role': 'tool',
        'tool_call_id': call.id,
        'tool_name': call.tool,
        'content': call.result,
      });
    }
  }
}

String _syncPlatform(String arguments) {
  try {
    final decoded = jsonDecode(arguments);
    if (decoded is! Map) return '';
    final platform = '${decoded['platform'] ?? ''}'.trim();
    if (platform.isEmpty || platform == 'all') return '';
    return platform;
  } on FormatException {
    return '';
  }
}

String? _latestUser(List<Map<String, dynamic>> messages) {
  for (final message in messages.reversed) {
    if (message['role'] != 'user') continue;
    final text = '${message['content'] ?? ''}'.trim();
    if (text.isEmpty || text == nativeToolCorrection) continue;
    return text.length <= 240 ? text : text.substring(0, 240);
  }
  return null;
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
