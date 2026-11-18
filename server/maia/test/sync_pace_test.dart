import 'package:maia_api/src/jobs/sync_pace.dart';
import 'package:test/test.dart';

void main() {
  test('a pass pulls one connector and remembers the next', () {
    final first = nextConnector(['gmail', 'slack', 'notion'], 0);
    expect(first?.platform, 'gmail');
    expect(first?.next, 1);
    final second = nextConnector(['gmail', 'slack', 'notion'], first!.next);
    expect(second?.platform, 'slack');
    final wrapped = nextConnector(['gmail', 'slack'], 2);
    expect(wrapped?.platform, 'gmail');
    expect(nextConnector(const [], 0), isNull);
  });

  test('a full pass waits ninety seconds between connectors', () {
    expect(syncDelay(0), Duration.zero);
    expect(syncDelay(1), const Duration(seconds: 90));
    expect(syncDelay(3), const Duration(seconds: 270));
  });
}
