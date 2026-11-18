import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// A fan of a hundred dotted terraces. The scatter stays inside its
/// terrace, and the step to the next one stays open. The steps widen
/// toward the left. One tight ripple kicks while [speaking].
class MaiaCloud extends StatefulWidget {
  const new({this.speaking = false, this.size = 280, super.key});

  final bool speaking;
  final double size;

  @override
  State<MaiaCloud> createState() => _MaiaCloudState();
}

class _MaiaCloudState extends State<MaiaCloud>
    with SingleTickerProviderStateMixin {
  late final AnimationController _tick;
  late final List<_Grain> _grains;

  @override
  void initState() {
    super.initState();
    _tick = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 24),
    )..repeat();
    _grains = _fan();
  }

  @override
  void dispose() {
    _tick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ink = ShadTheme.of(context).colorScheme.foreground;
    return SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: _tick,
        builder: (context, _) {
          return CustomPaint(
            painter: _CloudPainter(
              seconds: _tick.value * 24,
              speaking: widget.speaking,
              ink: ink,
              grains: _grains,
            ),
          );
        },
      ),
    );
  }
}

class _Grain {
  const new(this.s, this.nCross, this.nLift, this.ridge);

  /// Along the terrace.
  final double s;

  /// Scatter inside the terrace, smaller than the step.
  final double nCross;

  /// Scatter in the topographic height.
  final double nLift;

  /// Which terrace. The step between these is the drawing.
  final int ridge;
}

const _terraces = 96;
const _steps = 48;

/// One dotted contour per terrace. Noise does not cross the step.
List<_Grain> _fan() {
  final random = math.Random(11);
  double gauss() {
    final a = math.max(1e-9, random.nextDouble());
    final b = random.nextDouble();
    final g = math.sqrt(-2 * math.log(a)) * math.cos(math.pi * 2 * b);
    return g.clamp(-1.8, 1.8);
  }

  final grains = <_Grain>[];
  for (var ridge = 0; ridge < _terraces; ridge++) {
    for (var step = 0; step < _steps; step++) {
      final along = -1.05 + step * (2.1 / (_steps - 1));
      grains.add(_Grain(along + gauss() * 0.012, gauss(), gauss(), ridge));
    }
  }
  return grains;
}

class _CloudPainter extends CustomPainter {
  const new({
    required this.seconds,
    required this.speaking,
    required this.ink,
    required this.grains,
  });

  final double seconds;
  final bool speaking;
  final Color ink;
  final List<_Grain> grains;

  static const _sunset = <Color>[
    Color(0xFF4A0C56),
    Color(0xFFFF2A6A),
    Color(0xFFFF5C24),
    Color(0xFFFFBA40),
    Color(0xFFFFF4E0),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final span = size.shortestSide * 0.46;
    final origin = Offset(size.width / 2, size.height / 2);
    final pulse = speaking ? _spike(seconds, 3) : 0.0;
    final drawn = <({Offset at, double depth, double hot, double relief})>[];
    for (final grain in grains) {
      final s = grain.s;
      final open = ((1.15 - s) / 2.3).clamp(0.0, 1.0);
      final half = 0.72 + open * 0.3;
      final pitch = (2 * half) / (_terraces - 1);
      final u = grain.ridge / (_terraces - 1);
      final cross = (u - 0.5) * 2 * half + grain.nCross * pitch * 0.08;
      final lift =
          math.sin(s * 2.2 + grain.ridge * 0.05 + seconds * 0.35) *
              pitch *
              0.12 +
          grain.nLift * pitch * 0.05;
      final du = u - 0.55;
      final hot = math.exp(-(math.pow(s - 0.15, 2) * 22 + du * du * 4000));
      final kick = hot * pulse * pitch * 0.45;
      final depth = (0.3 + (1 - open) * 0.45).clamp(0.0, 1.0);
      drawn.add((
        at: Offset(
          origin.dx + s * span,
          origin.dy + (cross + lift - kick) * span,
        ),
        depth: depth,
        hot: hot,
        relief: (lift.abs() / pitch).clamp(0.0, 1.0),
      ));
    }
    drawn.sort((a, b) => a.depth.compareTo(b.depth));
    for (final dot in drawn) {
      final lit = speaking && dot.hot > 0.45;
      final color = lit
          ? _band(dot.hot).withValues(alpha: 0.92)
          : ink.withValues(alpha: 0.28 + dot.depth * 0.4 + dot.relief * 0.12);
      final side = 1 + dot.depth * 0.12;
      canvas.drawRect(
        Rect.fromCenter(center: dot.at, width: side, height: side),
        Paint()..color = color,
      );
    }
  }

  /// One shared transient. [paint] masks it onto a couple of terraces.
  double _spike(double seconds, int i) {
    final a = math.sin(seconds * 11 + i * 0.71);
    final b = math.sin(seconds * 19 + i * 1.37);
    final c = math.sin(seconds * 29 + i * 0.43);
    final mix = a * 0.5 + b * 0.32 + c * 0.18;
    if (mix <= 0) return 0;
    return math.pow(mix, 7).toDouble();
  }

  Color _band(double t) {
    final u = (t.clamp(0.0, 1.0)) * (_sunset.length - 1);
    final i = u.floor().clamp(0, _sunset.length - 2);
    return Color.lerp(_sunset[i], _sunset[i + 1], u - i) ?? _sunset[i];
  }

  @override
  bool shouldRepaint(covariant _CloudPainter old) {
    return old.seconds != seconds || old.speaking != speaking || old.ink != ink;
  }
}
