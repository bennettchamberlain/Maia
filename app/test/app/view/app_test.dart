import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:maia_api_client/maia_api_client.dart';
import 'package:maia_app/app/app.dart';
import 'package:maia_app/home/home.dart';
import 'package:maia_app/session/session.dart';
import 'package:maia_app/sign_in/sign_in.dart';
import 'package:maia_models/maia_models.dart';

class _MockApi extends Mock implements MaiaApiClient;

void main() {
  group('App', () {
    testWidgets('shows sign-in, then home after a successful sign-in', (
      tester,
    ) async {
      final api = _MockApi();
      when(() => api.signIn(handle: 'admin', password: 'pw')).thenAnswer(
        (_) async => Session(
          token: 't',
          expiresAt: DateTime.utc(2030),
          person: const Person(id: 'p1', handle: 'admin', isSuperadmin: true),
        ),
      );
      when(api.chatSessions).thenAnswer((_) async => []);
      when(api.chatTools).thenAnswer(
        (_) async => const ChatCatalog(
          defaultProvider: 'parasail',
          providers: {
            'parasail': ChatProviderInfo(
              available: true,
              model: 'parasail-glm-53-flash',
            ),
            'ollama': ChatProviderInfo(available: true, model: 'llama3.2'),
          },
          tools: [],
        ),
      );
      when(api.memoryFeed).thenAnswer((_) async => []);
      when(() => api.jobs(limit: 200)).thenAnswer((_) async => []);
      when(api.oneConnectors).thenAnswer(
        (_) async => const OneConnectorPage(
          total: 0,
          categories: [],
          connectors: [],
        ),
      );
      when(api.userTimeline).thenAnswer((_) async => UserTimelineView.empty);

      await tester.pumpWidget(App(apiClient: api));
      expect(find.byType(SignInPage), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('signIn_handle_textField')),
        'admin',
      );
      await tester.enterText(
        find.byKey(const Key('signIn_password_textField')),
        'pw',
      );
      await tester.pump(); // let the bloc process the field events
      await tester.tap(find.byKey(const Key('signIn_submit_button')));
      await tester.pumpAndSettle();

      expect(find.byType(HomePage), findsOneWidget);
      verify(api.chatSessions).called(1);
    });

    testWidgets('sign-in scrolls inside a short or narrow window', (
      tester,
    ) async {
      final api = _MockApi();
      await _pumpAt(tester, App(apiClient: api), const Size(420, 320));
      expect(find.byType(SignInPage), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('signIn_submit_button')));
      expect(tester.takeException(), isNull);

      await _pumpAt(tester, App(apiClient: api), const Size(280, 640));
      await tester.ensureVisible(find.byKey(const Key('signIn_submit_button')));
      expect(tester.takeException(), isNull);
    });

    testWidgets('home survives a short desktop window and a tiny phone', (
      tester,
    ) async {
      final api = _MockApi();
      when(api.chatSessions).thenAnswer((_) async => []);
      when(api.chatTools).thenAnswer(
        (_) async => const ChatCatalog(
          defaultProvider: 'parasail',
          providers: {},
          tools: [],
        ),
      );
      when(api.memoryFeed).thenAnswer((_) async => []);
      when(() => api.jobs(limit: 200)).thenAnswer((_) async => []);
      when(api.oneConnectors).thenAnswer(
        (_) async => const OneConnectorPage(
          total: 0,
          categories: [],
          connectors: [],
        ),
      );
      when(api.userTimeline).thenAnswer((_) async => UserTimelineView.empty);

      await _pumpAt(tester, App(apiClient: api), const Size(800, 600));
      tester
          .element(find.byType(SignInPage))
          .read<SessionCubit>()
          .signedIn(
            Session(
              token: 't',
              expiresAt: DateTime.utc(2030),
              person: const Person(
                id: 'p1',
                handle: 'admin',
                isSuperadmin: true,
              ),
            ),
          );
      await tester.pump();
      expect(find.byType(HomePage), findsOneWidget);

      await _resize(tester, const Size(960, 220));
      expect(_exceptions(tester), isEmpty);

      await _resize(tester, const Size(300, 180));
      expect(_exceptions(tester), isEmpty);
    });
  });
}

Future<void> _pumpAt(WidgetTester tester, Widget app, Size size) async {
  await _resize(tester, size);
  await tester.pumpWidget(app);
  await tester.pump();
}

List<Object> _exceptions(WidgetTester tester) {
  final errors = <Object>[];
  while (true) {
    final error = tester.takeException();
    if (error == null) return errors;
    errors.add(error as Object);
  }
}

Future<void> _resize(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pump();
}
