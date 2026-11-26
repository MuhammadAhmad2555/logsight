import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/browser_chrome.dart';
import 'core/glass.dart';
import 'core/theme.dart';
import 'firebase_options.dart';
import 'router.dart';
import 'state/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  final prefs = await SharedPreferences.getInstance();
  runApp(ProviderScope(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)], child: const LogSightApp()));
}

class LogSightApp extends ConsumerWidget {
  const LogSightApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return MaterialApp.router(
      title: 'LogSight',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: mode,
      routerConfig: ref.watch(routerProvider),
      builder: (context, child) => LayoutBuilder(
        builder: (context, constraints) {
          final content = AppBackground(child: child ?? const SizedBox.shrink());
          final platformBrightness = MediaQuery.platformBrightnessOf(context);
          final brightness = switch (mode) {
            ThemeMode.dark => Brightness.dark,
            ThemeMode.light => Brightness.light,
            ThemeMode.system => platformBrightness,
          };
          if (kIsWeb) setBrowserChrome(brightness);
          if (!kIsWeb || constraints.maxWidth >= 700) return content;
          return Theme(data: buildTheme(brightness, mobileOverride: true), child: content);
        },
      ),
    );
  }
}
