part of 'memory_bloc.dart';

enum MemoryStatus { initial, loading, success, failure }

final class MemoryState extends Equatable {
  const new({
    this.status = MemoryStatus.initial,
    this.timelines = const [],
    this.selectedId,
    this.entries = const [],
    this.library = LibraryView.empty,
    this.busy = false,
    this.error,
  });

  final MemoryStatus status;

  /// Every stream the caller owns. The user timeline is first.
  final List<TimelineInfo> timelines;

  /// The timeline whose events are in [entries].
  final String? selectedId;
  final List<TimelineEntry> entries;

  /// Skills, frequent files, and the last cron turns.
  final LibraryView library;

  /// A filter change or refresh is in flight. The chips stay put.
  final bool busy;
  final String? error;

  MemoryState copyWith({
    MemoryStatus? status,
    List<TimelineInfo>? timelines,
    String? selectedId,
    List<TimelineEntry>? entries,
    LibraryView? library,
    bool? busy,
    String? error,
    bool clearError = false,
  }) {
    return MemoryState(
      status: status ?? this.status,
      timelines: timelines ?? this.timelines,
      selectedId: selectedId ?? this.selectedId,
      entries: entries ?? this.entries,
      library: library ?? this.library,
      busy: busy ?? this.busy,
      error: clearError ? null : (error ?? this.error),
    );
  }

  @override
  List<Object?> get props => [
    status,
    timelines,
    selectedId,
    entries,
    library,
    busy,
    error,
  ];
}
