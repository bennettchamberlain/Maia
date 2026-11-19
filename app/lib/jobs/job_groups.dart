import 'package:maie_models/maie_models.dart';

/// One row on the jobs page. Runs of the same work sit together.
class JobGroup {
  const new(this.name, this.jobs);

  final String name;
  final List<JobRecord> jobs;

  JobRecord get latest => jobs.first;

  int get running => jobs.where((j) => j.state == JobState.active).length;

  int get waiting => jobs
      .where(
        (j) => j.state == JobState.created || j.state == JobState.retry,
      )
      .length;

  /// What the row should say about the newest runs.
  String get summary {
    if (running > 0) return running == 1 ? 'Running' : '$running running';
    if (waiting > 0) return waiting == 1 ? 'Waiting' : '$waiting waiting';
    return latest.state.name;
  }
}

/// Groups [jobs] by name. Each group stays in the order it arrived,
/// which is newest first.
List<JobGroup> groupJobs(List<JobRecord> jobs) {
  final byName = <String, List<JobRecord>>{};
  for (final job in jobs) {
    byName.putIfAbsent(job.name, () => []).add(job);
  }
  final groups = [
    for (final entry in byName.entries) JobGroup(entry.key, entry.value),
  ]..sort(
    (a, b) => b.latest.createdAt.compareTo(a.latest.createdAt),
  );
  return groups;
}

/// A short name for the jobs page. `etl:gmail` is a sync of Gmail.
String jobTitle(String name) {
  final split = name.split(':');
  final kind = split.first;
  final rest = split.length > 1 ? split.sublist(1).join(':') : '';
  final label = switch (kind) {
    'etl' => 'Sync',
    'embed' => 'Index',
    'conclude' => 'Read',
    'weave' => 'Weave',
    'dream' => 'Night',
    'derive-presence' => 'Place',
    _ => kind,
  };
  if (rest.isEmpty) return label;
  return '$label · $rest';
}
