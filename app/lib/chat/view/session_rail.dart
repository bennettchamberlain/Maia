import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:maie_app/chat/bloc/chat_bloc.dart';
import 'package:maie_app/ui/company_logo.dart';
import 'package:maie_models/maie_models.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Icon rail of conversations. Used when the window is too narrow for the
/// named list and wide enough to keep the thread on screen.
class SessionRail extends StatelessWidget {
  const new({this.footer, super.key});

  /// Destination icons and the account button, supplied by the shell.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final state = context.watch<ChatBloc>().state;
    final sessions = [
      for (final entry in state.entries)
        if (entry.isSession) entry,
    ];
    final shown = sessions.isNotEmpty ? sessions : state.entries;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: theme.colorScheme.border)),
      ),
      child: SizedBox(
        width: 72,
        child: SafeArea(
          right: false,
          child: Column(
            children: [
              const SizedBox(height: 8),
              ShadIconButton.ghost(
                icon: const Icon(LucideIcons.plus, size: 18),
                onPressed: () => context.read<ChatBloc>().add(
                  const ChatNewSessionRequested(),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    for (final entry in shown)
                      _Monogram(
                        entry: entry,
                        selected:
                            entry.sessionId != null &&
                            entry.sessionId == state.open?.id,
                        onPressed: () => _open(context, state, entry),
                      ),
                  ],
                ),
              ),
              ?footer,
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  void _open(BuildContext context, ChatState state, TimelineEntry entry) {
    if (!entry.isSession) return;
    ChatSession? session;
    for (final candidate in state.sessions) {
      if (candidate.id == entry.sessionId) {
        session = candidate;
        break;
      }
    }
    final id = entry.sessionId;
    if (id == null) return;
    context.read<ChatBloc>().add(
      ChatSessionOpened(
        session ??
            ChatSession(
              id: id,
              title: entry.title,
              topics: entry.topics,
              createdAt: entry.startedAt,
              lastMessageAt: entry.endedAt,
              firstMessageAt: entry.startedAt,
            ),
      ),
    );
  }
}

class _Monogram extends StatelessWidget {
  const new({
    required this.entry,
    required this.selected,
    required this.onPressed,
  });

  final TimelineEntry entry;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final title = entry.title ?? 'New chat';
    final letter = title.trim().isEmpty ? 'M' : title.trim().substring(0, 1);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Center(
        child: Material(
          color: selected ? theme.colorScheme.accent : Colors.transparent,
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          child: InkWell(
            onTap: onPressed,
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            child: SizedBox(
              width: 48,
              height: 48,
              child: Center(
                child: entry.platform != null && entry.platform!.isNotEmpty
                    ? CompanyLogo(slug: entry.platform, size: 32)
                    : Container(
                        width: 32,
                        height: 32,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          borderRadius: const BorderRadius.all(
                            Radius.circular(8),
                          ),
                          border: Border.all(color: theme.colorScheme.border),
                        ),
                        child: Text(
                          letter.toUpperCase(),
                          style: theme.textTheme.small,
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
