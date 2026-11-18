part of 'chat_bloc.dart';

sealed class ChatEvent extends Equatable {
  const new();

  @override
  List<Object?> get props => const [];
}

/// Load the session list.
final class ChatStarted extends ChatEvent {
  const new();
}

final class ChatSessionOpened extends ChatEvent {
  const new(this.session);
  final ChatSession session;

  @override
  List<Object?> get props => [session.id];
}

final class ChatNewSessionRequested extends ChatEvent {
  const new();
}

final class ChatSessionDeleted extends ChatEvent {
  const new(this.session);
  final ChatSession session;

  @override
  List<Object?> get props => [session.id];
}

/// Send a turn in the open session (a session is created if none is open).
final class ChatMessageSent extends ChatEvent {
  const new(this.content);
  final String content;

  @override
  List<Object?> get props => [content];
}

/// Phone layout: leave the open session and show the list.
final class ChatBackToList extends ChatEvent {
  const new();
}

/// The app paused. Close the open session without leaving it.
final class ChatLeft extends ChatEvent {
  const new();
}

/// The person named this chat. Later closes keep the name.
final class ChatSessionRenamed extends ChatEvent {
  const new(this.sessionId, this.title);

  final String sessionId;
  final String title;

  @override
  List<Object?> get props => [sessionId, title];
}

/// Branch a chat at [messageId]. [selection] is the highlighted passage.
final class ChatForkRequested extends ChatEvent {
  const new({
    required this.sessionId,
    required this.messageId,
    this.selection,
  });

  final String sessionId;
  final String messageId;
  final String? selection;

  @override
  List<Object?> get props => [sessionId, messageId, selection];
}

/// Create a file from [text], or append it when [documentId] is set.
final class ChatFileSaved extends ChatEvent {
  const new({
    required this.text,
    this.documentId,
    this.sessionId,
    this.messageId,
  });

  final String text;
  final String? documentId;
  final String? sessionId;
  final String? messageId;

  @override
  List<Object?> get props => [text, documentId, sessionId, messageId];
}

/// A transcript quote or a picked file. It sits in the thread and is not
/// sent as a prompt.
final class ChatAsideAdded extends ChatEvent {
  const new({required this.role, required this.content});

  final String role;
  final String content;

  @override
  List<Object?> get props => [role, content];
}
