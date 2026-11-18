import 'package:maia_app/jobs/job_groups.dart';
import 'package:maia_models/maia_models.dart';
import 'package:flutter_test/flutter_test.dart';

JobRecord _job(String name, JobState state, {String? error}) => JobRecord(
  id: name + state.name,
  name: name,
  state: state,
  createdAt: DateTime.utc(2026, 11, 18, 9),
  error: error,
);

void main() {
  test('same work sits on one row', () {
    final groups = groupJobs([
      _job('etl', JobState.created),
      _job('etl', JobState.created),
      _job('embed', JobState.completed),
    ]);
    expect(groups, hasLength(2));
    expect(groups.first.name, 'etl');
    expect(groups.first.summary, '2 waiting');
    expect(groups.first.jobs, hasLength(2));
  });

  test('a platform sync names the account', () {
    expect(jobTitle('etl:gmail'), 'Sync · gmail');
    expect(jobTitle('embed'), 'Index');
    expect(jobTitle('etl'), 'Sync');
  });
}
