import 'dart:ui' as ui;

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:maie_app/config/field_cubit.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Bone paper behind the mark, and the glass fill.
const bone = Color(0xFFF2F0EB);

/// Ink for type and the dark primary button.
const ink = Color(0xFF14120F);

/// True when the mark is the page background. False if the cubit is absent,
/// which is how a widget test that never mounts [FieldCubit] stays opaque.
bool watchField(BuildContext context) {
  try {
    return context.watch<FieldCubit>().state;
  } on ProviderNotFoundException {
    return false;
  }
}

/// Frosted bone. [opacity] is the fill. A lower one is chrome, a higher
/// one is a surface you read.
class MaieGlass extends StatelessWidget {
  const new({
    required this.child,
    this.opacity = 0.72,
    this.sigma = 18,
    this.radius = 0,
    this.border = true,
    super.key,
  });

  final Widget child;
  final double opacity;
  final double sigma;
  final double radius;
  final bool border;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    return ClipRRect(
      borderRadius: r,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: bone.withValues(alpha: opacity),
            borderRadius: r,
            border: border
                ? Border.all(color: ink.withValues(alpha: 0.12))
                : null,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// shadcn colors while the field is on. Fills go translucent so the blur
/// under them reads as glass. Ink on a primary button stays dark enough
/// to hit.
ShadThemeData maieFieldTheme(ShadThemeData theme) {
  final veil = bone.withValues(alpha: 0.58);
  final panel = bone.withValues(alpha: 0.84);
  final reading = bone.withValues(alpha: 0.92);
  return theme.copyWith(
    colorScheme: theme.colorScheme.copyWith(
      background: panel,
      card: reading,
      popover: bone.withValues(alpha: 0.94),
      secondary: veil,
      muted: bone.withValues(alpha: 0.72),
      accent: bone.withValues(alpha: 0.48),
    ),
    primaryButtonTheme: theme.primaryButtonTheme.copyWith(
      backgroundColor: ink.withValues(alpha: 0.9),
      hoverBackgroundColor: ink.withValues(alpha: 0.96),
      pressedBackgroundColor: ink,
      foregroundColor: bone,
      hoverForegroundColor: bone,
    ),
    secondaryButtonTheme: theme.secondaryButtonTheme.copyWith(
      backgroundColor: veil,
      hoverBackgroundColor: bone.withValues(alpha: 0.76),
      pressedBackgroundColor: bone.withValues(alpha: 0.84),
      foregroundColor: ink,
      hoverForegroundColor: ink,
    ),
    outlineButtonTheme: theme.outlineButtonTheme.copyWith(
      backgroundColor: bone.withValues(alpha: 0.4),
      hoverBackgroundColor: bone.withValues(alpha: 0.64),
      pressedBackgroundColor: bone.withValues(alpha: 0.76),
      foregroundColor: ink,
      hoverForegroundColor: ink,
    ),
    ghostButtonTheme: theme.ghostButtonTheme.copyWith(
      hoverBackgroundColor: bone.withValues(alpha: 0.38),
      foregroundColor: ink,
      hoverForegroundColor: ink,
    ),
    cardTheme: theme.cardTheme.copyWith(backgroundColor: reading),
  );
}
