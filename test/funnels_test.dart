import 'package:flutter_test/flutter_test.dart';
import 'package:trackapp/data/activity.dart';
import 'package:trackapp/data/funnels.dart';

var _n = 0;
ActivityEvent _e(String person, String event, DateTime at) => ActivityEvent(
  id: 'e${_n++}',
  event: event,
  distinctId: person,
  timestamp: at,
  properties: const {},
);

void main() {
  final t0 = DateTime(2026, 11, 20, 9);
  DateTime m(int minutes) => t0.add(Duration(minutes: minutes));
  const steps = ['app_open', 'signup', 'purchase'];

  group('computeFunnel', () {
    test('counts people who did the steps in order within the window', () {
      final r = computeFunnel([
        // a: all three in order.
        _e('a', 'app_open', m(0)), _e('a', 'signup', m(5)), _e('a', 'purchase', m(15)),
        // b: signs up but never buys.
        _e('b', 'app_open', m(0)), _e('b', 'signup', m(10)),
        // c: purchase before signup → only step 1 (and 2).
        _e('c', 'app_open', m(0)), _e('c', 'purchase', m(1)), _e('c', 'signup', m(2)),
        // d: purchase too late (outside the 1 h window).
        _e('d', 'app_open', m(0)), _e('d', 'signup', m(1)), _e('d', 'purchase', m(90)),
        // e: never opened the app → not in the funnel.
        _e('e', 'signup', m(0)), _e('e', 'purchase', m(1)),
        // other events are ignored
        _e('a', r'$screen', m(3)),
      ], steps, const Duration(hours: 1));
      expect(r.reached, [4, 4, 1]);
      expect(r.ofFirst(2), 0.25);
      expect(r.ofPrevious(1), 1);
      expect(r.conversion, 0.25);
      // Median app_open → signup: 1, 2, 5, 10 min → 3.5 min.
      expect(r.medianToNext[0], const Duration(minutes: 3, seconds: 30));
      expect(r.medianToNext[1], const Duration(minutes: 10));
      expect(r.medianToNext[2], isNull);
    });

    test('uses the attempt that got furthest', () {
      final r = computeFunnel([
        _e('a', 'app_open', m(0)), // first try goes nowhere within the window
        _e('a', 'app_open', m(200)), _e('a', 'signup', m(201)), _e('a', 'purchase', m(202)),
      ], steps, const Duration(hours: 1));
      expect(r.reached, [1, 1, 1]);
      expect(r.medianToNext[0], const Duration(minutes: 1));
    });

    test('no events', () {
      final r = computeFunnel(const [], steps, const Duration(days: 1));
      expect(r.reached, [0, 0, 0]);
      expect(r.conversion, 0);
    });
  });

  group('computeRetention', () {
    final now = DateTime(2026, 11, 26, 12); // Thursday

    test('daily cohorts, return in later days, unfinished days empty', () {
      final day = (int d, [int h = 10]) => DateTime(2026, 11, 20 + d, h);
      final r = computeRetention(
        [
          // Cohort Nov 20: a, b. a returns day 1 and 2, b day 2 only.
          _e('a', 'signup', day(0)), _e('a', 'app_open', day(1)), _e('a', 'app_open', day(2)),
          _e('b', 'signup', day(0, 22)), _e('b', 'app_open', day(2)),
          // a signing up again later doesn't move a to a newer cohort.
          _e('a', 'signup', day(3)),
          // Cohort Nov 25: c, returns day 1 = today (Nov 26, unfinished) → empty.
          _e('c', 'signup', day(5)), _e('c', 'app_open', day(6, 9)),
          // Same-day return doesn't count as period 1.
          _e('c', 'app_open', day(5, 11)),
        ],
        startEvent: 'signup',
        returnEvent: 'app_open',
        unit: RetentionUnit.day,
        periods: 3,
        from: DateTime(2026, 11, 19),
        now: now,
      );
      expect(r.cohorts.map((c) => c.start), [DateTime(2026, 11, 20), DateTime(2026, 11, 25)]);
      final first = r.cohorts.first;
      expect(first.size, 2);
      expect(first.returned, [1, 2, 0]);
      expect(first.rate(1), 1.0);
      expect(r.cohorts.last.returned, [null, null, null]);
      expect(r.average, [0.5, 1.0, 0.0]);
    });

    test('weekly cohorts start on Monday', () {
      expect(periodStart(DateTime(2026, 11, 26, 15), RetentionUnit.week), DateTime(2026, 11, 23));
      expect(periodStart(DateTime(2026, 11, 23), RetentionUnit.week), DateTime(2026, 11, 23));
      final r = computeRetention(
        [_e('a', 'signup', DateTime(2026, 11, 4)), _e('a', 'signup', DateTime(2026, 11, 12))],
        startEvent: 'signup',
        returnEvent: 'signup',
        unit: RetentionUnit.week,
        periods: 2,
        from: DateTime(2026, 11, 1),
        now: now,
      );
      expect(r.cohorts.single.start, DateTime(2026, 11, 2));
      expect(r.cohorts.single.returned, [1, 0]);
    });
  });
}
