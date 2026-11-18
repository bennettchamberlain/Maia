import 'dart:async';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:maia_api_client/maia_api_client.dart';
import 'package:maia_app/chat/attach.dart';
import 'package:maia_app/chat/chat.dart';
import 'package:maia_app/chat/parts/chat_part_view.dart';
import 'package:maia_app/config/chat_settings_cubit.dart';
import 'package:maia_app/ui/chrome.dart';
import 'package:maia_models/maia_models.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Chat with the Maia agent. Phone: list of conversations, tap to open.
/// Wide: list on the left, conversation on the right.
class ChatPage extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final chat = BlocProvider(
      create: (context) => ChatBloc(
        api: context.read<MaiaApiClient>(),
        provider: () => context.read<ChatSettingsCubit>().state,
      )..add(const ChatStarted()),
      child: const ChatView(),
    );
    try {
      context.read<VoiceCubit>();
      return chat;
    } on Object {
      return BlocProvider(
        create: (context) => VoiceCubit(api: context.read<MaiaApiClient>()),
        child: chat,
      );
    }
  }
}

class ChatView extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 700;
    final hasOpen = context.select<ChatBloc, bool>((b) => b.state.open != null);
    if (wide) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final available = math.max(0, constraints.maxWidth) * 0.42;
          final listWidth = math.min(300, available).toDouble();
          return Row(
            children: [
              SizedBox(width: listWidth, child: const _SessionList()),
              const MaiaDivider.vertical(),
              const Expanded(child: _WideConversation()),
            ],
          );
        },
      );
    }
    return hasOpen ? const _Conversation(showBack: true) : const _SessionList();
  }
}

class _WideConversation extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final hasOpen = context.select<ChatBloc, bool>((b) => b.state.open != null);
    return hasOpen ? const _Conversation() : const _EmptyConversation();
  }
}

class _SessionList extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ChatBloc>().state;
    return Scaffold(
      body: MaiaPane(
        header: MaiaHeader(
          title: 'Chat',
          actions: [
            ShadIconButton.ghost(
              key: const Key('chat_new_button'),
              icon: const Icon(LucideIcons.squarePen, size: 16),
              onPressed: () =>
                  context.read<ChatBloc>().add(const ChatNewSessionRequested()),
            ),
          ],
        ),
        body: _list(context, state),
      ),
    );
  }

  Widget _list(BuildContext context, ChatState state) {
    return switch (state.status) {
      ChatStatus.initial ||
      ChatStatus.loading when state.sessions.isEmpty => const MaiaSkeleton(),
      ChatStatus.failure when state.sessions.isEmpty => MaiaFailure(
        message: state.error ?? 'Could not load chats',
        onRetry: () => context.read<ChatBloc>().add(const ChatStarted()),
      ),
      _ when state.sessions.isEmpty => const _EmptyList(),
      _ => RefreshIndicator(
        onRefresh: () async =>
            context.read<ChatBloc>().add(const ChatStarted()),
        child: ListView.separated(
          itemCount: state.sessions.length,
          separatorBuilder: (_, _) => const MaiaDivider.horizontal(),
          itemBuilder: (context, i) {
            final s = state.sessions[i];
            return Dismissible(
              key: ValueKey(s.id),
              direction: DismissDirection.endToStart,
              background: ColoredBox(
                color: ShadTheme.of(context).colorScheme.destructive,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 20),
                    child: Icon(
                      LucideIcons.trash2,
                      color: ShadTheme.of(context)
                          .colorScheme
                          .destructiveForeground,
                    ),
                  ),
                ),
              ),
              onDismissed: (_) =>
                  context.read<ChatBloc>().add(ChatSessionDeleted(s)),
              child: _SessionTile(session: s, selected: state.open?.id == s.id),
            );
          },
        ),
      ),
    };
  }
}

class _SessionTile extends StatelessWidget {
  const new({required this.session, required this.selected});

  final ChatSession session;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final when = session.lastMessageAt;
    final subtitle =
        '${session.messageCount} messages'
        '${when != null ? ' · ${_ago(when)}' : ''}';
    return Material(
      color: selected ? theme.colorScheme.accent : theme.colorScheme.background,
      child: InkWell(
        onTap: () => context.read<ChatBloc>().add(ChatSessionOpened(session)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(
                LucideIcons.messageCircle,
                size: 16,
                color: theme.colorScheme.mutedForeground,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.title ?? 'New chat',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.p,
                    ),
                    Text(subtitle, style: theme.textTheme.muted),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Conversation extends StatefulWidget {
  const new({this.showBack = false});

  final bool showBack;

  @override
  State<_Conversation> createState() => _ConversationState();
}

class _ConversationState extends State<_Conversation> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    context.read<ChatBloc>().add(ChatMessageSent(text));
    _controller.clear();
  }

  void _insert(String text) {
    final current = _controller.text.trim();
    final next = current.isEmpty ? text : '$current\n\n$text';
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
  }

  Future<void> _pickFile() async {
    final file = await openFile();
    if (file == null || !mounted) return;
    final length = await file.length();
    final bytes = length > 48000 ? null : await file.readAsBytes();
    if (!mounted) return;
    _insert(attachmentNote(name: file.name, length: length, bytes: bytes));
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocListener(
      listeners: [
        BlocListener<VoiceCubit, VoiceState>(
          listenWhen: (p, c) =>
              p.heardSeq != c.heardSeq && (c.lastHeard ?? '').isNotEmpty,
          listener: (context, voice) {
            context.read<ChatBloc>().add(ChatMessageSent(voice.lastHeard!));
          },
        ),
        BlocListener<VoiceCubit, VoiceState>(
          listenWhen: (p, c) =>
              p.transcriptSeq != c.transcriptSeq &&
              (c.transcript ?? '').isNotEmpty,
          listener: (context, voice) => _insert(voice.transcript!),
        ),
      ],
      child: BlocConsumer<ChatBloc, ChatState>(
        listenWhen: (p, c) =>
            p.messages.length != c.messages.length ||
            p.draftReply != c.draftReply,
        listener: (context, state) {
          _scrollToEnd();
          if (state.sending || state.messages.isEmpty) return;
          final last = state.messages.last;
          if (last.role != 'assistant') return;
          unawaited(
            context.read<VoiceCubit>().speakReply(last.id, last.content),
          );
        },
        builder: (context, state) {
          final open = state.open;
          final theme = ShadTheme.of(context);
          return Scaffold(
            body: MaiaPane(
              header: MaiaHeader(
                title: open?.title ?? 'New chat',
                leading: widget.showBack
                    ? ShadIconButton.ghost(
                        icon: const Icon(LucideIcons.arrowLeft, size: 16),
                        onPressed: () => context.read<ChatBloc>().add(
                          const ChatBackToList(),
                        ),
                      )
                    : null,
                actions: const [_VoiceToggle()],
              ),
              body: state.status == ChatStatus.loading && state.messages.isEmpty
                  ? const MaiaSkeleton()
                  : ListView(
                      controller: _scroll,
                      padding: const EdgeInsets.all(12),
                      children: [
                        if (state.messages.isEmpty && !state.sending)
                          const _Hint(),
                        for (final m in state.messages) _Bubble.message(m),
                        if (state.sending)
                          _Bubble.draft(
                            state.draftReply,
                            tools: state.draftTools,
                          ),
                      ],
                    ),
              footer: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (state.error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        state.error!,
                        style: theme.textTheme.small.copyWith(
                          color: theme.colorScheme.destructive,
                        ),
                      ),
                    ),
                  const _VoiceStatusLine(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
                    child: _ComposerActions(onFile: _pickFile),
                  ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: ShadInput(
                              key: const Key('chat_composer'),
                              controller: _controller,
                              minLines: 1,
                              maxLines: 5,
                              textInputAction: TextInputAction.send,
                              onSubmitted: (_) => _send(),
                              placeholder: Text(
                                context.select<VoiceCubit, String>((v) {
                                  if (v.state.listening) {
                                    final partial = v.state.partial.trim();
                                    return partial.isEmpty
                                        ? 'Listening…'
                                        : partial;
                                  }
                                  return 'Ask Maia…';
                                }),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ShadIconButton(
                            key: const Key('chat_send_button'),
                            enabled: !state.sending,
                            onPressed: state.sending ? null : _send,
                            icon: state.sending
                                ? SizedBox.square(
                                    dimension: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color:
                                          theme.colorScheme.primaryForeground,
                                    ),
                                  )
                                : const Icon(LucideIcons.arrowUp, size: 16),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _VoiceToggle extends StatelessWidget {
  const _VoiceToggle();

  @override
  Widget build(BuildContext context) {
    final voice = context.watch<VoiceCubit>().state;
    return ShadIconButton.ghost(
      key: const Key('chat_voice_toggle'),
      icon: Icon(
        voice.enabled ? LucideIcons.volume2 : LucideIcons.volumeOff,
        size: 16,
      ),
      onPressed: () =>
          unawaited(context.read<VoiceCubit>().setEnabled(on: !voice.enabled)),
    );
  }
}

class _VoiceStatusLine extends StatelessWidget {
  const _VoiceStatusLine();

  @override
  Widget build(BuildContext context) {
    final voice = context.watch<VoiceCubit>().state;
    final theme = ShadTheme.of(context);
    final warming =
        voice.sidecarStarting || voice.sidecarLoading && !voice.sidecarLoaded;
    final text =
        voice.error ??
        (warming
            ? 'Starting PersonaVoice on the server. First load can take '
                  'a few minutes. You can still speak on this phone.'
            : voice.sidecarTried && !voice.sidecarLive
            ? 'PersonaVoice is off on the server. Speech stays on this phone.'
            : null);
    if (text == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Text(
        text,
        style: theme.textTheme.small.copyWith(
          color: voice.error != null
              ? theme.colorScheme.destructive
              : theme.colorScheme.mutedForeground,
        ),
      ),
    );
  }
}

class _ComposerActions extends StatelessWidget {
  const _ComposerActions({required this.onFile});

  final Future<void> Function() onFile;

  @override
  Widget build(BuildContext context) {
    final voice = context.watch<VoiceCubit>().state;
    final sending = context.select<ChatBloc, bool>((b) => b.state.sending);
    final transcribing =
        voice.listening && voice.capture == VoiceCapture.transcribe;
    final talking = voice.listening && voice.capture == VoiceCapture.talk;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _Action(
          key: const Key('chat_transcribe_button'),
          label: transcribing ? 'Stop' : 'Transcribe',
          onPressed: () => unawaited(
            context.read<VoiceCubit>().begin(VoiceCapture.transcribe),
          ),
        ),
        _Action(
          key: const Key('chat_talk_button'),
          label: talking ? 'Stop' : 'Talk',
          onPressed: sending
              ? null
              : () => unawaited(
                  context.read<VoiceCubit>().begin(VoiceCapture.talk),
                ),
        ),
        _Action(
          key: const Key('chat_file_button'),
          label: 'File',
          onPressed: () => unawaited(onFile()),
        ),
      ],
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.label, required this.onPressed, super.key});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return ShadButton.outline(
      size: ShadButtonSize.sm,
      onPressed: onPressed,
      child: Text(label),
    );
  }
}

class _Bubble extends StatelessWidget {
  new message(ChatMessage m)
    : role = m.role,
      text = m.content,
      tools = m.toolCalls ?? const [],
      streaming = false;

  const new draft(this.text, {this.tools = const []})
    : role = 'assistant',
      streaming = true;

  final String role;
  final String text;
  final List<ChatToolCall> tools;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final mine = role == 'user';
    final background = mine
        ? theme.colorScheme.primary
        : theme.colorScheme.muted;
    final foreground = mine
        ? theme.colorScheme.primaryForeground
        : theme.colorScheme.foreground;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: mine
              ? MediaQuery.sizeOf(context).width * 0.72
              : MediaQuery.sizeOf(context).width * 0.92,
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: background,
            borderRadius: const BorderRadius.all(Radius.circular(8)),
            border: mine ? null : Border.all(color: theme.colorScheme.border),
          ),
          child: mine
              ? SelectableText(
                  text,
                  style: theme.textTheme.p.copyWith(color: foreground),
                )
              : ChatMessageBody(
                  text: text,
                  foreground: foreground,
                  tools: tools,
                  streaming: streaming,
                ),
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Text(
      'Ask about a memory, a place, or the web. Transcribe types what you '
      'say. Talk sends it and speaks the reply. File attaches something '
      'you pick. The reply comes from the server.',
      textAlign: TextAlign.center,
      style: ShadTheme.of(context).textTheme.muted,
    ),
  );
}

class _EmptyList extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) => const MaiaScrollFill(
    padding: EdgeInsets.all(24),
    child: Text('No chats yet. Start one with the + button.'),
  );
}

class _EmptyConversation extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) =>
      const MaiaEmpty('Pick a chat or start a new one.');
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'now';
  if (d.inHours < 1) return '${d.inMinutes}m';
  if (d.inDays < 1) return '${d.inHours}h';
  return '${d.inDays}d';
}
