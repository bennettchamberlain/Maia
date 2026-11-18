import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:maia_api_client/maia_api_client.dart';
import 'package:material_ui/material_ui.dart';
import 'package:maia_app/jobs/job_groups.dart';
import 'package:maia_app/jobs/jobs.dart';
import 'package:maia_app/ui/chrome.dart';
import 'package:maia_models/maia_models.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class JobsPage extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) =>
          JobsBloc(api: context.read<MaiaApiClient>())
            ..add(const JobsFetched()),
      child: const JobsView(),
    );
  }
}

class JobsView extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: MaiaPane(
        header: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MaiaHeader(title: 'Jobs', actions: [_RefreshButton()]),
            _SyncNote(),
            _StateFilter(),
          ],
        ),
        body: _JobsBody(),
      ),
    );
  }
}

class _RefreshButton extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final refreshing = context.select<JobsBloc, bool>(
      (b) => b.state.refreshing,
    );
    return MaiaBusyIcon(
      key: const Key('jobs_refresh_button'),
      busy: refreshing,
      icon: const Icon(LucideIcons.refreshCw, size: 16),
      onPressed: () => context.read<JobsBloc>().add(const JobsRefreshed()),
    );
  }
}

class _SyncNote extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Text(
        'The cloud holds the record. This device keeps a cache, and sync '
        'keeps running.',
        style: theme.textTheme.muted,
      ),
    );
  }
}

class _StateFilter extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final filter = context.select<JobsBloc, Set<JobState>>(
      (b) => b.state.filter,
    );
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
            for (final s in JobState.values)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _StateBadge(state: s, selected: filter.contains(s)),
              ),
          ],
        ),
      ),
    );
  }
}

class _StateBadge extends StatelessWidget {
  const new({required this.state, required this.selected});

  final JobState state;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final filter = context.read<JobsBloc>().state.filter;
    void toggle() {
      final next = <JobState>{...filter};
      if (selected) {
        next.remove(state);
      } else {
        next.add(state);
      }
      context.read<JobsBloc>().add(JobsFilterChanged(next));
    }

    final child = Text(state.name);
    if (selected) {
      return ShadBadge.secondary(onPressed: toggle, child: child);
    }
    return ShadBadge.outline(onPressed: toggle, child: child);
  }
}

class _JobsBody extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<JobsBloc>().state;
    switch (state.status) {
      case JobsStatus.initial:
      case JobsStatus.loading:
        return const MaiaSkeleton();
      case JobsStatus.failure:
        return MaiaFailure(
          message: state.error ?? 'Could not load jobs',
          onRetry: () => context.read<JobsBloc>().add(const JobsRefreshed()),
        );
      case JobsStatus.success:
        final groups = groupJobs(state.jobs);
        if (groups.isEmpty) {
          return const MaiaEmpty(
            'Nothing is syncing yet. Connect an account and Maia starts '
            'keeping a copy.',
          );
        }
        return ListView.separated(
          itemCount: groups.length,
          separatorBuilder: (_, _) => const MaiaDivider.horizontal(),
          itemBuilder: (context, i) => _JobGroupTile(group: groups[i]),
        );
    }
  }
}

class _JobGroupTile extends StatefulWidget {
  const new({required this.group});

  final JobGroup group;

  @override
  State<_JobGroupTile> createState() => _JobGroupTileState();
}

class _JobGroupTileState extends State<_JobGroupTile> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final group = widget.group;
    final latest = group.latest;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(
                  _iconFor(latest.state),
                  size: 16,
                  color: _colorFor(latest.state, theme.colorScheme),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(jobTitle(group.name), style: theme.textTheme.p),
                      Text(
                        group.jobs.length == 1
                            ? group.summary
                            : '${group.summary} · ${group.jobs.length} runs',
                        style: theme.textTheme.muted,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  _ago(
                    latest.completedAt ?? latest.startedAt ?? latest.createdAt,
                  ),
                  style: theme.textTheme.muted,
                ),
                const SizedBox(width: 8),
                Icon(
                  _open ? LucideIcons.chevronUp : LucideIcons.chevronDown,
                  size: 16,
                  color: theme.colorScheme.mutedForeground,
                ),
              ],
            ),
          ),
        ),
        MaiaExpand(
          expanded: _open,
          child: Column(
            children: [
              for (final job in group.jobs) _JobRun(job: job),
            ],
          ),
        ),
      ],
    );
  }
}

class _JobRun extends StatelessWidget {
  const new({required this.job});

  final JobRecord job;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final subtitle = [
      if (job.attempt > 0) 'attempt ${job.attempt}',
      ?job.subjectClass,
      ?job.error,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(44, 0, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.muted,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _badge(job.state),
          const SizedBox(width: 8),
          Text(
            _ago(job.completedAt ?? job.startedAt ?? job.createdAt),
            style: theme.textTheme.muted,
          ),
        ],
      ),
    );
  }
}

IconData _iconFor(JobState state) => switch (state) {
  JobState.created => LucideIcons.clock,
  JobState.retry => LucideIcons.rotateCcw,
  JobState.active => LucideIcons.play,
  JobState.completed => LucideIcons.circleCheck,
  JobState.cancelled => LucideIcons.ban,
  JobState.failed => LucideIcons.circleAlert,
};

Color _colorFor(JobState state, ShadColorScheme scheme) => switch (state) {
  JobState.failed => scheme.destructive,
  JobState.active || JobState.completed => scheme.foreground,
  _ => scheme.mutedForeground,
};

Widget _badge(JobState state) {
  final child = Text(state.name);
  return switch (state) {
    JobState.failed => ShadBadge.destructive(child: child),
    JobState.completed => ShadBadge.secondary(child: child),
    JobState.active => ShadBadge(child: child),
    _ => ShadBadge.outline(child: child),
  };
}

String _ago(DateTime t) {
  final d = DateTime.now().toUtc().difference(t.toUtc());
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes}m ago';
  if (d.inDays < 1) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}
