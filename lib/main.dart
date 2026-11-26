import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/browser_chrome.dart';
import 'core/glass.dart';
import 'core/theme.dart';
import 'core/time_format.dart';
import 'firebase_options.dart';
import 'router.dart';
import 'state/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  final prefs = await SharedPreferences.getInstance();
  runApp(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: const LogSightApp(),
    ),
  );
}

class LogSightApp extends ConsumerWidget {
  const LogSightApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final clock = ref.watch(clockFormatProvider);
    return MaterialApp.router(
      title: 'LogSight',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: mode,
      routerConfig: ref.watch(routerProvider),
      builder: (context, child) {
        // The Clock setting, applied app-wide through MediaQuery (see
        // core/time_format.dart); System keeps the device's own choice.
        final media = MediaQuery.of(context);
        final h24 = switch (clock) {
          ClockFormat.h12 => false,
          ClockFormat.h24 => true,
          ClockFormat.system => media.alwaysUse24HourFormat,
        };
        clockUse24h = h24;
        return MediaQuery(
          data: media.copyWith(alwaysUse24HourFormat: h24),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final content = AppBackground(
                child: child ?? const SizedBox.shrink(),
              );
              final platformBrightness = MediaQuery.platformBrightnessOf(
                context,
              );
              final brightness = switch (mode) {
                ThemeMode.dark => Brightness.dark,
                ThemeMode.light => Brightness.light,
                ThemeMode.system => platformBrightness,
              };
              if (kIsWeb) setBrowserChrome(brightness);
              // Status bar icons follow the app's theme (screens without an
              // AppBar too); AppBars set the same style via the theme.
              final themed = AnnotatedRegion<SystemUiOverlayStyle>(
                value: systemBarsFor(brightness),
                child: content,
              );
              if (!kIsWeb || constraints.maxWidth >= 700) return themed;
              return Theme(
                data: buildTheme(brightness, mobileOverride: true),
                child: themed,
              );
            },
          ),
        );
      },
    );
  }
}
