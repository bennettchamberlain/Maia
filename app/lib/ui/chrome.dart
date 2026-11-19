import 'package:maie_app/ui/glass.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Bridges leftover Material widgets (scaffold, ink, refresh) onto the
/// shadcn slate palette. [ShadApp] does not install a `material_ui` theme.
///
/// [field] leaves the scaffold clear so the mark shows in the gaps.
Widget maieMaterialTheme(
  BuildContext context,
  Widget? child, {
  bool field = false,
}) {
  final scheme = ShadTheme.of(context).colorScheme;
  final paper = field ? Colors.transparent : scheme.background;
  return Theme(
    data: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: paper,
      canvasColor: paper,
      dividerColor: scheme.border,
      colorScheme: ColorScheme.light(
        primary: scheme.primary,
        onPrimary: scheme.primaryForeground,
        secondary: scheme.secondary,
        onSecondary: scheme.secondaryForeground,
        surface: scheme.card,
        onSurface: scheme.foreground,
        error: scheme.destructive,
        onError: scheme.destructiveForeground,
        outline: scheme.border,
      ),
    ),
    child: child ?? const SizedBox.shrink(),
  );
}

/// Fills the viewport and scrolls when [child] is taller than the window.
///
/// The child is centered when there is spare room, and forced to the
/// viewport width so text wraps instead of painting a horizontal overflow.
class MaieScrollFill extends StatelessWidget {
  const new({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.maxWidth,
    this.alignment = Alignment.center,
  });

  final Widget child;
  final EdgeInsets padding;
  final double? maxWidth;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 0.0;
        final height = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 0.0;
        final innerWidth = (width - padding.horizontal).clamp(0.0, width);
        final innerHeight = (height - padding.vertical).clamp(0.0, height);
        return SingleChildScrollView(
          padding: padding,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: innerWidth,
              maxWidth: innerWidth,
              minHeight: innerHeight,
            ),
            child: Align(
              alignment: alignment,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth ?? innerWidth),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Pins [header] and [footer] and gives [body] whatever height is left.
///
/// Header and footer scroll inside a capped slice when the window is too
/// short for them, so a small desktop window cannot overflow the column.
class MaiePane extends StatelessWidget {
  const new({
    required this.body,
    super.key,
    this.header,
    this.footer,
    this.plate = true,
  });

  final Widget? header;
  final Widget body;
  final Widget? footer;

  /// When the field is on, the body sits on a dense glass sheet and the
  /// header and footer sit on a thinner one. A sidebar passes false
  /// because it already has its own glass.
  final bool plate;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.maxHeight.isFinite || constraints.maxHeight <= 0) {
          return const SizedBox.shrink();
        }
        final cap = constraints.maxHeight * 0.45;
        final field = watchField(context);
        Widget chrome(Widget child) {
          final capped = ConstrainedBox(
            constraints: BoxConstraints(maxHeight: cap),
            child: SingleChildScrollView(child: child),
          );
          if (!field || !plate) return capped;
          return MaieGlass(
            opacity: 0.52,
            sigma: 16,
            border: false,
            child: capped,
          );
        }

        Widget sheet(Widget child) {
          if (!field || !plate) return child;
          return Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
            child: MaieGlass(
              opacity: 0.84,
              sigma: 20,
              radius: 18,
              child: child,
            ),
          );
        }

        return SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (header != null) chrome(header!),
              Expanded(child: sheet(body)),
              if (footer != null) chrome(footer!),
            ],
          ),
        );
      },
    );
  }
}

class MaieHeader extends StatelessWidget {
  const new({
    super.key,
    required this.title,
    this.leading,
    this.actions = const [],
    this.onTitleTap,
  });

  final String title;
  final Widget? leading;
  final List<Widget> actions;
  final VoidCallback? onTitleTap;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final field = watchField(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: field ? Colors.transparent : theme.colorScheme.background,
        border: Border(bottom: BorderSide(color: theme.colorScheme.border)),
      ),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 52,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                ?leading,
                Expanded(
                  child: GestureDetector(
                    onTap: onTitleTap,
                    child: Text(
                      title,
                      style: theme.textTheme.h4,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                if (actions.isNotEmpty)
                  Flexible(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: actions,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class MaieDivider extends StatelessWidget {
  const new vertical({super.key}) : axis = Axis.vertical;

  const new horizontal({super.key}) : axis = Axis.horizontal;

  final Axis axis;

  @override
  Widget build(BuildContext context) {
    final color = ShadTheme.of(context).colorScheme.border;
    return ColoredBox(
      color: color,
      child: axis == Axis.vertical
          ? const SizedBox(width: 1)
          : const SizedBox(height: 1),
    );
  }
}

/// shadcn/ui has no Skeleton widget in 0.57. Muted blocks pulse the same way.
class MaieSkeleton extends StatelessWidget {
  const new({super.key, this.rows = 6});

  final int rows;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (var i = 0; i < rows; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _Pulse(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: theme.colorScheme.border),
                  borderRadius: const BorderRadius.all(Radius.circular(8)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Bar(color: theme.colorScheme.muted, width: 148),
                      const SizedBox(height: 8),
                      _Bar(color: theme.colorScheme.muted),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class MaieFailure extends StatelessWidget {
  const new({super.key, required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return MaieScrollFill(
      padding: const EdgeInsets.all(24),
      maxWidth: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ShadAlert.destructive(
            title: const Text('Could not load'),
            description: Text(message),
          ),
          const SizedBox(height: 12),
          ShadButton.outline(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

/// A button that keeps its label and shows a spinner while [busy].
class MaieBusyButton extends StatelessWidget {
  const new({
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.busyLabel,
    this.outline = false,
    this.enabled = true,
    this.size,
    this.width,
    super.key,
  });

  final String label;
  final String? busyLabel;
  final bool busy;
  final bool enabled;
  final bool outline;
  final VoidCallback onPressed;
  final ShadButtonSize? size;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final spinner = theme.colorScheme.primaryForeground;
    final child = AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: busy
          ? Row(
              key: const ValueKey('busy'),
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: outline ? theme.colorScheme.foreground : spinner,
                  ),
                ),
                if (busyLabel != null) ...[
                  const SizedBox(width: 8),
                  Text(busyLabel!),
                ],
              ],
            )
          : Text(label, key: const ValueKey('idle')),
    );
    if (outline) {
      return ShadButton.outline(
        size: size,
        width: width,
        onPressed: busy || !enabled ? null : onPressed,
        child: child,
      );
    }
    return ShadButton(
      size: size,
      width: width,
      onPressed: busy || !enabled ? null : onPressed,
      child: child,
    );
  }
}

/// An icon button whose glyph turns while [busy].
class MaieBusyIcon extends StatefulWidget {
  const new({
    required this.icon,
    required this.onPressed,
    this.busy = false,
    super.key,
  });

  final Widget icon;
  final VoidCallback onPressed;
  final bool busy;

  @override
  State<MaieBusyIcon> createState() => _MaieBusyIconState();
}

class _MaieBusyIconState extends State<MaieBusyIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  @override
  void initState() {
    super.initState();
    if (widget.busy) _spin.repeat();
  }

  @override
  void didUpdateWidget(MaieBusyIcon old) {
    super.didUpdateWidget(old);
    if (widget.busy && !_spin.isAnimating) _spin.repeat();
    if (!widget.busy && _spin.isAnimating) {
      _spin
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ShadIconButton.ghost(
      onPressed: widget.busy ? null : widget.onPressed,
      icon: RotationTransition(turns: _spin, child: widget.icon),
    );
  }
}

class MaieEmpty extends StatelessWidget {
  const new(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaieScrollFill(
      padding: const EdgeInsets.all(24),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: ShadTheme.of(context).textTheme.muted,
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const new({required this.color, this.width});

  final Color color;
  final double? width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width ?? double.infinity,
      height: 12,
      decoration: BoxDecoration(
        color: color,
        borderRadius: const BorderRadius.all(Radius.circular(6)),
      ),
    );
  }
}

class _Pulse extends StatefulWidget {
  const new({required this.child});

  final Widget child;

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller.drive(Tween<double>(begin: 0.45, end: 1)),
      child: widget.child,
    );
  }
}

/// Grows and shrinks [child] on a cubic curve.
class MaieExpand extends StatelessWidget {
  const new({required this.expanded, required this.child, super.key});

  final bool expanded;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeInOutCubic,
      alignment: Alignment.topCenter,
      child: expanded
          ? child
          : const SizedBox(width: double.infinity, height: 0),
    );
  }
}
