import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:maie_app/chat/bloc/chat_bloc.dart';
import 'package:maie_app/chat/voice_cubit.dart';
import 'package:maie_app/ui/glass.dart';
import 'package:maie_models/maie_models.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// The trailing panel on a wide window. Session facts and voice.
class ChatInspector extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final state = context.watch<ChatBloc>().state;
    final open = state.open;
    final field = watchField(context);
    final title = open?.title ?? 'Maie';
    final letter = title.trim().isEmpty ? 'M' : title.trim().substring(0, 1);
    return ColoredBox(
      color: field ? Colors.transparent : theme.colorScheme.background,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.all(Radius.circular(12)),
                  border: Border.all(color: theme.colorScheme.border),
                ),
                child: Text(letter.toUpperCase(), style: theme.textTheme.small),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.h4,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text('Activity', style: theme.textTheme.small),
          const SizedBox(height: 8),
          Text(_activity(state), style: theme.textTheme.muted),
          if (open != null && open.topics.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final topic in open.topics)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(topic, style: theme.textTheme.small),
              ),
          ],
          const SizedBox(height: 20),
          Text('Voice', style: theme.textTheme.small),
          const SizedBox(height: 8),
          const _VoiceLine(),
          const SizedBox(height: 8),
          const Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _VoiceButton(
                label: 'Transcribe',
                capture: VoiceCapture.transcribe,
              ),
              _VoiceButton(label: 'Talk', capture: VoiceCapture.talk),
            ],
          ),
        ],
      ),
    );
  }

  String _activity(ChatState state) {
    final names = <String>[];
    void add(List<ChatToolCall> calls) {
      for (final call in calls) {
        if (call.name.isEmpty || names.contains(call.name)) continue;
        names.add(call.name);
      }
    }

    for (final message in state.messages) {
      add(message.toolCalls ?? const []);
    }
    add(state.draftTools);
    final count = state.messages.length;
    final tools = names.take(4).join(', ');
    if (count == 0 && tools.isEmpty) return 'Nothing in this chat yet.';
    final line = count == 1 ? '1 message' : '$count messages';
    if (tools.isEmpty) return line;
    return '$line · $tools';
  }
}

class _VoiceLine extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final voice = context.watch<VoiceCubit>().state;
    final theme = ShadTheme.of(context);
    final text =
        voice.error ??
        (voice.listening
            ? 'Listening'
            : voice.speaking
            ? 'Speaking'
            : 'Off');
    return Text(
      text,
      style: theme.textTheme.muted.copyWith(
        color: voice.error != null ? theme.colorScheme.destructive : null,
      ),
    );
  }
}

class _VoiceButton extends StatelessWidget {
  const new({required this.label, required this.capture});

  final String label;
  final VoiceCapture capture;

  @override
  Widget build(BuildContext context) {
    final voice = context.watch<VoiceCubit>().state;
    final selected = voice.listening && voice.capture == capture;
    void press() => unawaited(context.read<VoiceCubit>().begin(capture));
    if (selected) {
      return ShadButton(
        size: ShadButtonSize.sm,
        onPressed: press,
        child: Text(label),
      );
    }
    return ShadButton.outline(
      size: ShadButtonSize.sm,
      onPressed: press,
      child: Text(label),
    );
  }
}
