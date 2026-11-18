import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:maia_api_client/maia_api_client.dart';
import 'package:maia_app/ui/fault.dart';
import 'package:maia_models/maia_models.dart';

part 'memory_event.dart';
part 'memory_state.dart';

/// The memory page. Each timeline is a stream (the person, one Gmail,
/// a person, a thing). Events are whatever subscribed to that stream.
/// A note is not a connector, so it is merged onto the user timeline.
class MemoryBloc extends Bloc<MemoryEvent, MemoryState> {
  new({required this._api, this.pageSize = 50}) : super(const MemoryState()) {
    on<MemoryFetched>(_onFetched);
    on<MemoryRefreshed>(_onRefreshed);
    on<MemoryTimelineSelected>(_onSelected);
    on<MemoryNoteAdded>(_onNoteAdded);
  }

  final MaiaApiClient _api;
  final int pageSize;

  Future<void> _onFetched(MemoryFetched e, Emitter<MemoryState> emit) async {
    if (state.status == MemoryStatus.success) return;
    emit(state.copyWith(status: MemoryStatus.loading, busy: true));
    await _reload(emit);
  }

  Future<void> _onRefreshed(
    MemoryRefreshed e,
    Emitter<MemoryState> emit,
  ) async {
    emit(state.copyWith(busy: true));
    await _reload(emit);
  }

  Future<void> _onSelected(
    MemoryTimelineSelected e,
    Emitter<MemoryState> emit,
  ) async {
    if (e.id == state.selectedId) return;
    emit(
      state.copyWith(
        selectedId: e.id,
        entries: const [],
        busy: true,
        clearError: true,
      ),
    );
    try {
      final entries = await _entriesFor(e.id, _userId(state.timelines));
      emit(
        state.copyWith(
          status: MemoryStatus.success,
          entries: entries,
          busy: false,
          clearError: true,
        ),
      );
    } on MaiaApiException catch (err) {
      emit(
        state.copyWith(
          status: MemoryStatus.failure,
          busy: false,
          error: err.shown,
        ),
      );
    } on Exception catch (err) {
      rememberFault(_api, 'memory', err);
      emit(
        state.copyWith(
          status: MemoryStatus.failure,
          busy: false,
          error: shownFault(err),
        ),
      );
    }
  }

  Future<void> _onNoteAdded(
    MemoryNoteAdded e,
    Emitter<MemoryState> emit,
  ) async {
    try {
      final item = await _api.memoryUpsert(
        MemoryUpsert(
          kind: 'note',
          title: e.title,
          body: e.body,
          occurredAt: e.occurredAt ?? DateTime.now().toUtc(),
          source: 'manual',
          sourceId: e.sourceId,
        ),
      );
      final userId = _userId(state.timelines);
      if (userId != null && state.selectedId != userId) {
        emit(
          state.copyWith(
            selectedId: userId,
            entries: const [],
            busy: true,
            clearError: true,
          ),
        );
        final view = await _api.userTimeline();
        final notes = await _api.memoryFeed(limit: pageSize);
        emit(
          state.copyWith(
            status: MemoryStatus.success,
            entries: _withNotes(view.entries, notes),
            busy: false,
            clearError: true,
          ),
        );
        return;
      }
      emit(
        state.copyWith(
          status: MemoryStatus.success,
          entries: _withNotes(state.entries, [item]),
          clearError: true,
        ),
      );
    } on MaiaApiException catch (err) {
      emit(state.copyWith(error: err.shown));
    }
  }

  Future<void> _reload(Emitter<MemoryState> emit) async {
    try {
      final view = await _api.userTimeline();
      final timelines = _ordered(_merge(view, await _api.timelines()));
      final userId = view.timeline?.id ?? _userId(timelines);
      final previous = state.selectedId;
      final selected =
          previous != null && timelines.any((t) => t.id == previous)
          ? previous
          : userId;
      final entries = selected == null || selected == userId
          ? _withNotes(view.entries, await _api.memoryFeed(limit: pageSize))
          : await _api.timelineFeed(selected);
      emit(
        state.copyWith(
          status: MemoryStatus.success,
          timelines: timelines,
          selectedId: selected,
          entries: entries,
          library: await _shelf(),
          busy: false,
          clearError: true,
        ),
      );
    } on MaiaApiException catch (err) {
      emit(
        state.copyWith(
          status: MemoryStatus.failure,
          busy: false,
          error: err.shown,
        ),
      );
    } on Exception catch (err) {
      rememberFault(_api, 'memory', err);
      emit(
        state.copyWith(
          status: MemoryStatus.failure,
          busy: false,
          error: shownFault(err),
        ),
      );
    }
  }

  Future<LibraryView> _shelf() async {
    try {
      return await _api.library();
    } on MaiaApiException {
      return LibraryView.empty;
    } on Exception {
      return LibraryView.empty;
    }
  }

  Future<List<TimelineEntry>> _entriesFor(String id, String? userId) async {
    if (id == userId) {
      final view = await _api.userTimeline();
      final notes = await _api.memoryFeed(limit: pageSize);
      return _withNotes(view.entries, notes);
    }
    return await _api.timelineFeed(id);
  }
}

List<TimelineInfo> _merge(UserTimelineView view, List<TimelineInfo> rows) {
  final timeline = view.timeline;
  if (timeline == null || rows.any((row) => row.id == timeline.id)) {
    return rows;
  }
  return [timeline, ...rows];
}

List<TimelineInfo> _ordered(List<TimelineInfo> rows) {
  return [...rows]..sort((a, b) {
    final rank = _rank(a.kind).compareTo(_rank(b.kind));
    if (rank != 0) return rank;
    return a.name.compareTo(b.name);
  });
}

int _rank(String kind) => switch (kind) {
  'user' => 0,
  'connection' => 1,
  'person' => 2,
  'entity' => 3,
  _ => 4,
};

String? _userId(List<TimelineInfo> timelines) {
  for (final timeline in timelines) {
    if (timeline.kind == 'user' || timeline.key == 'user') return timeline.id;
  }
  return null;
}

/// Notes are not connector events, so they only exist on the user stream.
List<TimelineEntry> _withNotes(
  List<TimelineEntry> events,
  List<MemoryItem> items,
) {
  final ids = events.map((entry) => entry.id).toSet();
  final merged = [
    ...events,
    for (final item in items)
      if (item.kind == 'note' && !ids.contains(item.id))
        TimelineEntry(
          id: item.id,
          kind: 'note',
          title: item.title,
          body: item.body,
          startedAt: item.occurredAt,
          endedAt: item.occurredAt,
          source: item.source,
        ),
  ]..sort((a, b) => b.endedAt.compareTo(a.endedAt));
  return merged;
}
