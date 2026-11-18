import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:maia_app/chat/bloc/chat_bloc.dart';
import 'package:maia_app/chat/day_groups.dart';
import 'package:maia_app/ui/chrome.dart';
import 'package:maia_models/maia_models.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// The user timeline, beside navigation. Chats, mail, calendars, files.
class TimelineColumn extends StatefulWidget {
  const TimelineColumn({super.key});

  @override
  State<TimelineColumn> createState() => _TimelineColumnState();
}

class _TimelineColumnState extends State<TimelineColumn> {
  final _search = TextEditingController();
  final _open = <String>{};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ChatBloc>().state;
    final query = _search.text.trim().toLowerCase();
    final entries = [
      for (final entry in state.entries)
        if (_matches(entry, query)) entry,
    ];
    return Scaffold(
      body: MaiaPane(
        header: MaiaHeader(
          title: 'Memory',
          actions: [
            ShadIconButton.ghost(
              key: const Key('chat_new_button'),
              icon: const Icon(LucideIcons.squarePen, size: 16),
              onPressed: () => context.read<ChatBloc>().add(
                const ChatNewSessionRequested(),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: ShadInput(
                key: const Key('memory_search'),
                controller: _search,
                placeholder: const Text('Search memory…'),
                onChanged: (_) => setState(() {}),
              ),
            ),
            Expanded(child: _body(context, state, entries)),
          ],
        ),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    ChatState state,
    List<TimelineEntry> entries,
  ) {
    return switch (state.status) {
      ChatStatus.initial ||
      ChatStatus.loading when state.entries.isEmpty && state.sessions.isEmpty =>
        const MaiaSkeleton(),
      ChatStatus.failure when state.entries.isEmpty && state.sessions.isEmpty =>
        MaiaFailure(
          message: state.error ?? 'Could not load memory',
          onRetry: () => context.read<ChatBloc>().add(const ChatStarted()),
        ),
      _ when entries.isEmpty => const MaiaScrollFill(
        padding: EdgeInsets.all(24),
        child: Text('Nothing on this timeline yet.'),
      ),
      _ => RefreshIndicator(
        onRefresh: () async =>
            context.read<ChatBloc>().add(const ChatStarted()),
        child: _grouped(context, state, entries),
      ),
    };
  }

  Widget _grouped(
    BuildContext context,
    ChatState state,
    List<TimelineEntry> entries,
  ) {
    final groups = groupEntries(entries, DateTime.now());
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      children: [
        for (final group in groups) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
            child: Text(
              group.label,
              style: ShadTheme.of(context).textTheme.muted,
            ),
          ),
          for (final entry in group.entries)
            _Card(
              entry: entry,
              selected: entry.sessionId != null &&
                  entry.sessionId == state.open?.id,
              expanded: _open.contains(entry.id),
              onToggle: () => setState(() {
                if (!_open.add(entry.id)) _open.remove(entry.id);
              }),
              onOpen: () => _openEntry(context, state, entry),
              onRename: entry.isSession
                  ? () => _rename(context, entry)
                  : null,
              onDelete: entry.isSession
                  ? () {
                      final session = _session(state, entry);
                      if (session == null) return;
                      context.read<ChatBloc>().add(ChatSessionDeleted(session));
                    }
                  : null,
            ),
        ],
      ],
    );
  }

  void _openEntry(BuildContext context, ChatState state, TimelineEntry entry) {
    if (!entry.isSession) return;
    final session = _session(state, entry);
    if (session == null) return;
    context.read<ChatBloc>().add(ChatSessionOpened(session));
  }

  Future<void> _rename(BuildContext context, TimelineEntry entry) async {
    final title = await showShadDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initial: entry.title ?? ''),
    );
    if (title == null || !context.mounted || entry.sessionId == null) return;
    context.read<ChatBloc>().add(ChatSessionRenamed(entry.sessionId!, title));
  }

  ChatSession? _session(ChatState state, TimelineEntry entry) {
    for (final session in state.sessions) {
      if (session.id == entry.sessionId) return session;
    }
    final id = entry.sessionId;
    if (id == null) return null;
    return ChatSession(
      id: id,
      title: entry.title,
      topics: entry.topics,
      createdAt: entry.startedAt,
      lastMessageAt: entry.endedAt,
      firstMessageAt: entry.startedAt,
    );
  }

  bool _matches(TimelineEntry entry, String query) {
    if (query.isEmpty) return true;
    final account = entryAccountLine(entry);
    final hay = [
      entry.title,
      entry.body,
      account,
      entry.platform,
      ...entry.topics,
    ].whereType<String>().join(' ').toLowerCase();
    return hay.contains(query);
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.entry,
    required this.selected,
    required this.expanded,
    required this.onToggle,
    required this.onOpen,
    this.onRename,
    this.onDelete,
  });

  final TimelineEntry entry;
  final bool selected;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onOpen;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final account = entryAccountLine(entry);
    final hasTopics = entry.topics.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? theme.colorScheme.accent : theme.colorScheme.muted,
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        child: InkWell(
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          onTap: onOpen,
          onLongPress: onRename ?? onDelete,
          onSecondaryTap: onRename ?? onDelete,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        entry.title ?? 'New chat',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.p.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (hasTopics)
                      ShadIconButton.ghost(
                        icon: Icon(
                          expanded
                              ? LucideIcons.chevronDown
                              : LucideIcons.chevronRight,
                          size: 16,
                        ),
                        onPressed: onToggle,
                      ),
                  ],
                ),
                if (account.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(account, style: theme.textTheme.muted),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    formatSpan(entry.startedAt, entry.endedAt),
                    style: theme.textTheme.muted,
                  ),
                ),
                if (expanded)
                  for (final topic in entry.topics)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(topic, style: theme.textTheme.small),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});

  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _title = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ShadDialog(
      title: const Text('Rename'),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ShadButton(
          onPressed: () {
            final title = _title.text.trim();
            if (title.isEmpty) return;
            Navigator.of(context).pop(title);
          },
          child: const Text('Save'),
        ),
      ],
      child: ShadInput(
        controller: _title,
        autofocus: true,
        placeholder: const Text('Name'),
      ),
    );
  }
}

/// Asks for a new title. Null when cancelled.
Future<String?> askSessionTitle(BuildContext context, String initial) {
  return showShadDialog<String>(
    context: context,
    builder: (_) => _RenameDialog(initial: initial),
  );
}
