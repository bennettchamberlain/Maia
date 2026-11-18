import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:maia_app/chat/parts/chat_part.dart';
import 'package:maia_app/graph/ontology_view.dart';

import '../helpers/pump_app.dart';

void main() {
  testWidgets('selecting the busiest term shows what it means', (tester) async {
    const graph = ChatGraph(
      nodes: [
        ChatGraphNode(name: 'Maia', kind: 'project', subtitle: 'local memory'),
        ChatGraphNode(name: 'ship chat', kind: 'goal', subtitle: 'the phone'),
      ],
      edges: [
        ChatGraphLink(
          source: 'Maia',
          target: 'ship chat',
          kind: 'pursues',
          status: 'verified',
        ),
      ],
    );

    await tester.pumpApp(
      const SizedBox(
        width: 400,
        height: 420,
        child: OntologyCanvas(graph: graph, fill: true),
      ),
    );

    expect(find.text('Maia'), findsOneWidget);
    expect(find.text('local memory'), findsOneWidget);
    expect(find.text('Maia pursues ship chat'), findsOneWidget);
  });

  testWidgets('an empty graph says so', (tester) async {
    await tester.pumpApp(const OntologyCanvas(graph: ChatGraph()));
    expect(find.text('Nothing stored yet.'), findsOneWidget);
  });
}
