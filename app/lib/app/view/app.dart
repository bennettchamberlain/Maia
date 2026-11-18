import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:maia_api_client/maia_api_client.dart';
import 'package:maia_app/chat/voice_cubit.dart';
import 'package:maia_app/config/chat_settings_cubit.dart';
import 'package:maia_app/config/server_cubit.dart';
import 'package:maia_app/home/home.dart';
import 'package:maia_app/l10n/l10n.dart';
import 'package:maia_app/one/callback_forwarder.dart';
import 'package:maia_app/session/session.dart';
import 'package:maia_app/sign_in/sign_in.dart';
import 'package:maia_app/ui/chrome.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class App extends StatelessWidget {
  const new({super.key, this.apiClient, this.prefs});

  /// Injected in tests; built from [ServerCubit] otherwise.
  final MaiaApiClient? apiClient;

  /// Persisted settings (server URL). Null in tests.
  final SharedPreferences? prefs;

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => SessionCubit()),
        BlocProvider(create: (_) => ServerCubit(prefs: prefs)),
        BlocProvider(create: (_) => ChatSettingsCubit(prefs: prefs)),
      ],
      child: Builder(
        builder: (context) {
          final session = context.read<SessionCubit>();
          final server = context.read<ServerCubit>();
          return RepositoryProvider<MaiaApiClient>(
            create: (_) =>
                apiClient ??
                MaiaApiClient(
                  baseUrl: server.uri,
                  tokenProvider: () => session.token,
                ),
            child: BlocProvider(
              create: (context) => VoiceCubit(
                api: context.read<MaiaApiClient>(),
                prefs: prefs,
              ),
              child: const _ServerBridge(),
            ),
          );
        },
      ),
    );
  }
}

class _ServerBridge extends StatefulWidget {
  const new();

  @override
  State<_ServerBridge> createState() => _ServerBridgeState();
}

class _ServerBridgeState extends State<_ServerBridge> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        OneCallbackForwarder.instance.follow(context.read<ServerCubit>().uri),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<ServerCubit, String>(
      listener: (context, raw) {
        final next = ServerCubit.tryNormalise(raw);
        if (next == null) return;
        context.read<MaiaApiClient>().baseUrl = next;
        unawaited(OneCallbackForwarder.instance.follow(next));
      },
      child: const AppView(),
    );
  }
}

class AppView extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final status = context.select<SessionCubit, SessionStatus>(
      (c) => c.state.status,
    );
    return ShadApp.custom(
      appBuilder: (context) {
        return MaterialApp(
          title: 'Maia',
          debugShowCheckedModeBanner: false,
          theme: Theme.of(context),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => ShadAppBuilder(
            builder: maiaMaterialTheme,
            child: child,
          ),
          home: status == SessionStatus.authenticated
              ? const HomePage()
              : const SignInPage(),
        );
      },
    );
  }
}
