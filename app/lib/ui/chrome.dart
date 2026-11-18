import 'package:material_ui/material_ui.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Bridges leftover Material widgets (scaffold, ink, refresh) onto the
/// shadcn slate palette. [ShadApp] does not install a `material_ui` theme.
Widget maiaMaterialTheme(BuildContext context, Widget? child) {
  final scheme = ShadTheme.of(context).colorScheme;
  return Theme(
    data: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: scheme.background,
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
class MaiaScrollFill extends StatelessWidget {
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
                constraints: BoxConstraints(
                  maxWidth: maxWidth ?? innerWidth,
                ),
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
class MaiaPane extends StatelessWidget {
  const new({
    required this.body,
    super.key,
    this.header,
    this.footer,
  });

  final Widget? header;
  final Widget body;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.maxHeight.isFinite || constraints.maxHeight <= 0) {
          return const SizedBox.shrink();
        }
        final cap = constraints.maxHeight * 0.45;
        Widget chrome(Widget child) {
          return ConstrainedBox(
            constraints: BoxConstraints(maxHeight: cap),
            child: SingleChildScrollView(
              child: child,
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (header != null) chrome(header!),
            Expanded(child: body),
            if (footer != null) chrome(footer!),
          ],
        );
      },
    );
  }
}

class MaiaHeader extends StatelessWidget {
  const new({
    super.key,
    required this.title,
    this.leading,
    this.actions = const [],
  });

  final String title;
  final Widget? leading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.background,
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
                  child: Text(
                    title,
                    style: theme.textTheme.h4,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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

class MaiaDivider extends StatelessWidget {
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
class MaiaSkeleton extends StatelessWidget {
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

class MaiaFailure extends StatelessWidget {
  const new({super.key, required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return MaiaScrollFill(
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
          ShadButton.outline(
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

class MaiaEmpty extends StatelessWidget {
  const new(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaiaScrollFill(
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
