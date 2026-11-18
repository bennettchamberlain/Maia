import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:maia_api_client/maia_api_client.dart';
import 'package:maia_app/chat/chat.dart';
import 'package:maia_models/maia_models.dart';

class _MockApi extends Mock implements MaiaApiClient;

void main() {
  final session = ChatSession(id: 's1', createdAt: DateTime.utc(2026));
  ChatMessage msg(String id, String role, String text, int seq) => ChatMessage(
    id: id,
    role: role,
    content: text,
    seq: seq,
    createdAt: DateTime.utc(2026),
  );

  group('ChatBloc', () {
    late _MockApi api;

    setUp(() {
      api = _MockApi();
      when(api.userTimeline).thenAnswer((_) async => UserTimelineView.empty);
    });

    blocTest<ChatBloc, ChatState>(
      'loads sessions on start',
      build: () {
        when(api.chatSessions).thenAnswer((_) async => [session]);
        return ChatBloc(api: api);
      },
      act: (b) => b.add(const ChatStarted()),
      expect: () => [
        const ChatState(status: ChatStatus.loading),
        ChatState(
          status: ChatStatus.ready,
          sessions: [session],
          entries: [
            TimelineEntry.fromSession(
              sessionId: session.id,
              createdAt: session.createdAt,
            ),
          ],
        ),
      ],
    );

    blocTest<ChatBloc, ChatState>(
      'send streams a reply into draftReply, then stores the message',
      build: () {
        when(
          () => api.chatSend(
            's1',
            'hi',
            provider: any(named: 'provider'),
            screen: any(named: 'screen'),
          ),
        ).thenAnswer(
          (_) => Stream.fromIterable([
            ChatUserStored(msg('u1', 'user', 'hi', 1)),
            const ChatDelta('Hel'),
            const ChatDelta('lo'),
            ChatDone(msg('a1', 'assistant', 'Hello', 2)),
          ]),
        );
        return ChatBloc(api: api);
      },
      seed: () => ChatState(
        status: ChatStatus.ready,
        sessions: [session],
        open: session,
      ),
      act: (b) => b.add(const ChatMessageSent('hi')),
      verify: (b) {
        expect(b.state.sending, isFalse);
        expect(b.state.draftReply, isEmpty);
        expect(b.state.messages.map((m) => m.content), ['hi', 'Hello']);
        expect(b.state.open?.title, 'hi');
        expect(b.state.sessions.single.messageCount, 2);
      },
    );

    blocTest<ChatBloc, ChatState>(
      'a quote sits in the thread and is not sent',
      build: () => ChatBloc(api: api),
      seed: () => ChatState(status: ChatStatus.ready, open: session),
      act: (b) =>
          b.add(const ChatAsideAdded(role: 'quote', content: '"hello"')),
      verify: (b) {
        expect(b.state.messages.single.role, 'quote');
        expect(b.state.messages.single.content, '"hello"');
      },
    );

    blocTest<ChatBloc, ChatState>(
      'a line during a reply steers and the open stream shows it',
      build: () {
        final replies = StreamController<ChatStreamEvent>();
        when(
          () => api.chatSend(
            's1',
            'hi',
            provider: any(named: 'provider'),
            screen: any(named: 'screen'),
          ),
        ).thenAnswer((_) => replies.stream);
        when(() => api.chatSteer('s1', 'wait')).thenAnswer((_) async {
          replies.add(ChatUserStored(msg('u2', 'user', 'wait', 2)));
          replies.add(ChatDone(msg('a1', 'assistant', 'ok', 3)));
          await replies.close();
          return msg('u2', 'user', 'wait', 2);
        });
        return ChatBloc(api: api);
      },
      seed: () => ChatState(status: ChatStatus.ready, open: session),
      act: (b) async {
        b.add(const ChatMessageSent('hi'));
        await Future<void>.delayed(Duration.zero);
        b.add(const ChatSteered('wait'));
        await Future<void>.delayed(Duration.zero);
      },
      verify: (b) {
        expect(b.state.sending, isFalse);
        expect(b.state.messages.map((m) => m.content), ['wait', 'ok']);
        verify(() => api.chatSteer('s1', 'wait')).called(1);
      },
    );

    blocTest<ChatBloc, ChatState>(
      'a printed tool call is wiped from the draft',
      build: () {
        when(
          () => api.chatSend(
            's1',
            'hi',
            provider: any(named: 'provider'),
            screen: any(named: 'screen'),
          ),
        ).thenAnswer(
          (_) => Stream.fromIterable([
            ChatUserStored(msg('u1', 'user', 'hi', 1)),
            const ChatDelta('{"name":"web_search"}'),
            const ChatDraftReplaced(''),
            const ChatDelta('Lisbon.'),
            ChatDone(msg('a1', 'assistant', 'Lisbon.', 2)),
          ]),
        );
        return ChatBloc(api: api);
      },
      seed: () => ChatState(status: ChatStatus.ready, open: session),
      act: (b) => b.add(const ChatMessageSent('hi')),
      verify: (b) {
        expect(b.state.messages.last.content, 'Lisbon.');
        expect(b.state.draftReply, isEmpty);
      },
    );

    blocTest<ChatBloc, ChatState>(
      'a server-side failure surfaces as error and stops sending',
      build: () {
        when(
          () => api.chatSend(
            's1',
            'hi',
            provider: any(named: 'provider'),
            screen: any(named: 'screen'),
          ),
        ).thenAnswer(
          (_) => Stream.fromIterable([
            ChatUserStored(msg('u1', 'user', 'hi', 1)),
            const ChatFailed('agent 503'),
          ]),
        );
        return ChatBloc(api: api);
      },
      seed: () => ChatState(status: ChatStatus.ready, open: session),
      act: (b) => b.add(const ChatMessageSent('hi')),
      verify: (b) {
        expect(b.state.sending, isFalse);
        expect(b.state.error, 'agent 503');
        expect(b.state.messages.length, 1);
      },
    );

    blocTest<ChatBloc, ChatState>(
      'rename locks the title on the open chat',
      build: () {
        when(() => api.chatRename('s1', 'Career')).thenAnswer(
          (_) async => session.copyWith(title: 'Career', titleLocked: true),
        );
        return ChatBloc(api: api);
      },
      seed: () => ChatState(status: ChatStatus.ready, open: session),
      act: (b) => b.add(const ChatSessionRenamed('s1', 'Career')),
      verify: (b) {
        expect(b.state.open?.title, 'Career');
        expect(b.state.open?.titleLocked, isTrue);
      },
    );

    blocTest<ChatBloc, ChatState>(
      'switching chats closes the one you left',
      build: () {
        when(() => api.chatClose('s1')).thenAnswer((_) async => session);
        when(() => api.chatMessages('s2')).thenAnswer((_) async => []);
        when(api.userTimeline).thenAnswer(
          (_) async => UserTimelineView(
            entries: [
              TimelineEntry.fromSession(
                sessionId: 's1',
                createdAt: session.createdAt,
                title: 'You mapped careers',
              ),
            ],
          ),
        );
        return ChatBloc(api: api);
      },
      seed: () => ChatState(
        status: ChatStatus.ready,
        sessions: [
          session,
          ChatSession(id: 's2', createdAt: DateTime.utc(2026, 2)),
        ],
        open: session,
      ),
      act: (b) => b.add(
        ChatSessionOpened(ChatSession(id: 's2', createdAt: DateTime.utc(2026, 2))),
      ),
      verify: (b) {
        verify(() => api.chatClose('s1')).called(1);
        expect(b.state.open?.id, 's2');
      },
    );

    blocTest<ChatBloc, ChatState>(
      'fork opens the new session',
      build: () {
        final fork = ChatSession(id: 's2', createdAt: DateTime.utc(2026, 3));
        when(
          () => api.chatFork(
            's1',
            messageId: 'a1',
            selection: any(named: 'selection'),
          ),
        ).thenAnswer((_) async => fork);
        when(() => api.chatMessages('s2')).thenAnswer(
          (_) async => [msg('a1', 'assistant', 'hello', 1)],
        );
        when(api.userTimeline).thenAnswer((_) async => UserTimelineView.empty);
        return ChatBloc(api: api);
      },
      seed: () => ChatState(status: ChatStatus.ready, open: session),
      act: (b) => b.add(
        const ChatForkRequested(
          sessionId: 's1',
          messageId: 'a1',
          selection: 'hello',
        ),
      ),
      verify: (b) {
        expect(b.state.open?.id, 's2');
        expect(b.state.messages.single.content, 'hello');
      },
    );
  });
}
