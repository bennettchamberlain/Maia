import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:maie_api_client/maie_api_client.dart';
import 'package:maie_app/chat/parts/chat_part.dart';
import 'package:maie_app/graph/ontology_layout.dart';
import 'package:maie_app/ui/chrome.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const _gold = Color(0xFFFFBA40);

/// The semantic graph. Pick a term and the panel says what it means
/// and which terms it connects to. [fill] lets the canvas take the page.
class OntologyCanvas extends StatefulWidget {
  const new({
    super.key,
    required this.graph,
    this.query = '',
    this.fill = false,
  });

  final ChatGraph graph;
  final String query;
  final bool fill;

  @override
  State<OntologyCanvas> createState() => _OntologyCanvasState();
}

class _OntologyCanvasState extends State<OntologyCanvas> {
  var _focus = -1;

  @override
  void initState() {
    super.initState();
    _focus = ontologyFocus(widget.graph);
  }

  @override
  void didUpdateWidget(OntologyCanvas old) {
    super.didUpdateWidget(old);
    if (old.graph != widget.graph) _focus = ontologyFocus(widget.graph);
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    if (widget.graph.nodes.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'Nothing stored yet.',
          style: theme.textTheme.muted,
          textAlign: TextAlign.center,
        ),
      );
    }
    final spots = layoutOntology(widget.graph);
    final canvas = LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => _pick(details.localPosition, size, spots),
          child: CustomPaint(
            painter: _OntologyPainter(
              graph: widget.graph,
              spots: spots,
              focus: _focus,
              query: widget.query.trim().toLowerCase(),
              ink: theme.colorScheme.foreground,
              muted: theme.colorScheme.mutedForeground,
              border: theme.colorScheme.border,
            ),
            child: const SizedBox.expand(),
          ),
        );
      },
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.fill)
          Expanded(child: canvas)
        else
          SizedBox(height: 260, child: canvas),
        _TermPanel(graph: widget.graph, focus: _focus),
      ],
    );
  }

  void _pick(Offset at, Size size, List<Offset> spots) {
    var best = -1;
    var bestDist = 28.0;
    for (var i = 0; i < spots.length; i++) {
      final point = Offset(spots[i].dx * size.width, spots[i].dy * size.height);
      final dist = (point - at).distance;
      if (dist < bestDist) {
        best = i;
        bestDist = dist;
      }
    }
    if (best >= 0) setState(() => _focus = best);
  }
}

class _TermPanel extends StatelessWidget {
  const new({required this.graph, required this.focus});

  final ChatGraph graph;
  final int focus;

  @override
  Widget build(BuildContext context) {
    if (focus < 0 || focus >= graph.nodes.length) {
      return const SizedBox.shrink();
    }
    final theme = ShadTheme.of(context);
    final node = graph.nodes[focus];
    final links = [
      for (final edge in graph.edges)
        if (edge.source == node.name || edge.target == node.name) edge,
    ];
    final meaning = node.subtitle.isNotEmpty
        ? node.subtitle
        : (node.kind.isEmpty ? 'A term in the life graph.' : node.kind);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(node.name, style: theme.textTheme.small),
          const SizedBox(height: 2),
          Text(meaning, style: theme.textTheme.muted),
          if (node.status.isNotEmpty)
            Text(
              node.status == 'proposed' ? 'Not established yet.' : node.status,
              style: theme.textTheme.muted,
            ),
          for (final edge in links.take(6))
            Text(_linkLine(node.name, edge), style: theme.textTheme.muted),
        ],
      ),
    );
  }

  String _linkLine(String name, ChatGraphLink edge) {
    final other = edge.source == name ? edge.target : edge.source;
    final verb = edge.kind.isEmpty ? 'connects to' : edge.kind;
    final caution = edge.status == 'proposed' ? ' (not established)' : '';
    return '$name $verb $other$caution';
  }
}

class _OntologyPainter extends CustomPainter {
  const new({
    required this.graph,
    required this.spots,
    required this.focus,
    required this.query,
    required this.ink,
    required this.muted,
    required this.border,
  });

  final ChatGraph graph;
  final List<Offset> spots;
  final int focus;
  final String query;
  final Color ink;
  final Color muted;
  final Color border;

  @override
  void paint(Canvas canvas, Size size) {
    final names = <String, int>{
      for (var i = 0; i < graph.nodes.length; i++) graph.nodes[i].name: i,
    };
    final near = <int>{if (focus >= 0) focus};
    Offset at(int i) =>
        Offset(spots[i].dx * size.width, spots[i].dy * size.height);
    bool dim(int i) {
      if (query.isEmpty) return false;
      final node = graph.nodes[i];
      final hay = '${node.name} ${node.kind} ${node.subtitle}'.toLowerCase();
      return !hay.contains(query);
    }

    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final edge in graph.edges) {
      final a = names[edge.source];
      final b = names[edge.target];
      if (a == null || b == null) continue;
      final proposed = edge.status == 'proposed';
      line.color = (proposed ? muted : border).withValues(
        alpha: proposed ? 0.45 : 1,
      );
      canvas.drawLine(at(a), at(b), line);
      if (a == focus) near.add(b);
      if (b == focus) near.add(a);
    }

    final dot = Paint()..style = PaintingStyle.fill;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = _gold;
    for (var i = 0; i < graph.nodes.length; i++) {
      final point = at(i);
      final faded = dim(i);
      dot.color = (i == focus ? ink : muted).withValues(
        alpha: faded ? 0.25 : 1,
      );
      canvas.drawCircle(point, i == focus ? 3 : 2, dot);
      if (i == focus) canvas.drawCircle(point, 7, ring);
      if (graph.nodes.length <= 18 || near.contains(i)) {
        _label(canvas, graph.nodes[i].name, point, faded ? muted : ink);
      }
    }
  }

  void _label(Canvas canvas, String text, Offset at, Color color) {
    TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: 11, height: 1),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )
      ..layout(maxWidth: 120)
      ..paint(canvas, at + const Offset(8, -6));
  }

  @override
  bool shouldRepaint(_OntologyPainter old) =>
      old.graph != graph ||
      old.focus != focus ||
      old.query != query ||
      old.ink != ink;
}

/// Loads `GET /graph` and explores it. This is the memory-page ontology.
class OntologyPage extends StatefulWidget {
  const new({super.key});

  @override
  State<OntologyPage> createState() => _OntologyPageState();
}

class _OntologyPageState extends State<OntologyPage> {
  final _search = TextEditingController();
  ChatGraph? _graph;
  String? _error;
  var _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final api = context.read<MaieApiClient>();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await api.graph();
      if (!mounted) return;
      setState(() {
        _graph = chatGraphFromJson(raw);
        _loading = false;
      });
    } on Object catch (err) {
      if (!mounted) return;
      setState(() {
        _error = '$err';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const MaieSkeleton(rows: 3);
    if (_error != null) {
      return MaieFailure(
        message: 'Could not load the ontology',
        onRetry: _load,
      );
    }
    final graph = _graph ?? const ChatGraph();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: ShadInput(
            key: const Key('ontology_search'),
            controller: _search,
            placeholder: const Text('Search the ontology'),
            onChanged: (_) => setState(() {}),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: OntologyCanvas(
              graph: graph,
              query: _search.text,
              fill: true,
            ),
          ),
        ),
      ],
    );
  }
}
