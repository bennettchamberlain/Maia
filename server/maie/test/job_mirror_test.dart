import 'package:maie_api/src/jobs/job_mirror.dart';
import 'package:test/test.dart';

void main() {
  test('a fresh open mirror blocks another copy', () {
    final now = DateTime.utc(2026, 11, 18, 10);
    final fresh = now.subtract(const Duration(minutes: 2));
    final stale = now.subtract(const Duration(minutes: 20));
    expect(openMirrorBlocks(fresh.toIso8601String(), now), isTrue);
    expect(openMirrorBlocks(stale.toIso8601String(), now), isFalse);
    expect(openMirrorBlocks(null, now), isFalse);
  });

  test('the newest open row is the first one', () {
    expect(
      newestOpenCreatedAt('[{"created_at":"2026-11-18T10:00:00Z"}]'),
      '2026-11-18T10:00:00Z',
    );
    expect(newestOpenCreatedAt('[]'), isNull);
  });
}
