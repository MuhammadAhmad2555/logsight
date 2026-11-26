// Renders the log list rows with the app's fonts and theme so the design
// can be checked visually:  flutter test --update-goldens test/goldens
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trackapp/core/severity.dart';
import 'package:trackapp/core/theme.dart';
import 'package:trackapp/data/models.dart';
import 'package:trackapp/features/logs/logs_screen.dart';

Future<void> _font(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    loader.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
  }
  await loader.load();
}

LogEntry _log(String msg, Severity sev, String service, DateTime t) => LogEntry(
  id: '$msg$t',
  timestamp: t,
  severity: sev,
  message: msg,
  service: service,
  attributes: const {},
  tokens: const {},
);

void main() {
  setUpAll(() async {
    await _font('Inter', ['assets/fonts/Inter-400.ttf', 'assets/fonts/Inter-500.ttf', 'assets/fonts/Inter-600.ttf', 'assets/fonts/Inter-700.ttf']);
    await _font('JetBrainsMono', ['assets/fonts/JetBrainsMono-400.ttf', 'assets/fonts/JetBrainsMono-600.ttf']);
    await _font('MaterialIcons', ['${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
  });

  Widget rows(bool wide) {
    final t = DateTime(2026, 11, 26, 23, 8, 4, 132);
    LogRow row(String m, Severity s, {String svc = 'keyo_ios', int n = 1, Duration? span, bool nested = false, bool sel = false, int ago = 0}) =>
        LogRow(
          log: _log(m, s, svc, t.subtract(Duration(milliseconds: ago))),
          wide: wide,
          selected: sel,
          onTap: () {},
          groupCount: n,
          groupSpan: span,
          expanded: n > 1 && nested == false && m.contains('completion'),
          onToggle: n > 1 ? () {} : null,
          nested: nested,
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LogDayDivider(DateTime(2026, 11, 26)),
        row('KeyoBackend iap.store_transaction_finished', Severity.info, n: 46, span: const Duration(seconds: 25)),
        row('KeyoBackend iap.completion_call', Severity.info, n: 3, span: const Duration(milliseconds: 50), ago: 28),
        row('KeyoBackend iap.completion_call', Severity.info, nested: true, ago: 28),
        row('KeyoBackend iap.completion_call', Severity.info, nested: true, ago: 41),
        row('KeyoBackend iap.completion_call', Severity.info, nested: true, ago: 78),
        row('Slow response from /api/verify (2300 ms)', Severity.warn, svc: 'keyo_backend', ago: 1500),
        row('Payment failed for order 42: SocketException: Connection reset by peer', Severity.error, svc: 'keyo_backend', ago: 1600, sel: false),
        row('Paywall opened', Severity.info, ago: 153408, sel: true),
        row('Screen viewed', Severity.debug, svc: 'keyo_android', n: 6, span: const Duration(minutes: 3), ago: 165169),
        row('Crash: Null check operator used on a null value', Severity.fatal, svc: 'keyo_android', ago: 170000),
      ],
    );
  }

  for (final b in Brightness.values) {
    for (final wide in [true, false]) {
      testWidgets('log rows ${b.name} ${wide ? 'wide' : 'phone'}', (tester) async {
        tester.view.physicalSize = Size(wide ? 1200 : 390, wide ? 420 : 820);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildTheme(b),
            home: Scaffold(
              backgroundColor: b == Brightness.dark ? const Color(0xFF121218) : const Color(0xFFF4F4F8),
              body: MediaQuery(
                data: const MediaQueryData(alwaysUse24HourFormat: false),
                child: Builder(builder: (_) => rows(wide)),
              ),
            ),
          ),
        );
        await expectLater(find.byType(Scaffold), matchesGoldenFile('log_rows_${b.name}_${wide ? 'wide' : 'phone'}.png'));
      });
    }
  }
}
