import 'package:maie_models/maie_models.dart';

/// How loudly a sentence should read. Worst first.
enum JobTone { critical, warning, ok }

/// One thing the jobs page can say, and the state that proves it.
class JobVerdict {
  const new({
    required this.tone,
    required this.headline,
    this.detail,
    this.state,
  });

  final JobTone tone;
  final String headline;
  final String? detail;

  /// The filter that produced this sentence. Null when there is nowhere to go.
  final JobState? state;
}

bool _sync(JobRecord job) => job.name == 'etl' || job.name.startsWith('etl:');

String _account(JobRecord job) {
  final parts = job.name.split(':');
  if (parts.length < 2 || parts[1].isEmpty) return '';
  return parts.sublist(1).join(':');
}

String _named(Iterable<JobRecord> jobs) =>
    jobs.map(_account).where((name) => name.isNotEmpty).toSet().join(' and ');

/// What is true about sync, worst first.
///
/// An empty list means nothing is known yet. The page must not invent an
/// all-clear while it is still loading.
List<JobVerdict> jobVerdicts(List<JobRecord> jobs, {DateTime? now}) {
  if (jobs.isEmpty) return const [];
  final clock = now ?? DateTime.now();
  final syncs = jobs.where(_sync).toList();
  final running = jobs.where((job) => job.state == JobState.active).length;
  final runningSync = syncs
      .where((job) => job.state == JobState.active)
      .toList();
  final waitingSync = syncs
      .where(
        (job) => job.state == JobState.created || job.state == JobState.retry,
      )
      .toList();
  final failedSync = syncs
      .where((job) => job.state == JobState.failed)
      .toList();
  final verdicts = <JobVerdict>[];

  if (failedSync.isNotEmpty) {
    final names = _named(failedSync);
    verdicts.add(
      JobVerdict(
        tone: JobTone.critical,
        headline: failedSync.length == 1
            ? (names.isEmpty ? 'The sync failed.' : 'The $names sync failed.')
            : '${failedSync.length} syncs failed.',
        detail: failedSync.first.error ?? 'The last run did not finish.',
        state: JobState.failed,
      ),
    );
  }

  if (waitingSync.isNotEmpty && running == 0) {
    final count = waitingSync.length;
    verdicts.add(
      JobVerdict(
        tone: JobTone.critical,
        headline: count == 1
            ? 'A sync is waiting and nothing is running.'
            : '$count syncs are waiting and nothing is running.',
        detail: 'Work is queued. No worker has picked it up.',
        state: JobState.created,
      ),
    );
  } else if (waitingSync.isNotEmpty) {
    final count = waitingSync.length;
    verdicts.add(
      JobVerdict(
        tone: JobTone.warning,
        headline: count == 1
            ? 'A sync is waiting its turn.'
            : '$count syncs are waiting their turn.',
        detail: '$running running.',
        state: JobState.created,
      ),
    );
  }

  if (runningSync.isNotEmpty) {
    final names = _named(runningSync);
    verdicts.add(
      JobVerdict(
        tone: JobTone.ok,
        headline: names.isEmpty ? 'Sync is running.' : 'Syncing $names.',
        detail: 'It is running now.',
        state: JobState.active,
      ),
    );
  }

  if (syncs.isEmpty) {
    verdicts.add(
      const JobVerdict(
        tone: JobTone.warning,
        headline: 'No sync has run.',
        detail: 'Connect an account and Maie starts keeping a copy.',
      ),
    );
  } else if (verdicts.every((verdict) => verdict.tone == JobTone.ok) &&
      runningSync.isEmpty) {
    final finished = syncs
        .where((job) => job.state == JobState.completed)
        .toList()
      ..sort(
        (a, b) => (b.completedAt ?? b.createdAt).compareTo(
          a.completedAt ?? a.createdAt,
        ),
      );
    if (finished.isNotEmpty) {
      final when = finished.first.completedAt ?? finished.first.createdAt;
      verdicts.add(
        JobVerdict(
          tone: JobTone.ok,
          headline: 'Sync is up to date.',
          detail: 'Last finished ${_ago(when, clock)}.',
          state: JobState.completed,
        ),
      );
    }
  }

  const rank = {JobTone.critical: 0, JobTone.warning: 1, JobTone.ok: 2};
  verdicts.sort((a, b) => rank[a.tone]!.compareTo(rank[b.tone]!));
  return verdicts;
}

String _ago(DateTime t, DateTime now) {
  final d = now.toUtc().difference(t.toUtc());
  if (d.isNegative || d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes}m ago';
  if (d.inDays < 1) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}
