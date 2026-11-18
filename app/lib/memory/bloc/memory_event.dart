part of 'memory_bloc.dart';

sealed class MemoryEvent extends Equatable {
  const new();

  @override
  List<Object?> get props => [];
}

/// First load. No-op once a timeline is already on screen.
final class MemoryFetched extends MemoryEvent {
  const new();
}

/// Pull-to-refresh: reload timelines and the selected stream.
final class MemoryRefreshed extends MemoryEvent {
  const new();
}

/// Show the events on this timeline.
final class MemoryTimelineSelected extends MemoryEvent {
  const new(this.id);

  final String id;

  @override
  List<Object?> get props => [id];
}

/// A manual note typed in the app. It lands on the user timeline.
final class MemoryNoteAdded extends MemoryEvent {
  const new({
    required this.title,
    required this.sourceId,
    this.body,
    this.occurredAt,
  });

  final String title;
  final String? body;
  final DateTime? occurredAt;

  /// Idempotency key; the server upserts on (owner, source, source_id).
  final String sourceId;

  @override
  List<Object?> get props => [title, body, occurredAt, sourceId];
}
