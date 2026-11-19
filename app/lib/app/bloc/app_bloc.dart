import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:maie_api_client/maie_api_client.dart';
import 'package:maie_app/config/app_config.dart';
import 'package:maie_app/config/server_cubit.dart';
import 'package:maie_app/session/session.dart';

part 'app_event.dart';

final class AppState extends Equatable {
  const new();

  @override
  List<Object?> get props => [];
}

/// The launch event. Signs in once. Logging out does not run it again.
class AppBloc extends Bloc<AppEvent, AppState> {
  new({
    required this._api,
    required this._server,
    required this._session,
  }) : super(const AppState()) {
    on<AppStarted>(_onStarted);
  }

  final MaieApiClient _api;
  final ServerCubit _server;
  final SessionCubit _session;

  Future<void> _onStarted(AppStarted event, Emitter<AppState> emit) async {
    try {
      final uri = ServerCubit.tryNormalise(AppConfig.apiUrl);
      if (uri != null) {
        await _server.set(AppConfig.apiUrl);
        _api.baseUrl = uri;
      }
      final session = await _api.signIn(
        handle: AppConfig.handle,
        password: AppConfig.password,
      );
      _session.signedIn(session);
    } on Object {
      _session.signedOut();
    }
  }
}
