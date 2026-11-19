import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:maie_app/chat/bloc/chat_bloc.dart';
import 'package:maie_app/chat/day_groups.dart';
import 'package:maie_app/ui/chrome.dart';
import 'package:maie_app/ui/company_logo.dart';
import 'package:maie_models/maie_models.dart';
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
      body: MaiePane(
        header: MaieHeader(
          title: 'Maie',
          actions: [
            ShadIconButton.ghost(
              key: const Key('chat_new_button'),
              icon: const Icon(LucideIcons.plus, size: 16),
              onPressed: () =>
                  context.read<ChatBloc>().add(const ChatNewSessionRequested()),
            ),
          ],
        ),
        body: _body(context, state, entries),
        footer: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: ShadInput(
            key: const Key('memory_search'),
            controller: _search,
            placeholder: const Text('Search'),
            onChanged: (_) => setState(() {}),
          ),
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
      ChatStatus.initial || ChatStatus.loading
          when state.entries.isEmpty && state.sessions.isEmpty =>
        const MaieSkeleton(),
      ChatStatus.failure when state.entries.isEmpty && state.sessions.isEmpty =>
        MaieFailure(
          message: state.error ?? 'Could not load memory',
          onRetry: () => context.read<ChatBloc>().add(const ChatStarted()),
        ),
      _ when entries.isEmpty => const MaieScrollFill(
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
              selected:
                  entry.sessionId != null && entry.sessionId == state.open?.id,
              expanded: _open.contains(entry.id),
              onToggle: () => setState(() {
                if (!_open.add(entry.id)) _open.remove(entry.id);
              }),
              onOpen: () => _openEntry(context, state, entry),
              onRename: entry.isSession ? () => _rename(context, entry) : null,
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
    final title = entry.title ?? 'New chat';
    final preview = _preview(entry, account);
    final when = shortWhen(entry.endedAt, DateTime.now());
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected ? theme.colorScheme.accent : Colors.transparent,
        borderRadius: const BorderRadius.all(Radius.circular(10)),
        child: InkWell(
          borderRadius: const BorderRadius.all(Radius.circular(10)),
          onTap: onOpen,
          onLongPress: onRename ?? onDelete,
          onSecondaryTap: onRename ?? onDelete,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                _RowMark(entry: entry, title: title),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.small.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            when,
                            style: theme.textTheme.muted.copyWith(fontSize: 11),
                          ),
                        ],
                      ),
                      if (preview.isNotEmpty)
                        Text(
                          preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.muted,
                        ),
                      if (expanded)
                        for (final topic in entry.topics)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(topic, style: theme.textTheme.small),
                          ),
                    ],
                  ),
                ),
                if (hasTopics)
                  ShadIconButton.ghost(
                    icon: Icon(
                      expanded
                          ? LucideIcons.chevronDown
                          : LucideIcons.chevronRight,
                      size: 14,
                    ),
                    onPressed: onToggle,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _preview(TimelineEntry entry, String account) {
  final body = entry.body?.trim() ?? '';
  if (body.isNotEmpty) return body;
  if (account.isNotEmpty) return account;
  return entry.topics.join(', ');
}

class _RowMark extends StatelessWidget {
  const new({required this.entry, required this.title});

  final TimelineEntry entry;
  final String title;

  @override
  Widget build(BuildContext context) {
    if (entry.platform != null && entry.platform!.isNotEmpty) {
      return CompanyLogo(slug: entry.platform, size: 36);
    }
    final theme = ShadTheme.of(context);
    final letter = title.trim().isEmpty ? 'M' : title.trim().substring(0, 1);
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.all(Radius.circular(10)),
        border: Border.all(color: theme.colorScheme.border),
      ),
      child: Text(letter.toUpperCase(), style: theme.textTheme.small),
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
