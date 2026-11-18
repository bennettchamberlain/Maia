part of 'app_bloc.dart';

sealed class AppEvent extends Equatable {
  const new();

  @override
  List<Object?> get props => [];
}

/// Sign in with the default server, handle, and password.
final class AppStarted extends AppEvent {
  const new();
}
