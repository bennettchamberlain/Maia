import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// A ring of points. It turns on its own. While [speaking], points kick
/// outward in short spikes that stand in for a voice. No audio analysis.
class MaiaCloud extends StatefulWidget {
  const new({this.speaking = false, this.size = 76, super.key});

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
    _grains = _ring();
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
  const new(this.angle, this.radius, this.i, this.core);

  final double angle;
  final double radius;
  final int i;
  final double core;
}

/// A tick ring. Most points sit on the circle. A few sit just off it.
List<_Grain> _ring() {
  final random = math.Random(11);
  double gauss() {
    final u = math.max(1e-9, random.nextDouble());
    final v = random.nextDouble();
    return math.sqrt(-2 * math.log(u)) * math.cos(2 * math.pi * v);
  }

  final grains = <_Grain>[];
  const count = 168;
  for (var n = 0; n < count; n++) {
    final wobble = gauss() * 0.028;
    final core = math.exp(-(wobble * wobble) / 0.0008).clamp(0.25, 1.0);
    grains.add(_Grain((n / count) * math.pi * 2, 0.78 + wobble, n, core));
  }
  for (var n = 0; n < 28; n++) {
    final sign = random.nextBool() ? 1.0 : -1.0;
    final radius = 0.78 + sign * (0.06 + random.nextDouble() * 0.1);
    grains.add(
      _Grain(random.nextDouble() * math.pi * 2, radius, count + n, 0.3),
    );
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
    Color(0xFF08040E),
    Color(0xFF4A0C56),
    Color(0xFFFF2A6A),
    Color(0xFFFF5C24),
    Color(0xFFFFBA40),
    Color(0xFFFFF4E0),
    Color(0xFFFFFFFF),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final span = size.shortestSide * 0.42;
    final origin = Offset(size.width / 2, size.height / 2);
    final spin = seconds * 0.22;
    final breathe = 1 + math.sin(seconds * 0.35) * 0.03;
    for (final grain in grains) {
      final spike = speaking ? _spike(seconds, grain.i) : 0.0;
      final radius = (grain.radius + spike * 0.24) * breathe;
      final angle = grain.angle + spin;
      final at = Offset(
        origin.dx + math.cos(angle) * radius * span,
        origin.dy + math.sin(angle) * radius * span,
      );
      final color = spike > 0.08
          ? _band(spike).withValues(alpha: 0.95)
          : ink.withValues(alpha: 0.28 + grain.core * 0.62);
      final dot = 1.1 + grain.core * 0.9;
      canvas.drawRect(
        Rect.fromCenter(center: at, width: dot, height: dot),
        Paint()..color = color,
      );
    }
  }

  /// A few sines, raised hard, so most frames are quiet and a few points
  /// kick out like a transient.
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
