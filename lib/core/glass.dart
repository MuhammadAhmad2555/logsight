import 'dart:ui';

import 'package:flutter/material.dart';

import 'theme.dart';

/// iOS-style "glass" surfaces: a frosted blur of what's behind, a light tint,
/// a thin bright edge and a soft highlight from the top-left.
///
/// Glass only reads as glass over something colourful, so [AppBackground]
/// paints soft colour glows behind every screen.

bool _dark(BuildContext context) => Theme.of(context).brightness == Brightness.dark;

/// Soft gradient with colour glows. Wraps the whole app (MaterialApp.builder).
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = _dark(context);
    final compact = MediaQuery.sizeOf(context).width < 700;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? (compact
                    ? const [Color(0xFF10131E), Color(0xFF111522), Color(0xFF0E1720)]
                    : const [Color(0xFF0A0C1B), Color(0xFF110E2B), Color(0xFF0B1424)])
              : (compact
                    ? const [Color(0xFFF5F6FA), Color(0xFFF1F3F8), Color(0xFFF6F7FA)]
                    : const [Color(0xFFEFF2FF), Color(0xFFF6F2FF), Color(0xFFEFF8FB)]),
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Opacity(
            opacity: compact ? 0.28 : 1,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _Glow(alignment: const Alignment(-1.1, -1.0), color: const Color(0xFF4C6EF5), size: 620, dark: dark),
                _Glow(alignment: const Alignment(1.15, -0.35), color: const Color(0xFF9C36B5), size: 520, dark: dark),
                _Glow(alignment: const Alignment(0.2, 1.25), color: const Color(0xFF20C997), size: 560, dark: dark),
              ],
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _Glow extends StatelessWidget {
  const _Glow({required this.alignment, required this.color, required this.size, required this.dark});

  final Alignment alignment;
  final Color color;
  final double size;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Align(
        alignment: alignment,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                color.withValues(alpha: dark ? 0.30 : 0.22),
                color.withValues(alpha: 0),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A frosted-glass panel.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.radius = 20,
    this.padding,
    this.blur = 22,
    this.strength = 1,
    this.borderColor,
    this.shadow = true,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final double blur;

  /// 0..1+: how opaque the tint is (higher = more solid, easier to read).
  final double strength;
  final Color? borderColor;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final dark = _dark(context);
    final mobile = isMobileLayout(context);
    final r = BorderRadius.circular(radius);
    final tint = dark
        ? Colors.white.withValues(alpha: ((mobile ? 0.09 : 0.07) * strength).clamp(0, 1))
        : Colors.white.withValues(alpha: ((mobile ? 0.90 : 0.58) * strength).clamp(0, 1));
    final edge =
        borderColor ??
        (dark
            ? Colors.white.withValues(alpha: mobile ? 0.10 : 0.14)
            : Colors.white.withValues(alpha: mobile ? 0.96 : 0.85));
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: shadow && !mobile
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? 0.35 : 0.07),
                  blurRadius: 30,
                  offset: const Offset(0, 12),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: r,
        child: mobile
            ? _GlassSurface(
                tint: tint,
                edge: edge,
                dark: dark,
                radius: radius,
                child: padding == null ? child : Padding(padding: padding!, child: child),
              )
            : BackdropFilter(
                filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                child: _GlassSurface(
                  tint: tint,
                  edge: edge,
                  dark: dark,
                  radius: radius,
                  child: padding == null ? child : Padding(padding: padding!, child: child),
                ),
              ),
      ),
    );
  }
}

class _GlassSurface extends StatelessWidget {
  const _GlassSurface({
    required this.tint,
    required this.edge,
    required this.dark,
    required this.radius,
    required this.child,
  });

  final Color tint;
  final Color edge;
  final bool dark;
  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      DecoratedBox(
        decoration: BoxDecoration(
          color: tint,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: edge, width: 1),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Colors.white.withValues(alpha: dark ? 0.06 : 0.22), Colors.white.withValues(alpha: 0)],
            stops: const [0, 0.55],
          ),
        ),
        child: child,
      );
}

/// Drop-in replacement for [Card] using glass.
class GlassCard extends StatelessWidget {
  const GlassCard({super.key, required this.child, this.clipBehavior, this.shape});

  final Widget child;

  /// Accepted for drop-in compatibility with [Card]; glass always clips.
  final Clip? clipBehavior;

  /// Only the border colour of a [RoundedRectangleBorder] is used.
  final ShapeBorder? shape;

  @override
  Widget build(BuildContext context) {
    final s = shape;
    final border = s is RoundedRectangleBorder && s.side != BorderSide.none ? s.side.color : null;
    return GlassPanel(
      radius: 18,
      borderColor: border,
      child: Material(type: MaterialType.transparency, child: child),
    );
  }
}
