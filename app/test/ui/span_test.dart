import 'package:flutter_test/flutter_test.dart';
import 'package:maie_app/ui/span.dart';

void main() {
  test('window spans match the Grok client', () {
    expect(maieSpan(393), MaieSpan.stack);
    expect(maieSpan(679), MaieSpan.stack);
    expect(maieSpan(680), MaieSpan.rail);
    expect(maieSpan(834), MaieSpan.rail);
    expect(maieSpan(959), MaieSpan.rail);
    expect(maieSpan(960), MaieSpan.split);
    expect(maieSpan(1032), MaieSpan.split);
    expect(maieSpan(1179), MaieSpan.split);
    expect(maieSpan(1180), MaieSpan.desk);
    expect(maieSpan(1194), MaieSpan.desk);
    expect(maieSpan(1376), MaieSpan.desk);
  });
}
