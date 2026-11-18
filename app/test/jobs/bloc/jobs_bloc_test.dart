import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:maia_api_client/maia_api_client.dart';
import 'package:maia_app/jobs/jobs.dart';
import 'package:maia_models/maia_models.dart';

class _MockApi extends Mock implements MaiaApiClient;

JobRecord _job(String id, JobState state) => JobRecord(
  id: id,
  name: 'embed',
  state: state,
  createdAt: DateTime.utc(2026, 10, 27),
);

void main() {
  late _MockApi api;
  setUp(() => api = _MockApi());

  group('JobsBloc', () {
    blocTest<JobsBloc, JobsState>(
      'fetches all states by default',
      setUp: () {
        when(() => api.jobs(limit: 200))
            .thenAnswer((_) async => [_job('1', JobState.created)]);
      },
      build: () => JobsBloc(api: api),
      act: (b) => b.add(const JobsFetched()),
      expect: () => [
        const JobsState(status: JobsStatus.loading),
        isA<JobsState>()
            .having((s) => s.status, 'status', JobsStatus.success)
            .having((s) => s.jobs.length, 'jobs', 1),
      ],
    );

    blocTest<JobsBloc, JobsState>(
      'a filter keeps the jobs already loaded',
      setUp: () {
        when(() => api.jobs(limit: 200)).thenAnswer(
          (_) async => [
            _job('1', JobState.created),
            _job('2', JobState.failed),
          ],
        );
      },
      build: () => JobsBloc(api: api),
      act: (b) async {
        b.add(const JobsFetched());
        await b.stream.firstWhere((s) => s.status == JobsStatus.success);
        b.add(const JobsFilterChanged({JobState.failed}));
      },
      expect: () => [
        const JobsState(status: JobsStatus.loading),
        isA<JobsState>().having((s) => s.jobs.length, 'jobs', 2),
        isA<JobsState>()
            .having((s) => s.jobs.length, 'jobs', 2)
            .having((s) => s.filter, 'filter', {JobState.failed})
            .having((s) => s.status, 'status', JobsStatus.success),
      ],
      verify: (_) {
        verify(() => api.jobs(limit: 200)).called(1);
      },
    );

    blocTest<JobsBloc, JobsState>(
      'reports failure',
      setUp: () {
        when(() => api.jobs(limit: 200))
            .thenThrow(const MaiaApiException(500, 'boom'));
      },
      build: () => JobsBloc(api: api),
      act: (b) => b.add(const JobsFetched()),
      expect: () => [
        const JobsState(status: JobsStatus.loading),
        const JobsState(status: JobsStatus.failure, error: 'boom'),
      ],
    );
  });
}
