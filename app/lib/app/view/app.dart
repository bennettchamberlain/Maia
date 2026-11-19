import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:maie_api_client/maie_api_client.dart';
import 'package:maie_app/app/bloc/app_bloc.dart';
import 'package:maie_app/chat/voice_cubit.dart';
import 'package:maie_app/config/chat_settings_cubit.dart';
import 'package:maie_app/config/field_cubit.dart';
import 'package:maie_app/config/server_cubit.dart';
import 'package:maie_app/ghost/ghost_layer.dart';
import 'package:maie_app/home/home.dart';
import 'package:maie_app/l10n/l10n.dart';
import 'package:maie_app/one/callback_forwarder.dart';
import 'package:maie_app/session/session.dart';
import 'package:maie_app/sign_in/sign_in.dart';
import 'package:maie_app/ui/chrome.dart';
import 'package:maie_app/ui/field_backdrop.dart';
import 'package:maie_app/ui/glass.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class App extends StatelessWidget {
  const new({super.key, this.apiClient, this.prefs, this.autoSignIn = true});

  /// Injected in tests; built from [ServerCubit] otherwise.
  final MaieApiClient? apiClient;

  /// Persisted settings (server URL). Null in tests.
  final SharedPreferences? prefs;

  /// Signs in with the default server and account. Tests that drive the
  /// form themselves turn this off.
  final bool autoSignIn;

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(
          create: (_) => SessionCubit(
            initial: autoSignIn
                ? const SessionState.starting()
                : const SessionState.unauthenticated(),
          ),
        ),
        BlocProvider(create: (_) => ServerCubit(prefs: prefs)),
        BlocProvider(create: (_) => ChatSettingsCubit(prefs: prefs)),
        BlocProvider(create: (_) => FieldCubit(prefs: prefs)),
      ],
      child: Builder(
        builder: (context) {
          final session = context.read<SessionCubit>();
          final server = context.read<ServerCubit>();
          return RepositoryProvider<MaieApiClient>(
            create: (_) =>
                apiClient ??
                MaieApiClient(
                  baseUrl: server.uri,
                  tokenProvider: () => session.token,
                ),
            child: BlocProvider(
              create: (context) =>
                  VoiceCubit(api: context.read<MaieApiClient>(), prefs: prefs),
              child: BlocProvider(
                lazy: false,
                create: (context) {
                  final bloc = AppBloc(
                    api: context.read<MaieApiClient>(),
                    server: context.read<ServerCubit>(),
                    session: context.read<SessionCubit>(),
                  );
                  if (autoSignIn) bloc.add(const AppStarted());
                  return bloc;
                },
                child: const _ServerBridge(),
              ),
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
        context.read<MaieApiClient>().baseUrl = next;
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
          title: 'Maie',
          debugShowCheckedModeBanner: false,
          theme: Theme.of(context),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) {
            final field = context.watch<FieldCubit>().state;
            return ShadAppBuilder(
              builder: (context, built) {
                final themed = field
                    ? ShadTheme(
                        data: maieFieldTheme(ShadTheme.of(context)),
                        child: maieMaterialTheme(context, built, field: true),
                      )
                    : maieMaterialTheme(context, built);
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    if (field)
                      const Positioned.fill(
                        child: IgnorePointer(child: FieldBackdrop()),
                      ),
                    themed,
                  ],
                );
              },
              child: GhostLayer(child: child ?? const SizedBox.shrink()),
            );
          },
          home: switch (status) {
            SessionStatus.starting => const Scaffold(body: MaieSkeleton()),
            SessionStatus.authenticated => const HomePage(),
            SessionStatus.unauthenticated => const SignInPage(),
          },
        );
      },
    );
  }
}
