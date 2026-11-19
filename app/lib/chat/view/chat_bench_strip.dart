import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:maia_app/chat/bloc/chat_bloc.dart';
import 'package:maia_app/chat/chat_turn_bench.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// True while this app is walking the ladder, so Talk does not read it aloud.
bool chatBenchRunning = false;

/// Bumps when a run starts so the shell can show Chat.
final chatBenchShow = ValueNotifier<int>(0);

/// The check list for this Flutter instance. Run walks the open chat,
/// one question at a time, and marks each row as the reply lands.
class ChatBenchStrip extends StatefulWidget {
  const new({super.key});

  @override
  State<ChatBenchStrip> createState() => _ChatBenchStripState();
}

var _extensionReady = false;
_ChatBenchStripState? _live;

class _ChatBenchStripState extends State<ChatBenchStrip> {
  var _running = false;
  var _cursor = -1;
  final _notes = <String, String?>{};

  @override
  void initState() {
    super.initState();
    _live = this;
    _registerStart();
  }

  @override
  void dispose() {
    if (_live == this) _live = null;
    super.dispose();
  }

  void _registerStart() {
    if (_extensionReady) return;
    _extensionReady = true;
    developer.registerExtension('ext.maia.bench', (method, params) async {
      final live = _live;
      if (live != null && live.mounted && !live._running) {
        unawaited(live._run());
      }
      return developer.ServiceExtensionResponse.result('{"ok":true}');
    });
  }

  Future<void> _run() async {
    if (_running) return;
    final bloc = context.read<ChatBloc>();
    setState(() {
      _running = true;
      chatBenchRunning = true;
      _cursor = -1;
      _notes.clear();
    });
    chatBenchShow.value++;
    final previous = bloc.state.open?.id;
    bloc.add(const ChatNewSessionRequested());
    try {
      await bloc.stream
          .firstWhere(
            (s) =>
                s.open != null &&
                s.open!.id != previous &&
                s.messages.isEmpty &&
                !s.sending,
          )
          .timeout(const Duration(seconds: 20));
    } on Object {
      if (mounted) {
        setState(() {
          _running = false;
          chatBenchRunning = false;
        });
      }
      return;
    }
    final sessionId = bloc.state.open?.id;
    for (var i = 0; i < chatTurnBenchCases.length; i++) {
      if (!mounted) {
        chatBenchRunning = false;
        return;
      }
      final item = chatTurnBenchCases[i];
      setState(() => _cursor = i);
      final before = bloc.state.messages.length;
      final tools = <String>[];
      bloc.add(ChatMessageSent(item.prompt));
      try {
        final done = await bloc.stream
            .firstWhere((s) {
              for (final call in s.draftTools) {
                if (!tools.contains(call.name)) tools.add(call.name);
              }
              if (s.open?.id != sessionId || s.sending) return false;
              final grew = s.messages.length > before;
              final reply = grew && s.messages.last.role == 'assistant';
              return reply || (s.error != null && grew);
            })
            .timeout(const Duration(minutes: 2));
        final last = done.messages.last;
        final stored = last.toolCalls?.map((call) => call.name) ?? const [];
        final names = stored.isEmpty ? tools : stored;
        final calls = last.toolCalls;
        final toolText = calls == null
            ? ''
            : [for (final call in calls) call.result ?? ''].join('\n');
        final note = last.role == 'assistant'
            ? item.checkReply(
                last.content,
                toolNames: names,
                toolText: toolText,
              )
            : (done.error ?? 'no reply');
        if (mounted) setState(() => _notes[item.id] = note);
      } on Object catch (e) {
        if (mounted) setState(() => _notes[item.id] = '$e');
      }
    }
    if (sessionId != null && mounted) {
      bloc.add(ChatSessionRenamed(sessionId, 'Checks'));
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _cursor = -1;
      chatBenchRunning = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.colorScheme.border)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text('Checks', style: theme.textTheme.small)),
                ShadButton.outline(
                  size: ShadButtonSize.sm,
                  enabled: !_running,
                  onPressed: _run,
                  child: Text(_running ? 'Running' : 'Run'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            for (var i = 0; i < chatTurnBenchCases.length; i++)
              _CaseLine(
                label: chatTurnBenchCases[i].id,
                asking: _running && _cursor == i,
                seen: _notes.containsKey(chatTurnBenchCases[i].id),
                note: _notes[chatTurnBenchCases[i].id],
              ),
          ],
        ),
      ),
    );
  }
}

String _mark({required bool asking, required bool seen, required bool failed}) {
  if (asking) return 'asking';
  if (!seen) return 'waiting';
  if (failed) return 'fail';
  return 'pass';
}

class _CaseLine extends StatelessWidget {
  const new({
    required this.label,
    required this.asking,
    required this.seen,
    required this.note,
  });

  final String label;
  final bool asking;
  final bool seen;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final mark = _mark(asking: asking, seen: seen, failed: note != null);
    final color = mark == 'fail'
        ? theme.colorScheme.destructive
        : mark == 'pass'
        ? theme.colorScheme.foreground
        : theme.colorScheme.mutedForeground;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.small,
            ),
          ),
          Expanded(
            child: Text(
              mark == 'fail' ? note! : mark,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.small.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}
