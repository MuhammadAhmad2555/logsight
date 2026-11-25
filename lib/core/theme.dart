import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

const _seed = Color(0xFF4C6EF5);

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness).copyWith(
    primary: dark ? const Color(0xFF8FA6FF) : const Color(0xFF4058E0),
    surface: dark ? const Color(0xFF14152A) : const Color(0xFFFBFBFF),
    outlineVariant: dark ? Colors.white.withValues(alpha: 0.10) : const Color(0xFF1B1F3B).withValues(alpha: 0.10),
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: brightness);
  final text = base.textTheme.apply(
    bodyColor: dark ? const Color(0xFFE9EAF6) : const Color(0xFF1B1F3B),
    displayColor: dark ? const Color(0xFFF4F5FF) : const Color(0xFF14172E),
  );
  final pill = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
  final fieldFill = dark ? Colors.white.withValues(alpha: 0.06) : Colors.white.withValues(alpha: 0.65);

  return base.copyWith(
    // Screens are transparent so the AppBackground glow shows through glass.
    scaffoldBackgroundColor: Colors.transparent,
    canvasColor: Colors.transparent,
    textTheme: text.copyWith(
      headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4),
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleMedium?.copyWith(fontWeight: FontWeight.w700, fontSize: 17),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: 64,
      indicatorColor: scheme.primary.withValues(alpha: dark ? 0.22 : 0.14),
      indicatorShape: pill,
      labelTextStyle: WidgetStatePropertyAll(text.labelSmall?.copyWith(fontWeight: FontWeight.w600)),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: fieldFill,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: dark ? const Color(0xF0181A33) : const Color(0xF5FFFFFF),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: dark ? const Color(0xF2181A33) : const Color(0xF7FFFFFF),
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: dark ? const Color(0xF51B1D38) : const Color(0xFAFFFFFF),
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: fieldFill,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(shape: pill)),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: pill,
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(shape: pill)),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        backgroundColor: fieldFill,
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1, thickness: 1),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: fieldFill,
      side: BorderSide(color: scheme.outlineVariant),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    listTileTheme: const ListTileThemeData(shape: RoundedRectangleBorder()),
  );
}

const monoStyle = TextStyle(fontFamily: 'monospace', fontFamilyFallback: ['Menlo', 'Consolas', 'Courier New']);

/// True on desktop apps (macOS, Windows, Linux) and desktop web browsers.
/// These always use the desktop layout (sidebar, side panels), however narrow
/// the window gets. Phones and mobile browsers use the phone layout.
bool get isDesktopPlatform {
  final p = defaultTargetPlatform;
  final mobile = p == TargetPlatform.iOS || p == TargetPlatform.android || p == TargetPlatform.fuchsia;
  return !mobile;
}

/// Desktop layout: always on desktop platforms; on phones and tablets only
/// when the screen is wide (e.g. iPad landscape).
bool isWide(BuildContext context) => isDesktopPlatform || MediaQuery.sizeOf(context).width >= 900;
