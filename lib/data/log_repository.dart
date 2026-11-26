import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/severity.dart';
import 'log_query.dart';
import 'models.dart';

/// One page of results from [LogRepository.fetchPage].
class LogPage {
  const LogPage({required this.logs, required this.cursor, required this.hasMore, required this.scanned});

  /// Logs that passed every filter.
  final List<LogEntry> logs;

  /// The last document read, used to continue to the next page.
  final DocumentSnapshot<Map<String, dynamic>>? cursor;
  final bool hasMore;

  /// How many documents were read to fill this page.
  final int scanned;
}

class VolumeBucket {
  const VolumeBucket(this.start, this.end, this.count);
  final DateTime start;
  final DateTime end;
  final int count;
}

/// Ranges with at most this many documents are counted in the app from one
/// read instead of one count query per bar (30–40 round trips).
const smallRangeLimit = 300;

/// Counts documents per bar for a volume chart. [query] builds the Firestore
/// query for a time window (documents need a `ts` timestamp field).
///
/// Small ranges, the common case, take two requests: a total count, then one
/// read of the documents, counted per bar here. Larger ranges fall back to a
/// count query per bar, which costs far fewer reads.
Future<List<VolumeBucket>> countVolume(
  Query<Map<String, dynamic>> Function(DateTime from, DateTime to) query, {
  required DateTime from,
  required DateTime to,
  int maxBuckets = 40,
}) async {
  final buckets = buildBuckets(from, to, maxBuckets: maxBuckets);
  final whole = query(from, to);
  final total = (await whole.count().get()).count ?? 0;
  if (total <= smallRangeLimit) {
    final counts = List.filled(buckets.length, 0);
    if (total > 0) {
      final snap = await whole.limit(smallRangeLimit).get();
      for (final d in snap.docs) {
        final ts = (d.data()['ts'] as Timestamp?)?.toDate();
        if (ts == null) continue;
        final i = bucketIndex(buckets, ts);
        if (i >= 0) counts[i]++;
      }
    }
    return [for (var i = 0; i < buckets.length; i++) VolumeBucket(buckets[i].$1, buckets[i].$2, counts[i])];
  }
  final counts = await Future.wait(
    buckets.map((b) async => (await query(b.$1, b.$2).count().get()).count ?? 0),
  );
  return [for (var i = 0; i < buckets.length; i++) VolumeBucket(buckets[i].$1, buckets[i].$2, counts[i])];
}

/// Which bucket [t] falls in (start inclusive, end exclusive), or -1.
int bucketIndex(List<(DateTime, DateTime)> buckets, DateTime t) {
  var lo = 0, hi = buckets.length - 1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    final (s, e) = buckets[mid];
    if (t.isBefore(s)) {
      hi = mid - 1;
    } else if (!t.isBefore(e)) {
      lo = mid + 1;
    } else {
      return mid;
    }
  }
  return -1;
}

/// Runs log queries against Firestore.
///
/// Firestore can only filter on equality, `in`, `array-contains` and one
/// range, and every combination needs an index. So the repository sends
/// Firestore the filters it can run (time range, service, severity, one
/// search word) and [LogQuery.matches] applies the rest in the app.
class LogRepository {
  LogRepository(this._db);

  final FirebaseFirestore _db;

  static const pageSize = 100;

  CollectionReference<Map<String, dynamic>> _logs(String pid) => _db.collection('projects').doc(pid).collection('logs');

  /// The Firestore part of [q]. [from]/[to] override the query's time range.
  Query<Map<String, dynamic>> serverQuery(
    String pid,
    LogQuery q, {
    required DateTime from,
    DateTime? to,
    bool includeSeverity = true,
  }) {
    var query = _logs(pid).where('ts', isGreaterThanOrEqualTo: Timestamp.fromDate(from));
    if (to != null) query = query.where('ts', isLessThan: Timestamp.fromDate(to));

    var usedIn = false;
    if (q.services.length == 1) {
      query = query.where('service', isEqualTo: q.services.first);
    } else if (q.services.length > 1 && q.services.length <= 30) {
      query = query.where('service', whereIn: q.services);
      usedIn = true;
    }

    if (includeSeverity && q.severities.isNotEmpty && q.severities.length < Severity.values.length) {
      if (q.severities.length == 1) {
        query = query.where('severity', isEqualTo: q.severities.first.id);
      } else if (!usedIn) {
        query = query.where('severity', whereIn: q.severities.map((s) => s.id).toList());
      }
    }

    final tokens = q.searchTokens;
    if (tokens.isNotEmpty) {
      // The longest word usually matches the fewest logs.
      final best = tokens.reduce((a, b) => b.length > a.length ? b : a);
      query = query.where('tokens', arrayContains: best);
    }
    return query.orderBy('ts', descending: true);
  }

  /// Fetches up to [want] matching logs, reading more pages from Firestore
  /// while filters that only run in the app drop results. Stops after
  /// [maxScan] documents so one view can't read without limit.
  Future<LogPage> fetchPage(
    String pid,
    LogQuery q, {
    DocumentSnapshot<Map<String, dynamic>>? after,
    int want = 50,
    int maxScan = 1000,
  }) async {
    final (from, to) = q.range.resolve();
    final base = serverQuery(pid, q, from: from, to: to);
    final out = <LogEntry>[];
    var cursor = after;
    var scanned = 0;
    var hasMore = true;
    while (out.length < want && scanned < maxScan) {
      var page = base.limit(pageSize);
      if (cursor != null) page = page.startAfterDocument(cursor);
      final snap = await page.get();
      scanned += snap.docs.length;
      for (final d in snap.docs) {
        final log = LogEntry.fromDoc(d);
        if (q.matches(log)) out.add(log);
      }
      if (snap.docs.isNotEmpty) cursor = snap.docs.last;
      if (snap.docs.length < pageSize) {
        hasMore = false;
        break;
      }
    }
    return LogPage(logs: out, cursor: cursor, hasMore: hasMore, scanned: scanned);
  }

  /// Live tail: the newest matching logs, updating as they arrive.
  /// Live updates: the newest matching logs from [since] (default: the start
  /// of the query's time range), re-emitted whenever new logs arrive.
  Stream<List<LogEntry>> watchLatest(String pid, LogQuery q, {DateTime? since, int limit = 200}) {
    final (from, _) = q.range.resolve();
    return serverQuery(
      pid,
      q,
      from: since ?? from,
    ).limit(limit).snapshots().map((s) => s.docs.map(LogEntry.fromDoc).where(q.matches).toList());
  }

  /// Log counts over time for the volume chart (see [countVolume]).
  Future<List<VolumeBucket>> volume(String pid, LogQuery q, {int maxBuckets = 40}) {
    final (from, to) = q.range.resolve();
    return countVolume((f, t) => serverQuery(pid, q, from: f, to: t), from: from, to: to, maxBuckets: maxBuckets);
  }

  /// How many logs match the Firestore part of [q] in its time range.
  Future<int> count(String pid, LogQuery q) async {
    final (from, to) = q.range.resolve();
    final agg = await serverQuery(pid, q, from: from, to: to).count().get();
    return agg.count ?? 0;
  }

  /// Totals per severity across the whole range, for the severity chips.
  Future<Map<Severity, int>> severityTotals(String pid, LogQuery q) async {
    final (from, to) = q.range.resolve();
    final withoutSeverity = q.copyWith(severities: {});
    // Small ranges: one read, counted here, instead of a query per level.
    final whole = serverQuery(pid, withoutSeverity, from: from, to: to);
    final total = (await whole.count().get()).count ?? 0;
    if (total <= smallRangeLimit) {
      final out = {for (final s in Severity.values) s: 0};
      if (total > 0) {
        final snap = await whole.limit(smallRangeLimit).get();
        for (final d in snap.docs) {
          final s = Severity.parse(d.data()['severity'] as String?);
          out[s] = out[s]! + 1;
        }
      }
      return out;
    }
    final results = await Future.wait(
      Severity.values.map((s) async {
        final query = serverQuery(
          pid,
          withoutSeverity.copyWith(severities: {s}),
          from: from,
          to: to,
        );
        final agg = await query.count().get();
        return MapEntry(s, agg.count ?? 0);
      }),
    );
    return Map.fromEntries(results);
  }
}
