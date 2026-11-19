import 'package:flutter_test/flutter_test.dart';
import 'package:maie_app/ghost/ghost_layer.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/pump_app.dart';

void main() {
  testWidgets('the cursor clicks the control it was sent to', (tester) async {
    Ghost.instant = true;
    addTearDown(() => Ghost.instant = false);
    var taps = 0;
    await tester.pumpApp(
      GhostLayer(
        child: Center(
          child: TextButton(
            key: const Key('go'),
            onPressed: () => taps++,
            child: const Text('Go'),
          ),
        ),
      ),
    );
    final pending = Ghost.tapKey('go');
    await tester.pump();
    await pending;

    expect(taps, 1);
  });
}
