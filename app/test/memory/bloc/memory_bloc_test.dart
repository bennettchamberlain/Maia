import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:maia_api_client/maia_api_client.dart';
import 'package:maia_app/memory/memory.dart';
import 'package:maia_models/maia_models.dart';

class _MockApi extends Mock implements MaiaApiClient;

final _t0 = DateTime.utc(2026, 10, 27, 12);

TimelineInfo _timeline(String id, String kind, String name) => TimelineInfo(
  id: id,
  key: kind == 'user' ? 'user' : '$kind:$id',
  name: name,
  kind: kind,
);

TimelineEntry _entry(String id, {String kind = 'session', DateTime? at}) {
  final when = at ?? _t0;
  return TimelineEntry(
    id: id,
    kind: kind,
    title: id,
    startedAt: when,
    endedAt: when,
  );
}

MemoryItem _note(String id, DateTime at) => MemoryItem(
  id: id,
  kind: 'note',
  title: id,
  occurredAt: at,
  source: 'manual',
);

void main() {
  late _MockApi api;
  final user = _timeline('u', 'user', 'Memory');
  final gmail = _timeline('g', 'connection', 'Gmail');

  setUpAll(() {
    registerFallbackValue(
      MemoryUpsert(
        kind: 'note',
        occurredAt: _t0,
        source: 'manual',
        sourceId: 'x',
      ),
    );
  });

  setUp(() => api = _MockApi());

  void stubUser({
    List<TimelineEntry> entries = const [],
    List<MemoryItem> notes = const [],
    List<TimelineInfo> timelines = const [],
  }) {
    when(() => api.userTimeline()).thenAnswer(
      (_) async => UserTimelineView(timeline: user, entries: entries),
    );
    when(() => api.timelines()).thenAnswer((_) async => timelines);
    when(() => api.memoryFeed(limit: 50)).thenAnswer((_) async => notes);
    when(() => api.library()).thenAnswer((_) async => LibraryView.empty);
  }

  group('MemoryBloc', () {
    blocTest<MemoryBloc, MemoryState>(
      'opens on the user timeline and keeps the other streams as filters',
      setUp: () {
        stubUser(
          entries: [_entry('chat')],
          timelines: [gmail, user],
          notes: [_note('n', _t0.add(const Duration(hours: 1)))],
        );
      },
      build: () => MemoryBloc(api: api),
      act: (b) => b.add(const MemoryFetched()),
      expect: () => [
        const MemoryState(status: MemoryStatus.loading, busy: true),
        isA<MemoryState>()
            .having((s) => s.status, 'status', MemoryStatus.success)
            .having((s) => s.selectedId, 'selected', 'u')
            .having((s) => s.timelines.map((t) => t.id).toList(), 'order', [
              'u',
              'g',
            ])
            .having((s) => s.entries.map((e) => e.id).toList(), 'entries', [
              'n',
              'chat',
            ]),
      ],
    );

    blocTest<MemoryBloc, MemoryState>(
      'loads the events on the timeline that was selected',
      setUp: () {
        when(() => api.timelineFeed('g'))
            .thenAnswer((_) async => [_entry('mail', kind: 'mail')]);
      },
      build: () => MemoryBloc(api: api),
      seed: () => MemoryState(
        status: MemoryStatus.success,
        timelines: [user, gmail],
        selectedId: 'u',
        entries: [_entry('chat')],
      ),
      act: (b) => b.add(const MemoryTimelineSelected('g')),
      expect: () => [
        isA<MemoryState>()
            .having((s) => s.selectedId, 'selected', 'g')
            .having((s) => s.entries, 'cleared', isEmpty)
            .having((s) => s.busy, 'busy', true),
        isA<MemoryState>()
            .having((s) => s.entries.single.id, 'id', 'mail')
            .having((s) => s.busy, 'busy', false),
      ],
    );

    blocTest<MemoryBloc, MemoryState>(
      'surfaces api failure',
      setUp: () {
        when(() => api.userTimeline())
            .thenThrow(const MaiaApiException(401, 'expired'));
      },
      build: () => MemoryBloc(api: api),
      act: (b) => b.add(const MemoryFetched()),
      expect: () => [
        const MemoryState(status: MemoryStatus.loading, busy: true),
        const MemoryState(status: MemoryStatus.failure, error: 'expired'),
      ],
    );

    blocTest<MemoryBloc, MemoryState>(
      'adds a note on the user timeline, de-duplicating by id',
      setUp: () {
        when(() => api.memoryUpsert(any())).thenAnswer(
          (_) async => _note('new', _t0.add(const Duration(hours: 2))),
        );
      },
      build: () => MemoryBloc(api: api),
      seed: () => MemoryState(
        status: MemoryStatus.success,
        timelines: [user],
        selectedId: 'u',
        entries: [_entry('chat')],
      ),
      act: (b) => b.add(const MemoryNoteAdded(title: 'hi', sourceId: 'k1')),
      expect: () => [
        isA<MemoryState>().having(
          (s) => s.entries.map((e) => e.id).toList(),
          'ids',
          ['new', 'chat'],
        ),
      ],
      verify: (_) {
        final sent =
            verify(() => api.memoryUpsert(captureAny())).captured.single
                as MemoryUpsert;
        expect(sent.sourceId, 'k1');
        expect(sent.source, 'manual');
      },
    );
  });
}
