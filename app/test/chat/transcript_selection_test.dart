import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Future<void> _chord(WidgetTester tester, LogicalKeyboardKey modifier) async {
  await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
  await tester.pump();
  await tester.sendKeyUpEvent(modifier);
  await tester.pump();
}

void main() {
  testWidgets('ctrl and cmd A select the prompt and the reply', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final field = TextEditingController(text: 'composer');
    addTearDown(field.dispose);
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Shortcuts(
                shortcuts: const <ShortcutActivator, Intent>{
                  SingleActivator(LogicalKeyboardKey.keyA, control: true):
                      SelectAllTextIntent(SelectionChangedCause.keyboard),
                  SingleActivator(LogicalKeyboardKey.keyA, meta: true):
                      SelectAllTextIntent(SelectionChangedCause.keyboard),
                },
                child: SelectionArea(
                  focusNode: focus,
                  onSelectionChanged: (content) {
                    selected = content?.plainText;
                  },
                  child: const Column(
                    children: [
                      Text('What is my GitHub login?'),
                      Text('Your login is ada.'),
                    ],
                  ),
                ),
              ),
              TextField(controller: field),
            ],
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    await _chord(tester, LogicalKeyboardKey.control);
    expect(selected, contains('What is my GitHub login?'));
    expect(selected, contains('Your login is ada.'));
    expect(field.selection.isCollapsed, isTrue);

    selected = null;
    await _chord(tester, LogicalKeyboardKey.meta);
    expect(selected, contains('What is my GitHub login?'));
    expect(selected, contains('Your login is ada.'));
  });
}
