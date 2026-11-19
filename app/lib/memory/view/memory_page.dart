import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:maie_api_client/maie_api_client.dart';
import 'package:maie_app/chat/day_groups.dart';
import 'package:maie_app/graph/ontology_view.dart';
import 'package:maie_app/memory/memory.dart';
import 'package:maie_app/memory/memory_filter.dart';
import 'package:maie_app/ui/chrome.dart';
import 'package:maie_app/ui/company_logo.dart';
import 'package:maie_models/maie_models.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class MemoryPage extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) =>
          MemoryBloc(api: context.read<MaieApiClient>())
            ..add(const MemoryFetched()),
      child: const MemoryView(),
    );
  }
}

class MemoryView extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: MaiePane(
        header: MaieHeader(
          title: 'Memory',
          actions: [
            ShadIconButton.ghost(
              key: const Key('memory_addNote_fab'),
              icon: const Icon(LucideIcons.squarePen, size: 16),
              onPressed: () => _showAddNote(context),
            ),
          ],
        ),
        body: BlocListener<MemoryBloc, MemoryState>(
          listenWhen: (p, c) => c.error != null && p.error != c.error,
          listener: (context, state) {
            ShadToaster.of(context).show(
              ShadToast.destructive(
                title: const Text('Memory'),
                description: Text(state.error!),
              ),
            );
          },
          child: const _MemoryBody(),
        ),
      ),
    );
  }

  Future<void> _showAddNote(BuildContext context) async {
    final bloc = context.read<MemoryBloc>();
    final result = await showShadDialog<({String title, String body})>(
      context: context,
      builder: (_) => const _AddNoteDialog(),
    );
    if (result == null) return;
    bloc.add(
      MemoryNoteAdded(
        title: result.title,
        body: result.body.isEmpty ? null : result.body,
        sourceId: DateTime.now().toUtc().microsecondsSinceEpoch.toString(),
      ),
    );
  }
}

class _MemoryBody extends StatefulWidget {
  const new();

  @override
  State<_MemoryBody> createState() => _MemoryBodyState();
}

class _MemoryBodyState extends State<_MemoryBody> {
  final _search = TextEditingController();
  var _ontology = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<MemoryBloc>().state;
    final phrase = readMemoryPhrase(
      _search.text,
      DateTime.now(),
      platforms: [
        for (final timeline in state.timelines)
          if (timeline.platform != null) timeline.platform!,
      ],
    );
    final entries = [
      for (final entry in state.entries)
        if (memoryPhraseMatches(phrase, entry)) entry,
    ];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              _Mode(
                label: 'Timeline',
                buttonKey: const Key('memory_timeline'),
                selected: !_ontology,
                onPressed: () => setState(() => _ontology = false),
              ),
              const SizedBox(width: 8),
              _Mode(
                label: 'Ontology',
                buttonKey: const Key('memory_ontology'),
                selected: _ontology,
                onPressed: () => setState(() => _ontology = true),
              ),
            ],
          ),
        ),
        if (_ontology)
          const Expanded(child: OntologyPage())
        else ...[
          if (!state.library.isEmpty) const _LibraryShelf(),
          if (state.timelines.isNotEmpty) const _TimelineFilters(),
          if (state.timelines.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: ShadInput(
                key: const Key('memory_search'),
                controller: _search,
                placeholder: const Text(
                  'Filter in words, like gmail from Ada this week',
                ),
                onChanged: (value) => _onSearch(context, state, value),
              ),
            ),
          if (phrase.narrowed)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  memoryPhraseLine(phrase),
                  style: ShadTheme.of(context).textTheme.muted,
                ),
              ),
            ),
          Expanded(child: _list(context, state, entries, phrase.narrowed)),
        ],
      ],
    );
  }

  Widget _list(
    BuildContext context,
    MemoryState state,
    List<TimelineEntry> entries,
    bool filtered,
  ) {
    switch (state.status) {
      case MemoryStatus.initial:
      case MemoryStatus.loading:
        return const MaieSkeleton();
      case MemoryStatus.failure when state.timelines.isEmpty:
        return MaieFailure(
          message: state.error ?? 'Could not load memory',
          onRetry: () =>
              context.read<MemoryBloc>().add(const MemoryRefreshed()),
        );
      case MemoryStatus.failure:
      case MemoryStatus.success:
        if (state.busy && state.entries.isEmpty) {
          return const MaieSkeleton();
        }
        if (entries.isEmpty) {
          final message = filtered
              ? 'Nothing matches.'
              : 'Nothing on this timeline yet.';
          return RefreshIndicator(
            onRefresh: () => _refresh(context),
            child: MaieScrollFill(
              padding: const EdgeInsets.all(24),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: ShadTheme.of(context).textTheme.muted,
              ),
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: () => _refresh(context),
          child: _grouped(context, entries),
        );
    }
  }

  Future<void> _refresh(BuildContext context) async {
    final bloc = context.read<MemoryBloc>()..add(const MemoryRefreshed());
    await bloc.stream.firstWhere((s) => !s.busy);
  }

  Widget _grouped(BuildContext context, List<TimelineEntry> entries) {
    final groups = groupEntries(entries, DateTime.now());
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
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
          for (final entry in group.entries) _EventTile(entry: entry),
        ],
      ],
    );
  }

  void _onSearch(BuildContext context, MemoryState state, String value) {
    setState(() {});
    final phrase = readMemoryPhrase(
      value,
      DateTime.now(),
      platforms: [
        for (final timeline in state.timelines)
          if (timeline.platform != null) timeline.platform!,
      ],
    );
    final platform = phrase.platform;
    if (platform == null) return;
    for (final timeline in state.timelines) {
      if (timeline.platform != platform || timeline.id == state.selectedId) {
        continue;
      }
      context.read<MemoryBloc>().add(MemoryTimelineSelected(timeline.id));
      return;
    }
  }
}

class _Mode extends StatelessWidget {
  const new({
    required this.label,
    required this.buttonKey,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final Key buttonKey;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return ShadButton.outline(
      key: buttonKey,
      size: ShadButtonSize.sm,
      onPressed: onPressed,
      child: Text(
        label,
        style: theme.textTheme.small.copyWith(
          color: selected
              ? theme.colorScheme.foreground
              : theme.colorScheme.mutedForeground,
        ),
      ),
    );
  }
}

class _LibraryShelf extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final library = context.watch<MemoryBloc>().state.library;
    final theme = ShadTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (library.skills.isNotEmpty)
            _ShelfRow(label: 'Skills', entries: library.skills),
          if (library.files.isNotEmpty)
            _ShelfRow(label: 'Files', entries: library.files),
          if (library.turns.isNotEmpty)
            _ShelfRow(label: 'Turns', entries: library.turns),
          Divider(height: 1, color: theme.colorScheme.border),
        ],
      ),
    );
  }
}

class _ShelfRow extends StatelessWidget {
  const new({required this.label, required this.entries});

  final String label;
  final List<LibraryEntry> entries;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 52,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(label, style: theme.textTheme.muted),
            ),
          ),
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in entries.take(8))
                  ShadBadge.outline(
                    onPressed: () => showShadDialog<void>(
                      context: context,
                      builder: (_) => ShadDialog(
                        title: Text(entry.name),
                        child: Text(
                          entry.line.isEmpty ? entry.kind : entry.line,
                        ),
                      ),
                    ),
                    child: Text(entry.name),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TimelineFilters extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<MemoryBloc>().state;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: ShadTheme.of(context).colorScheme.border),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            for (final timeline in state.timelines)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _TimelineBadge(
                  timeline: timeline,
                  selected: timeline.id == state.selectedId,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TimelineBadge extends StatelessWidget {
  const new({required this.timeline, required this.selected});

  final TimelineInfo timeline;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final label = timeline.name.isEmpty ? timeline.kind : timeline.name;
    void select() {
      context.read<MemoryBloc>().add(MemoryTimelineSelected(timeline.id));
    }

    final platform = timeline.platform;
    final child = platform == null || platform.isEmpty
        ? Text(label)
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CompanyLogo(slug: platform, size: 16),
              const SizedBox(width: 6),
              Text(label),
            ],
          );
    if (selected) {
      return ShadBadge.secondary(
        key: Key('memory_timeline_${timeline.id}'),
        onPressed: select,
        child: child,
      );
    }
    return ShadBadge.outline(
      key: Key('memory_timeline_${timeline.id}'),
      onPressed: select,
      child: child,
    );
  }
}

class _EventTile extends StatelessWidget {
  const new({required this.entry});

  final TimelineEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final line = _kindLine(entry);
    final when = formatSpan(entry.startedAt, entry.endedAt);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: theme.colorScheme.muted,
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        child: InkWell(
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          onTap: () => showShadDialog<void>(
            context: context,
            builder: (_) => _EventDialog(entry: entry),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _EventMark(entry: entry),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.title ?? '(untitled ${entry.kind})',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.p,
                      ),
                      Text(
                        '$line · $when',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.muted,
                      ),
                      if (entry.body != null && entry.body!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            entry.body!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.muted,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EventMark extends StatelessWidget {
  const _EventMark({required this.entry});

  final TimelineEntry entry;

  @override
  Widget build(BuildContext context) {
    final platform = entry.platform;
    if (platform != null && platform.isNotEmpty) {
      return CompanyLogo(slug: platform);
    }
    final theme = ShadTheme.of(context);
    return Icon(
      switch (entry.kind) {
        'note' => LucideIcons.stickyNote,
        'session' => LucideIcons.messageCircle,
        'mail' => LucideIcons.mail,
        'calendar' => LucideIcons.calendar,
        'file' => LucideIcons.file,
        'ontology' => LucideIcons.brain,
        _ => LucideIcons.circle,
      },
      size: 16,
      color: theme.colorScheme.mutedForeground,
    );
  }
}

class _EventDialog extends StatelessWidget {
  const new({required this.entry});

  final TimelineEntry entry;

  @override
  Widget build(BuildContext context) {
    final when = formatSpan(entry.startedAt, entry.endedAt);
    final bits = [_kindLine(entry), when, ?entry.source].join(' · ');
    return ShadDialog(
      title: Text(entry.title ?? entry.kind),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(bits),
          if (entry.body != null && entry.body!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(entry.body!),
          ],
          for (final topic in entry.topics)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text(topic)),
        ],
      ),
    );
  }
}

/// Account line for a connector. A plain kind name for everything else.
String _kindLine(TimelineEntry entry) {
  final account = entryAccountLine(entry);
  if (account.isNotEmpty) return account;
  return switch (entry.kind) {
    'session' => 'Chat',
    'note' => 'Note',
    'file' => 'File',
    'ontology' => 'About',
    _ => entry.kind,
  };
}

class _AddNoteDialog extends StatefulWidget {
  const new();

  @override
  State<_AddNoteDialog> createState() => _AddNoteDialogState();
}

class _AddNoteDialogState extends State<_AddNoteDialog> {
  final _title = TextEditingController();
  final _body = TextEditingController();

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ShadDialog(
      title: const Text('New note'),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ShadButton(
          key: const Key('memory_addNote_save'),
          onPressed: () {
            if (_title.text.trim().isEmpty) return;
            Navigator.of(context)
                .pop((title: _title.text.trim(), body: _body.text.trim()));
          },
          child: const Text('Save'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ShadInput(
            key: const Key('memory_addNote_title'),
            controller: _title,
            autofocus: true,
            placeholder: const Text('Title'),
          ),
          const SizedBox(height: 8),
          ShadInput(
            key: const Key('memory_addNote_body'),
            controller: _body,
            minLines: 2,
            maxLines: 6,
            placeholder: const Text('Body'),
          ),
        ],
      ),
    );
  }
}
