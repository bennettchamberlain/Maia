import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:maia_api_client/maia_api_client.dart';
import 'package:maia_app/ui/fault.dart';
import 'package:maia_models/maia_models.dart';

part 'jobs_event.dart';
part 'jobs_state.dart';

/// The caller's `JobRecord`s, optionally filtered by state.
class JobsBloc extends Bloc<JobsEvent, JobsState> {
  new({required this._api}) : super(const JobsState()) {
    on<JobsFetched>(_onFetched);
    on<JobsRefreshed>(_onRefreshed);
    on<JobsFilterChanged>(_onFilterChanged);
  }

  final MaiaApiClient _api;

  Future<void> _onFetched(JobsFetched e, Emitter<JobsState> emit) async {
    if (state.status == JobsStatus.success) return;
    emit(state.copyWith(status: JobsStatus.loading));
    await _load(emit);
  }

  Future<void> _onRefreshed(JobsRefreshed e, Emitter<JobsState> emit) async {
    emit(state.copyWith(refreshing: true));
    await _load(emit);
  }

  Future<void> _onFilterChanged(
    JobsFilterChanged e,
    Emitter<JobsState> emit,
  ) async {
    emit(state.copyWith(filter: e.states, status: JobsStatus.loading));
    await _load(emit);
  }

  Future<void> _load(Emitter<JobsState> emit) async {
    try {
      final jobs = await _api.jobs(
        states: state.filter.isEmpty ? null : state.filter.toList(),
        limit: 200,
      );
      emit(
        state.copyWith(
          status: JobsStatus.success,
          jobs: jobs,
          refreshing: false,
          clearError: true,
        ),
      );
    } on MaiaApiException catch (err) {
      emit(
        state.copyWith(
          status: JobsStatus.failure,
          refreshing: false,
          error: err.shown,
        ),
      );
    } on Exception catch (err) {
      rememberFault(_api, 'jobs', err);
      emit(
        state.copyWith(
          status: JobsStatus.failure,
          refreshing: false,
          error: shownFault(err),
        ),
      );
    }
  }
}
