import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// LogSight design system.
///
/// Background and glass surfaces live in glass.dart; this file styles every
/// control that sits on top of them: type, buttons, inputs, chips, menus…
///
/// Principles: one accent colour, 40px controls with 12px corners, quiet
/// borders that strengthen on hover, and a soft accent glow on primary
/// actions.

const _seed = Color(0xFF5B5BF7);

/// Brand accents (also used for gradients on primary actions).
abstract final class Brand {
  static const indigo = Color(0xFF5B5BF7);
  static const violet = Color(0xFF8B5CF6);
  static const indigoLight = Color(0xFF9EA3FF);
  static const violetLight = Color(0xFFC4A8FF);

  static LinearGradient accent(Brightness b) => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: b == Brightness.dark ? const [Color(0xFF7C7FFF), Color(0xFFA27BFF)] : const [indigo, violet],
  );
}

const _font = 'Inter';
const _desktopRadius = 12.0;
const _mobileRadius = 14.0;

/// Status/navigation bar style for a theme: dark icons on the light theme,
/// light icons on the dark theme, with see-through bars.
SystemUiOverlayStyle systemBarsFor(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark).copyWith(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarContrastEnforced: false,
  );
}

ThemeData buildTheme(Brightness brightness, {bool? mobileOverride}) {
  final mobile = mobileOverride ?? isMobilePlatform;
  final radius = mobile ? _mobileRadius : _desktopRadius;
  final controlHeight = mobile ? 48.0 : 40.0;
  final dark = brightness == Brightness.dark;
  final ink = dark ? const Color(0xFFECEDF7) : const Color(0xFF151833);
  final inkMuted = dark ? const Color(0xFFA2A6C4) : const Color(0xFF5D6283);
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness).copyWith(
    primary: dark ? Brand.indigoLight : Brand.indigo,
    onPrimary: dark ? const Color(0xFF0E1030) : Colors.white,
    secondary: dark ? Brand.violetLight : Brand.violet,
    surface: dark ? const Color(0xFF14152A) : const Color(0xFFFBFBFF),
    onSurface: ink,
    onSurfaceVariant: inkMuted,
    outline: dark ? const Color(0xFF6E7293) : const Color(0xFF9397B5),
    outlineVariant: dark ? Colors.white.withValues(alpha: 0.09) : const Color(0xFF151833).withValues(alpha: 0.09),
    error: dark ? const Color(0xFFFF8A8A) : const Color(0xFFE5484D),
    inverseSurface: dark ? const Color(0xFFF1F2FA) : const Color(0xFF1A1C33),
    onInverseSurface: dark ? const Color(0xFF151833) : const Color(0xFFF1F2FA),
  );

  final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: brightness, fontFamily: _font);
  final t = base.textTheme.apply(bodyColor: ink, displayColor: ink, fontFamily: _font);
  final text = t.copyWith(
    headlineMedium: t.headlineMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.8, height: 1.15),
    headlineSmall: t.headlineSmall?.copyWith(
      fontWeight: FontWeight.w700,
      fontSize: 24,
      letterSpacing: -0.6,
      height: 1.2,
    ),
    titleLarge: t.titleLarge?.copyWith(fontWeight: FontWeight.w700, fontSize: 20, letterSpacing: -0.4),
    titleMedium: t.titleMedium?.copyWith(fontWeight: FontWeight.w600, fontSize: 15.5, letterSpacing: -0.2),
    titleSmall: t.titleSmall?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.1),
    bodyLarge: t.bodyLarge?.copyWith(fontSize: 15, letterSpacing: -0.1, height: 1.45),
    bodyMedium: t.bodyMedium?.copyWith(fontSize: 14, letterSpacing: -0.05, height: 1.45),
    bodySmall: t.bodySmall?.copyWith(fontSize: 12.5, color: inkMuted, height: 1.4),
    labelLarge: t.labelLarge?.copyWith(fontWeight: FontWeight.w600, fontSize: 14, letterSpacing: -0.1),
    labelMedium: t.labelMedium?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0),
    labelSmall: t.labelSmall?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.2),
  );

  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));
  final fieldFill = dark
      ? Colors.white.withValues(alpha: mobile ? 0.07 : 0.05)
      : Colors.white.withValues(alpha: mobile ? 0.88 : 0.72);
  final hoverFill = dark ? Colors.white.withValues(alpha: 0.08) : Colors.white.withValues(alpha: 0.92);
  final border = scheme.outlineVariant;
  final borderHover = dark ? Colors.white.withValues(alpha: 0.18) : const Color(0xFF151833).withValues(alpha: 0.18);
  final accentWash = scheme.primary.withValues(alpha: dark ? 0.18 : 0.10);
  const buttonPadding = EdgeInsets.symmetric(horizontal: 16);
  final buttonText = text.labelLarge;
  final controlSize = Size(0, controlHeight);

  Color? hover(Set<WidgetState> s, Color c) => s.contains(WidgetState.pressed)
      ? c.withValues(alpha: 0.16)
      : (s.contains(WidgetState.hovered) || s.contains(WidgetState.focused) ? c.withValues(alpha: 0.08) : null);

  OutlineInputBorder outline(Color c, [double w = 1]) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(radius),
    borderSide: BorderSide(color: c, width: w),
  );

  return base.copyWith(
    // Screens are transparent so the AppBackground glow shows through glass.
    scaffoldBackgroundColor: Colors.transparent,
    canvasColor: Colors.transparent,
    textTheme: text,
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: _font),
    visualDensity: VisualDensity.standard,
    splashFactory: InkSparkle.splashFactory,
    hoverColor: scheme.onSurface.withValues(alpha: 0.04),
    highlightColor: Colors.transparent,
    iconTheme: IconThemeData(color: inkMuted, size: 20),

    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      // A transparent bar reads as "dark" to Flutter, which would always pick
      // white status-bar icons; set them from the theme instead.
      systemOverlayStyle: systemBarsFor(brightness),
      foregroundColor: ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      toolbarHeight: mobile ? 60 : 56,
      titleTextStyle: text.titleMedium?.copyWith(fontWeight: FontWeight.w700, fontSize: 17),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: mobile ? 72 : 66,
      indicatorColor: accentWash,
      indicatorShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(size: 22, color: s.contains(WidgetState.selected) ? scheme.primary : inkMuted),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => text.labelSmall?.copyWith(
          fontSize: 11.5,
          color: s.contains(WidgetState.selected) ? scheme.primary : inkMuted,
        ),
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: fieldFill,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: border),
      ),
    ),

    // ------------------------------------------------------------ overlays
    dialogTheme: DialogThemeData(
      backgroundColor: dark ? const Color(0xF2171932) : const Color(0xF7FFFFFF),
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.22),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: border),
      ),
      titleTextStyle: text.titleLarge,
      contentTextStyle: text.bodyMedium?.copyWith(color: inkMuted),
      actionsPadding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: dark ? const Color(0xF5171932) : const Color(0xF9FFFFFF),
      surfaceTintColor: Colors.transparent,
      dragHandleColor: scheme.outline.withValues(alpha: 0.5),
      dragHandleSize: const Size(36, 4),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: dark ? const Color(0xFA1A1C36) : const Color(0xFCFFFFFF),
      surfaceTintColor: Colors.transparent,
      elevation: 16,
      shadowColor: Colors.black.withValues(alpha: dark ? 0.5 : 0.18),
      menuPadding: const EdgeInsets.all(6),
      textStyle: text.bodyMedium,
      labelTextStyle: WidgetStatePropertyAll(text.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: border),
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(dark ? const Color(0xFA1A1C36) : const Color(0xFCFFFFFF)),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(16),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: border),
          ),
        ),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 350),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      textStyle: text.labelMedium?.copyWith(color: scheme.onInverseSurface, fontWeight: FontWeight.w500),
      decoration: BoxDecoration(color: scheme.inverseSurface, borderRadius: BorderRadius.circular(8)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      elevation: 8,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: text.bodyMedium?.copyWith(color: scheme.onInverseSurface, fontWeight: FontWeight.w500),
      actionTextColor: dark ? Brand.indigo : Brand.indigoLight,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
      insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    ),

    // -------------------------------------------------------------- inputs
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: fieldFill,
      hoverColor: hoverFill,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      hintStyle: text.bodyMedium?.copyWith(color: scheme.outline),
      labelStyle: text.bodyMedium?.copyWith(color: inkMuted),
      floatingLabelStyle: text.bodyMedium?.copyWith(color: scheme.primary, fontWeight: FontWeight.w600),
      helperStyle: text.bodySmall,
      prefixIconColor: WidgetStateColor.resolveWith(
        (s) => s.contains(WidgetState.focused) ? scheme.primary : scheme.outline,
      ),
      suffixIconColor: scheme.outline,
      prefixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      border: outline(border),
      enabledBorder: outline(border),
      disabledBorder: outline(border.withValues(alpha: 0.05)),
      focusedBorder: outline(scheme.primary, 1.6),
      errorBorder: outline(scheme.error.withValues(alpha: 0.7)),
      focusedErrorBorder: outline(scheme.error, 1.6),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: scheme.primary,
      selectionColor: scheme.primary.withValues(alpha: 0.25),
      selectionHandleColor: scheme.primary,
    ),

    // ------------------------------------------------------------- buttons
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(controlSize),
        padding: const WidgetStatePropertyAll(buttonPadding),
        shape: WidgetStatePropertyAll(shape),
        textStyle: WidgetStatePropertyAll(buttonText),
        elevation: const WidgetStatePropertyAll(0),
        iconSize: const WidgetStatePropertyAll(18),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        minimumSize: controlSize,
        padding: buttonPadding,
        shape: shape,
        textStyle: buttonText,
        elevation: 0,
        backgroundColor: hoverFill,
        foregroundColor: ink,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(controlSize),
        padding: const WidgetStatePropertyAll(buttonPadding),
        shape: WidgetStatePropertyAll(shape),
        textStyle: WidgetStatePropertyAll(buttonText),
        iconSize: const WidgetStatePropertyAll(18),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled) ? scheme.onSurface.withValues(alpha: 0.38) : ink,
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.hovered) ? hoverFill : fieldFill,
        ),
        side: WidgetStateProperty.resolveWith(
          (s) => BorderSide(color: s.contains(WidgetState.hovered) ? borderHover : border),
        ),
        overlayColor: WidgetStateProperty.resolveWith((s) => hover(s, ink)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size(0, mobile ? 44 : 36)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
        shape: WidgetStatePropertyAll(shape),
        textStyle: WidgetStatePropertyAll(buttonText),
        iconSize: const WidgetStatePropertyAll(18),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled) ? scheme.onSurface.withValues(alpha: 0.38) : scheme.primary,
        ),
        overlayColor: WidgetStateProperty.resolveWith((s) => hover(s, scheme.primary)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size(mobile ? 44 : 36, mobile ? 44 : 36)),
        iconSize: const WidgetStatePropertyAll(20),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? scheme.primary : inkMuted,
        ),
        overlayColor: WidgetStateProperty.resolveWith((s) => hover(s, ink)),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      elevation: 4,
      focusElevation: 6,
      hoverElevation: 6,
      highlightElevation: 2,
      extendedTextStyle: buttonText,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: const VisualDensity(horizontal: -1, vertical: -2),
        textStyle: WidgetStatePropertyAll(text.labelMedium?.copyWith(fontSize: 13)),
        iconSize: const WidgetStatePropertyAll(16),
        shape: WidgetStatePropertyAll(shape),
        side: WidgetStatePropertyAll(BorderSide(color: border)),
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? accentWash : fieldFill,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? scheme.primary : inkMuted,
        ),
        overlayColor: WidgetStateProperty.resolveWith((s) => hover(s, scheme.primary)),
      ),
    ),
    toggleButtonsTheme: ToggleButtonsThemeData(
      borderRadius: BorderRadius.circular(radius),
      borderColor: border,
      selectedBorderColor: border,
      fillColor: accentWash,
      selectedColor: scheme.primary,
      color: inkMuted,
    ),

    // ---------------------------------------------------------- selections
    chipTheme: ChipThemeData(
      backgroundColor: fieldFill,
      selectedColor: accentWash,
      disabledColor: fieldFill,
      checkmarkColor: scheme.primary,
      deleteIconColor: inkMuted,
      side: WidgetStateBorderSide.resolveWith(
        (s) => BorderSide(color: s.contains(WidgetState.selected) ? scheme.primary.withValues(alpha: 0.45) : border),
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      labelStyle: text.labelMedium?.copyWith(fontSize: 13, color: ink),
      secondaryLabelStyle: text.labelMedium?.copyWith(fontSize: 13, color: scheme.primary),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      labelPadding: const EdgeInsets.symmetric(horizontal: 4),
      iconTheme: IconThemeData(size: 16, color: inkMuted),
      elevation: 0,
      pressElevation: 0,
      showCheckmark: false,
    ),
    switchTheme: SwitchThemeData(
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Colors.transparent : border,
      ),
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Colors.white : scheme.outline,
      ),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? scheme.primary : fieldFill),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      side: BorderSide(color: scheme.outline, width: 1.4),
    ),
    radioTheme: RadioThemeData(fillColor: WidgetStatePropertyAll(scheme.primary)),
    sliderTheme: SliderThemeData(
      trackHeight: 4,
      inactiveTrackColor: border,
      overlayShape: SliderComponentShape.noOverlay,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: border,
      circularTrackColor: Colors.transparent,
      borderRadius: BorderRadius.circular(4),
    ),
    badgeTheme: BadgeThemeData(
      backgroundColor: scheme.primary,
      textColor: scheme.onPrimary,
      textStyle: text.labelSmall,
    ),
    tabBarTheme: TabBarThemeData(
      dividerColor: Colors.transparent,
      labelColor: scheme.primary,
      unselectedLabelColor: inkMuted,
      labelStyle: text.labelLarge,
      unselectedLabelStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w500),
      indicatorSize: TabBarIndicatorSize.tab,
      indicator: BoxDecoration(color: accentWash, borderRadius: BorderRadius.circular(10)),
      overlayColor: WidgetStateProperty.resolveWith((s) => hover(s, scheme.primary)),
      splashBorderRadius: BorderRadius.circular(10),
    ),

    // --------------------------------------------------------------- lists
    dividerTheme: DividerThemeData(color: border, space: 1, thickness: 1),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
      iconColor: inkMuted,
      selectedColor: scheme.primary,
      selectedTileColor: accentWash,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      minLeadingWidth: 24,
      horizontalTitleGap: 12,
      minTileHeight: mobile ? 56 : null,
      minVerticalPadding: mobile ? 10 : null,
      titleTextStyle: text.bodyLarge?.copyWith(fontWeight: FontWeight.w500, fontSize: 14.5, color: ink),
      subtitleTextStyle: text.bodySmall,
    ),
    expansionTileTheme: ExpansionTileThemeData(
      shape: const RoundedRectangleBorder(),
      collapsedShape: const RoundedRectangleBorder(),
      iconColor: inkMuted,
      collapsedIconColor: inkMuted,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(6),
      thumbColor: WidgetStatePropertyAll(scheme.onSurface.withValues(alpha: 0.18)),
      crossAxisMargin: 2,
      mainAxisMargin: 4,
    ),
  );
}

const monoStyle = TextStyle(
  fontFamily: 'JetBrainsMono',
  fontFamilyFallback: ['SF Mono', 'Menlo', 'Consolas', 'Courier New', 'monospace'],
);

/// True on native desktop apps. Web chooses its layout from viewport width.
bool get isDesktopPlatform {
  final p = defaultTargetPlatform;
  return !kIsWeb && p != TargetPlatform.iOS && p != TargetPlatform.android && p != TargetPlatform.fuchsia;
}

bool get isMobilePlatform =>
    defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android;

/// Compact mobile layout on native phones and narrow mobile web viewports.
bool isMobileLayout(BuildContext context) =>
    isMobilePlatform || (kIsWeb && MediaQuery.sizeOf(context).width < 700);

/// Desktop layout: always on native desktop apps, and on web or mobile when
/// the viewport is wide enough for a sidebar and side panels.
bool isWide(BuildContext context) => isDesktopPlatform || MediaQuery.sizeOf(context).width >= 900;
