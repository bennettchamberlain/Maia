import 'package:flutter_test/flutter_test.dart';
import 'package:maie_app/chat/day_groups.dart';
import 'package:maie_models/maie_models.dart';

TimelineEntry entry(String id, DateTime ended) => TimelineEntry(
  id: id,
  kind: 'session',
  title: id,
  startedAt: ended.subtract(const Duration(minutes: 30)),
  endedAt: ended,
);

void main() {
  test('groups by day and labels today', () {
    final now = DateTime(2026, 11, 17, 20);
    final groups = groupEntries([
      entry('today', DateTime(2026, 11, 17, 15, 8)),
      entry('earlier', DateTime(2026, 11, 10, 15, 8)),
    ], now);
    expect(groups.map((g) => g.label), ['Today', 'Tue 10 Nov']);
    expect(groups.first.entries.single.id, 'today');
  });

  test('a same-day span is a clock range', () {
    expect(
      formatSpan(DateTime(2026, 11, 10, 14, 35), DateTime(2026, 11, 10, 15, 8)),
      '2:35 PM – 3:08 PM',
    );
  });

  test('a span across midnight names both dates', () {
    expect(
      formatSpan(DateTime(2026, 11, 10, 23, 40), DateTime(2026, 11, 11, 0, 15)),
      'Nov 10, 11:40 PM – Nov 11, 12:15 AM',
    );
  });
}
