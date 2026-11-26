import 'activity.dart';

/// Funnels and retention, computed in the app from the events loaded for a
/// time range (like PostHog's Funnels and Retention insights, on a sample).

// ------------------------------------------------------------------- funnels

/// How many people reached each step, in order.
class FunnelResult {
  const FunnelResult({required this.steps, required this.reached, required this.medianToNext});

  final List<String> steps;

  /// People who reached step i (and every step before it, in order).
  final List<int> reached;

  /// Median time from step i to step i + 1 for people who made it
  /// (null for the last step or when nobody did).
  final List<Duration?> medianToNext;

  int get entered => reached.isEmpty ? 0 : reached.first;

  /// Share of the people who entered that reached step [i].
  double ofFirst(int i) => entered == 0 ? 0 : reached[i] / entered;

  /// Share of the people at step i - 1 that reached step [i].
  double ofPrevious(int i) => i == 0 ? 1 : (reached[i - 1] == 0 ? 0 : reached[i] / reached[i - 1]);

  /// Overall conversion: entered → last step.
  double get conversion => steps.isEmpty ? 0 : ofFirst(steps.length - 1);
}

/// An ordered funnel: a person counts at step k if they did steps 1…k in
/// that order, each after the previous one, all within [window] of step 1.
/// Each person is counted once, from the attempt that got furthest (the
/// earliest such attempt for the timings).
FunnelResult computeFunnel(Iterable<ActivityEvent> events, List<String> steps, Duration window) {
  final reached = List.filled(steps.length, 0);
  final gaps = List.generate(steps.length, (_) => <Duration>[]);
  if (steps.isEmpty) return FunnelResult(steps: steps, reached: reached, medianToNext: const []);

  final byPerson = <String, List<ActivityEvent>>{};
  for (final e in events) {
    if (e.distinctId.isEmpty || !steps.contains(e.event)) continue;
    byPerson.putIfAbsent(e.distinctId, () => []).add(e);
  }

  for (final list in byPerson.values) {
    list.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    var best = 0;
    List<DateTime> bestTimes = const [];
    for (var s = 0; s < list.length; s++) {
      if (list[s].event != steps.first) continue;
      final start = list[s].timestamp;
      final deadline = start.add(window);
      final times = <DateTime>[start];
      for (var j = s + 1; j < list.length && times.length < steps.length; j++) {
        final e = list[j];
        if (e.timestamp.isAfter(deadline)) break;
        if (e.event == steps[times.length]) times.add(e.timestamp);
      }
      if (times.length > best) {
        best = times.length;
        bestTimes = times;
        if (best == steps.length) break;
      }
    }
    for (var i = 0; i < best; i++) {
      reached[i]++;
      if (i + 1 < best) gaps[i].add(bestTimes[i + 1].difference(bestTimes[i]));
    }
  }

  return FunnelResult(
    steps: steps,
    reached: reached,
    medianToNext: [for (var i = 0; i < steps.length; i++) i + 1 < steps.length ? _median(gaps[i]) : null],
  );
}

Duration? _median(List<Duration> values) {
  if (values.isEmpty) return null;
  final sorted = [...values]..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) ~/ 2;
}

// ----------------------------------------------------------------- retention

enum RetentionUnit {
  day('Day', Duration(days: 1)),
  week('Week', Duration(days: 7));

  const RetentionUnit(this.label, this.length);
  final String label;
  final Duration length;
}

/// People who first did the start event in one period, and how many came
/// back (did the return event) in each later period.
class RetentionCohort {
  const RetentionCohort({required this.start, required this.size, required this.returned});

  /// Start of the cohort's period (local time).
  final DateTime start;
  final int size;

  /// People who returned in period 1, 2, …; null for periods that haven't
  /// finished yet.
  final List<int?> returned;

  double? rate(int period) {
    final n = returned[period];
    return n == null || size == 0 ? null : n / size;
  }
}

class RetentionResult {
  const RetentionResult({required this.unit, required this.periods, required this.cohorts});

  final RetentionUnit unit;

  /// Periods after the first shown as columns (1…periods).
  final int periods;

  /// Oldest first.
  final List<RetentionCohort> cohorts;

  /// Weighted average return rate for each period, over cohorts where that
  /// period has finished.
  List<double?> get average => [
    for (var p = 0; p < periods; p++)
      () {
        var size = 0, back = 0;
        for (final c in cohorts) {
          final n = c.returned[p];
          if (n == null) continue;
          size += c.size;
          back += n;
        }
        return size == 0 ? null : back / size;
      }(),
  ];
}

/// Start of the [unit] period containing [t] (local midnight; weeks start Monday).
DateTime periodStart(DateTime t, RetentionUnit unit) {
  final l = t.toLocal();
  final day = DateTime(l.year, l.month, l.day);
  return unit == RetentionUnit.day ? day : DateTime(day.year, day.month, day.day - (day.weekday - 1));
}

DateTime _addPeriods(DateTime start, RetentionUnit unit, int n) =>
    DateTime(start.year, start.month, start.day + n * (unit == RetentionUnit.day ? 1 : 7));

/// Retention: each person joins the cohort of the period in which they first
/// did [startEvent] within [from, now); they count as returned in period k if
/// they did [returnEvent] in the k-th period after it. Periods that end after
/// [now] are left empty.
RetentionResult computeRetention(
  Iterable<ActivityEvent> events, {
  required String startEvent,
  required String returnEvent,
  required RetentionUnit unit,
  required int periods,
  required DateTime from,
  DateTime? now,
}) {
  final end = now ?? DateTime.now();
  final first = <String, DateTime>{};
  final returns = <String, List<DateTime>>{};
  for (final e in events) {
    if (e.distinctId.isEmpty || e.timestamp.isBefore(from) || e.timestamp.isAfter(end)) continue;
    if (e.event == startEvent) {
      final f = first[e.distinctId];
      if (f == null || e.timestamp.isBefore(f)) first[e.distinctId] = e.timestamp;
    }
    if (e.event == returnEvent) returns.putIfAbsent(e.distinctId, () => []).add(e.timestamp);
  }

  final cohorts = <DateTime, List<String>>{};
  for (final entry in first.entries) {
    cohorts.putIfAbsent(periodStart(entry.value, unit), () => []).add(entry.key);
  }

  final out = <RetentionCohort>[];
  for (final start in cohorts.keys.toList()..sort()) {
    final people = cohorts[start]!;
    final returned = <int?>[];
    for (var p = 1; p <= periods; p++) {
      final pStart = _addPeriods(start, unit, p);
      final pEnd = _addPeriods(start, unit, p + 1);
      if (pEnd.isAfter(end)) {
        returned.add(null);
        continue;
      }
      var n = 0;
      for (final id in people) {
        final times = returns[id];
        if (times != null && times.any((t) => !t.toLocal().isBefore(pStart) && t.toLocal().isBefore(pEnd))) n++;
      }
      returned.add(n);
    }
    out.add(RetentionCohort(start: start, size: people.length, returned: returned));
  }
  return RetentionResult(unit: unit, periods: periods, cohorts: out);
}
