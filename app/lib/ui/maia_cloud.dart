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
    _grains = [
      for (var i = 0; i < 48; i++) _Grain.sphere(i, 48),
    ];
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
  const _Grain(this.x, this.y, this.z, this.i);

  factory _Grain.sphere(int i, int count) {
    final y = 1 - (i / (count - 1)) * 2;
    final ring = math.sqrt(math.max(0, 1 - y * y));
    final theta = math.pi * (1 + math.sqrt(5)) * i;
    return _Grain(math.cos(theta) * ring, y, math.sin(theta) * ring, i);
  }

  final double x;
  final double y;
  final double z;
  final int i;
}

class _CloudPainter extends CustomPainter {
  const _CloudPainter({
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
    final c = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide * 0.30;
    canvas.drawCircle(
      c,
      radius * 1.35,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = ink.withValues(alpha: 0.28),
    );
    final yaw = seconds * 0.35;
    final drawn = <({double z, Offset at, double spike})>[];
    for (final grain in grains) {
      final spike = speaking ? _spike(seconds, grain.i) : 0.0;
      final reach = radius * (0.72 + spike * 0.7);
      final x = grain.x * math.cos(yaw) + grain.z * math.sin(yaw);
      final z = -grain.x * math.sin(yaw) + grain.z * math.cos(yaw);
      drawn.add((
        z: z,
        at: Offset(c.dx + x * reach, c.dy + grain.y * reach),
        spike: spike,
      ));
    }
    drawn.sort((a, b) => a.z.compareTo(b.z));
    for (final dot in drawn) {
      final depth = (dot.z + 1) / 2;
      final color = dot.spike > 0.08
          ? _band(dot.spike).withValues(alpha: 0.95)
          : ink.withValues(alpha: 0.22 + depth * 0.55);
      canvas.drawRect(
        Rect.fromCenter(center: dot.at, width: 1.6, height: 1.6),
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
    return old.seconds != seconds ||
        old.speaking != speaking ||
        old.ink != ink;
  }
}
