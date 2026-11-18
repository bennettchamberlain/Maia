import 'dart:async';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:maia_api_client/maia_api_client.dart';
import 'package:maia_app/chat/attach.dart';
import 'package:maia_app/chat/chat.dart';
import 'package:maia_app/chat/parts/chat_part_view.dart';
import 'package:maia_app/chat/quote.dart';
import 'package:maia_app/chat/view/composer.dart';
import 'package:maia_app/chat/view/file_chip.dart';
import 'package:maia_app/chat/view/timeline_column.dart';
import 'package:maia_app/config/chat_settings_cubit.dart';
import 'package:maia_app/ui/chrome.dart';
import 'package:maia_app/ui/fault.dart';
import 'package:maia_app/ui/selection_menu.dart';
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
      child: const _CloseWhenPaused(child: ChatView()),
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
              SizedBox(width: listWidth, child: const TimelineColumn()),
              const MaiaDivider.vertical(),
              const Expanded(child: _WideConversation()),
            ],
          );
        },
      );
    }
    return hasOpen
        ? const _Conversation(showBack: true)
        : const TimelineColumn();
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

class _Conversation extends StatefulWidget {
  const new({this.showBack = false});

  final bool showBack;

  @override
  State<_Conversation> createState() => _ConversationState();
}

class _ConversationState extends State<_Conversation> {
  final _composer = GlobalKey<ChatComposerState>();
  final _scroll = ScrollController();
  var _picking = false;
  String? _notice;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    final text = _composer.currentState?.take();
    if (text == null) return;
    context.read<ChatBloc>().add(ChatMessageSent(text));
  }

  Future<void> _pickFile() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final file = await openFile();
      if (file == null || !mounted) return;
      await _composer.currentState?.addPicked(file);
      if (mounted) setState(() => _notice = null);
    } on Object catch (e) {
      if (!mounted) return;
      rememberFault(context.read<MaiaApiClient>(), 'attach file', e);
      setState(() => _notice = shownFault(e));
    } finally {
      if (mounted) setState(() => _picking = false);
    }
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
          listener: (context, voice) {
            final quoted = quotedSpeech(voice.transcript!);
            if (quoted.isEmpty) return;
            context.read<ChatBloc>().add(
              ChatAsideAdded(role: 'quote', content: quoted),
            );
          },
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
                onTitleTap: open == null
                    ? null
                    : () async {
                        final title = await askSessionTitle(
                          context,
                          open.title ?? '',
                        );
                        if (title == null || !context.mounted) return;
                        context.read<ChatBloc>().add(
                          ChatSessionRenamed(open.id, title),
                        );
                      },
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
                  if (state.error != null || _notice != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        state.error ?? _notice!,
                        style: theme.textTheme.small.copyWith(
                          color: theme.colorScheme.destructive,
                        ),
                      ),
                    ),
                  const _VoiceStatusLine(),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(12, 0, 12, 0),
                    child: _ComposerActions(),
                  ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          MaiaBusyIcon(
                            key: const Key('chat_file_button'),
                            busy: _picking,
                            icon: const Icon(LucideIcons.file, size: 16),
                            onPressed: () => unawaited(_pickFile()),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: ChatComposer(
                              key: _composer,
                              enabled: !state.sending,
                              onSubmit: _send,
                              placeholder: context.select<VoiceCubit, String>((
                                v,
                              ) {
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
                          const SizedBox(width: 8),
                          ShadIconButton(
                            key: const Key('chat_send_button'),
                            enabled: !state.sending,
                            onPressed: state.sending ? null : _send,
                            icon: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 180),
                              child: state.sending
                                  ? SizedBox.square(
                                      key: const ValueKey('sending'),
                                      dimension: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color:
                                            theme.colorScheme.primaryForeground,
                                      ),
                                    )
                                  : const Icon(
                                      LucideIcons.arrowUp,
                                      key: ValueKey('idle'),
                                      size: 16,
                                    ),
                            ),
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
  const _ComposerActions();

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
    : messageId = m.id,
      role = m.role,
      text = m.content,
      tools = m.toolCalls ?? const [],
      streaming = false;

  const new draft(this.text, {this.tools = const []})
    : messageId = null,
      role = 'assistant',
      streaming = true;

  final String? messageId;
  final String role;
  final String text;
  final List<ChatToolCall> tools;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    if (role == 'quote') {
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: SelectableText(
            text,
            style: theme.textTheme.p,
            contextMenuBuilder: (context, state) => maiaTextMenu(
              context,
              state,
              fallbackText: text,
              messageId: messageId,
            ),
          ),
        ),
      );
    }
    if (role == 'file') {
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Icon(
                LucideIcons.file,
                size: 16,
                color: theme.colorScheme.mutedForeground,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(fileLabel(text), style: theme.textTheme.p)),
            ],
          ),
        ),
      );
    }
    final mine = role == 'user';
    final background = mine
        ? theme.colorScheme.primary
        : theme.colorScheme.muted;
    final foreground = mine
        ? theme.colorScheme.primaryForeground
        : theme.colorScheme.foreground;
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 0.0;
        return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: mine ? available * 0.72 : available,
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
              ? FileAwareText(
                  text: text,
                  style: theme.textTheme.p.copyWith(color: foreground),
                  contextMenuBuilder: (context, state) => maiaTextMenu(
                    context,
                    state,
                    fallbackText: text,
                    messageId: messageId,
                  ),
                )
              : ChatMessageBody(
                  text: text,
                  foreground: foreground,
                  tools: tools,
                  streaming: streaming,
                  contextMenuBuilder: (context, state) => maiaTextMenu(
                    context,
                    state,
                    fallbackText: text,
                    messageId: messageId,
                  ),
                ),
        ),
      ),
    );
      },
    );
  }
}

class _Hint extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Text(
      'Ask about a memory, a place, or the web. Transcribe puts what you '
      'said in the chat, in quotes. Talk sends it and speaks the reply. '
      'The file icon attaches something you pick.',
      textAlign: TextAlign.center,
      style: ShadTheme.of(context).textTheme.muted,
    ),
  );
}

class _EmptyConversation extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) =>
      const MaiaEmpty('Pick a chat or start a new one.');
}

class _CloseWhenPaused extends StatefulWidget {
  const new({required this.child});

  final Widget child;

  @override
  State<_CloseWhenPaused> createState() => _CloseWhenPausedState();
}

class _CloseWhenPausedState extends State<_CloseWhenPaused>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      context.read<ChatBloc>().add(const ChatLeft());
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
