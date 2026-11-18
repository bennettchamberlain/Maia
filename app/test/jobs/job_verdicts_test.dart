import 'package:flutter_test/flutter_test.dart';
import 'package:maia_app/jobs/job_verdicts.dart';
import 'package:maia_models/maia_models.dart';

JobRecord _job(
  String name,
  JobState state, {
  String? error,
  DateTime? completedAt,
}) => JobRecord(
  id: '$name-${state.name}',
  name: name,
  state: state,
  createdAt: DateTime.utc(2026, 11, 18, 9),
  completedAt: completedAt,
  error: error,
);

void main() {
  test('an empty queue says nothing', () {
    expect(jobVerdicts(const []), isEmpty);
  });

  test('a waiting sync with nothing running is stuck', () {
    final verdicts = jobVerdicts([
      _job('etl:gmail', JobState.created),
    ]);
    expect(verdicts.single.tone, JobTone.critical);
    expect(
      verdicts.single.headline,
      'A sync is waiting and nothing is running.',
    );
    expect(verdicts.single.state, JobState.created);
  });

  test('a running sync names the account', () {
    final verdicts = jobVerdicts([
      _job('etl:gmail', JobState.active),
    ]);
    expect(verdicts.single.headline, 'Syncing gmail.');
    expect(verdicts.single.tone, JobTone.ok);
  });

  test('a finished sync says when', () {
    final verdicts = jobVerdicts(
      [
        _job(
          'etl:gmail',
          JobState.completed,
          completedAt: DateTime.utc(2026, 11, 18, 8),
        ),
      ],
      now: DateTime.utc(2026, 11, 18, 9),
    );
    expect(verdicts.single.headline, 'Sync is up to date.');
    expect(verdicts.single.detail, 'Last finished 1h ago.');
  });

  test('a failed sync leads with the error', () {
    final verdicts = jobVerdicts([
      _job('etl:gmail', JobState.failed, error: 'token expired'),
      _job('etl:gmail', JobState.completed),
    ]);
    expect(verdicts.first.headline, 'The gmail sync failed.');
    expect(verdicts.first.detail, 'token expired');
    expect(verdicts.any((v) => v.headline == 'Sync is up to date.'), isFalse);
  });

  test('other work without a sync is called out', () {
    final verdicts = jobVerdicts([
      _job('embed', JobState.completed),
    ]);
    expect(verdicts.single.headline, 'No sync has run.');
  });
}
