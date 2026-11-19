import 'dart:math' as math;
import 'dart:ui';

import 'package:maie_app/chat/parts/chat_part.dart';

/// Where each term sits, in unit space. Index matches [ChatGraph.nodes].
///
/// A short force pass: terms that share an edge pull together, the rest
/// push apart. The same graph always lands in the same places.
List<Offset> layoutOntology(ChatGraph graph) {
  final count = graph.nodes.length;
  if (count == 0) return const [];
  if (count == 1) return const [Offset(0.5, 0.5)];

  final pos = <Offset>[
    for (var i = 0; i < count; i++)
      Offset(
        0.5 + 0.34 * math.cos(2 * math.pi * i / count),
        0.5 + 0.34 * math.sin(2 * math.pi * i / count),
      ),
  ];
  final names = <String, int>{
    for (var i = 0; i < count; i++) graph.nodes[i].name: i,
  };
  final neighbors = <int, List<int>>{
    for (var i = 0; i < count; i++) i: <int>[],
  };
  for (final edge in graph.edges) {
    final a = names[edge.source];
    final b = names[edge.target];
    if (a == null || b == null || a == b) continue;
    neighbors[a]!.add(b);
    neighbors[b]!.add(a);
  }

  for (var step = 0; step < 40; step++) {
    final next = List<Offset>.of(pos);
    for (var i = 0; i < count; i++) {
      var dx = (0.5 - pos[i].dx) * 0.02;
      var dy = (0.5 - pos[i].dy) * 0.02;
      for (var j = 0; j < count; j++) {
        if (i == j) continue;
        final delta = pos[i] - pos[j];
        final dist = math.max(0.05, delta.distance);
        final push = 0.01 / (dist * dist);
        dx += delta.dx / dist * push;
        dy += delta.dy / dist * push;
      }
      for (final other in neighbors[i]!) {
        final delta = pos[other] - pos[i];
        dx += delta.dx * 0.12;
        dy += delta.dy * 0.12;
      }
      next[i] = Offset(
        (pos[i].dx + dx).clamp(0.1, 0.9),
        (pos[i].dy + dy).clamp(0.12, 0.88),
      );
    }
    for (var i = 0; i < count; i++) {
      pos[i] = next[i];
    }
  }
  return pos;
}

/// The term with the most connections, which the canvas opens on.
int ontologyFocus(ChatGraph graph) {
  if (graph.nodes.isEmpty) return -1;
  final degree = List<int>.filled(graph.nodes.length, 0);
  final names = <String, int>{
    for (var i = 0; i < graph.nodes.length; i++) graph.nodes[i].name: i,
  };
  for (final edge in graph.edges) {
    final a = names[edge.source];
    final b = names[edge.target];
    if (a != null) degree[a]++;
    if (b != null) degree[b]++;
  }
  var best = 0;
  for (var i = 1; i < degree.length; i++) {
    if (degree[i] > degree[best]) best = i;
  }
  return best;
}
