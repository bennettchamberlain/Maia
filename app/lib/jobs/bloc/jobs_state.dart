part of 'jobs_bloc.dart';

enum JobsStatus { initial, loading, success, failure }

final class JobsState extends Equatable {
  const new({
    this.status = JobsStatus.initial,
    this.jobs = const [],
    this.filter = const {},
    this.refreshing = false,
    this.error,
  });

  final JobsStatus status;
  final List<JobRecord> jobs;
  final Set<JobState> filter;
  final bool refreshing;
  final String? error;

  JobsState copyWith({
    JobsStatus? status,
    List<JobRecord>? jobs,
    Set<JobState>? filter,
    bool? refreshing,
    String? error,
    bool clearError = false,
  }) {
    return JobsState(
      status: status ?? this.status,
      jobs: jobs ?? this.jobs,
      filter: filter ?? this.filter,
      refreshing: refreshing ?? this.refreshing,
      error: clearError ? null : (error ?? this.error),
    );
  }

  @override
  List<Object?> get props => [status, jobs, filter, refreshing, error];
}
