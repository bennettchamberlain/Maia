import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// A slow point cloud. While [speaking], points kick outward in short
/// spikes that stand in for a voice. No audio analysis.
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
    _grains = _arch();
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
  const new(this.x, this.off, this.i, this.core);

  final double x;
  final double off;
  final int i;
  final double core;
}

/// A shallow arch. Dense on the spine, thin at the ends, a few points off
/// the curve. Same drawing as the app icon.
List<_Grain> _arch() {
  final random = math.Random(11);
  double gauss() {
    final u = math.max(1e-9, random.nextDouble());
    final v = random.nextDouble();
    return math.sqrt(-2 * math.log(u)) * math.cos(2 * math.pi * v);
  }

  final grains = <_Grain>[];
  var i = 0;
  void add(double x, double off, double spread) {
    final y = 0.24 * math.pow(x / 0.92, 2) + off;
    if (x.abs() > 0.96 || y < -0.32 || y > 0.58) return;
    final core = math.exp(-(off * off) / (2 * spread * spread + 1e-6));
    grains.add(_Grain(x, off, i, core));
    i++;
  }

  for (var n = 0; n < 36; n++) {
    final x = -0.88 + (1.76 * n / 35);
    add(x, gauss() * 0.016, 0.016);
  }
  for (var n = 0; n < 180; n++) {
    final sign = random.nextBool() ? -1.0 : 1.0;
    final x = sign * math.pow(random.nextDouble(), 1.35) * 0.92;
    final spread = 0.022 + 0.06 * (x.abs() / 0.92);
    var off = gauss() * spread;
    if (random.nextDouble() < 0.1) {
      off += (random.nextBool() ? 1 : -1) * (0.05 + random.nextDouble() * 0.16);
    }
    add(x, off, spread);
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
    final origin = Offset(size.width / 2, size.height * 0.46);
    final drift = math.sin(seconds * 0.2) * 0.03;
    for (final grain in grains) {
      final spike = speaking ? _spike(seconds, grain.i) : 0.0;
      final wobble = math.sin(seconds * 0.45 + grain.i * 0.17) * 0.012;
      final kick = spike * 0.28 * (grain.off >= 0 ? 1 : -1);
      final x = grain.x + drift;
      final y = 0.24 * math.pow(x / 0.92, 2) + grain.off * (1 + wobble) + kick;
      final at = Offset(origin.dx + x * span, origin.dy + y * span);
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
