import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trackapp/core/time_format.dart';
import 'package:trackapp/data/log_query.dart';

void main() {
  final t = DateTime(2026, 11, 26, 14, 5, 9, 42);

  test('12- and 24-hour patterns', () {
    expect(timeFormatFor(true).format(t), '14:05');
    expect(timeFormatFor(false).format(t), '2:05 PM');
    expect(timeFormatFor(true, date: 'MMM dd', millis: true).format(t), 'Nov 26 14:05:09.042');
    expect(timeFormatFor(false, date: 'MMM dd', millis: true).format(t), 'Nov 26 2:05:09.042 PM');
    expect(timeFormatFor(false, seconds: true).format(DateTime(2026, 1, 1, 0, 7)), '12:07:00 AM');
  });

  test('custom time range labels follow the clock setting', () {
    final r = TimeRange.absolute(DateTime(2026, 11, 26, 9), DateTime(2026, 11, 26, 18, 30));
    clockUse24h = true;
    expect(r.label, '2026-11-26 09:00 → 2026-11-26 18:30');
    clockUse24h = false;
    expect(r.label, '2026-11-26 9:00 AM → 2026-11-26 6:30 PM');
    clockUse24h = true;
  });

  testWidgets('widgets read the setting from MediaQuery', (tester) async {
    Future<String> render(bool h24) async {
      late String out;
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(alwaysUse24HourFormat: h24),
          child: Builder(builder: (context) {
            out = timeFormat(context, seconds: true).format(t);
            return const SizedBox();
          }),
        ),
      );
      return out;
    }

    expect(await render(true), '14:05:09');
    expect(await render(false), '2:05:09 PM');
  });
}
