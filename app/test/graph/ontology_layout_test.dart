import 'package:flutter_test/flutter_test.dart';
import 'package:maia_app/chat/parts/chat_part.dart';
import 'package:maia_app/graph/ontology_layout.dart';

void main() {
  const graph = ChatGraph(
    nodes: [
      ChatGraphNode(name: 'Maia', kind: 'project', subtitle: 'local memory'),
      ChatGraphNode(name: 'ship chat', kind: 'goal'),
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

  test('linked terms land apart, and the same graph repeats', () {
    final once = layoutOntology(graph);
    final twice = layoutOntology(graph);
    expect(once, hasLength(2));
    expect(once, twice);
    expect(once.first, isNot(once.last));
  });

  test('one term sits in the middle', () {
    final spots = layoutOntology(
      const ChatGraph(nodes: [ChatGraphNode(name: 'Maia')]),
    );
    expect(spots.single.dx, 0.5);
    expect(spots.single.dy, 0.5);
  });

  test('the opening term is the one with the most links', () {
    expect(ontologyFocus(graph), 0);
    expect(ontologyFocus(const ChatGraph()), -1);
  });
}
