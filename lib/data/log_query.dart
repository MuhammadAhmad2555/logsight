import 'package:flutter/foundation.dart';

import '../core/severity.dart';
import '../core/tokenizer.dart';
import 'models.dart';

/// A time window: either relative to now ("last 24 hours") or absolute.
@immutable
class TimeRange {
  const TimeRange.relative(this.preset) : from = null, to = null;

  const TimeRange.absolute(DateTime this.from, DateTime this.to) : preset = null;

  final RelativePreset? preset;
  final DateTime? from;
  final DateTime? to;

  bool get isRelative => preset != null;

  (DateTime, DateTime) resolve([DateTime? now]) {
    final n = now ?? DateTime.now();
    if (preset != null) return (n.subtract(preset!.duration), n);
    return (from!, to!);
  }

  String get label {
    if (preset != null) return preset!.label;
    return '${_fmt(from!)} → ${_fmt(to!)}';
  }

  static String _fmt(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    final l = d.toLocal();
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  @override
  bool operator ==(Object other) =>
      other is TimeRange && other.preset == preset && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(preset, from, to);
}

enum RelativePreset {
  m15('15m', 'Last 15 minutes', Duration(minutes: 15)),
  h1('1h', 'Last hour', Duration(hours: 1)),
  h6('6h', 'Last 6 hours', Duration(hours: 6)),
  h24('24h', 'Last 24 hours', Duration(hours: 24)),
  d7('7d', 'Last 7 days', Duration(days: 7)),
  d30('30d', 'Last 30 days', Duration(days: 30)),
  d90('90d', 'Last 90 days', Duration(days: 90));

  const RelativePreset(this.id, this.label, this.duration);
  final String id;
  final String label;
  final Duration duration;

  static RelativePreset? tryParse(String? id) {
    for (final p in values) {
      if (p.id == id) return p;
    }
    return null;
  }
}

enum FilterOp {
  equals('=', 'equals'),
  notEquals('≠', 'does not equal'),
  contains('~', 'contains'),
  notContains('!~', 'does not contain'),
  exists('∃', 'is set'),
  notExists('∄', 'is not set');

  const FilterOp(this.symbol, this.label);
  final String symbol;
  final String label;

  bool get needsValue => this != exists && this != notExists;
}

/// A filter on a built-in field or on an attribute, e.g. `app.version = 2.1.0`.
@immutable
class AttrFilter {
  const AttrFilter(this.key, this.op, [this.value = '']);

  final String key;
  final FilterOp op;
  final String value;

  bool matches(LogEntry log) {
    final raw = log.field(key);
    final str = raw?.toString();
    switch (op) {
      case FilterOp.exists:
        return raw != null;
      case FilterOp.notExists:
        return raw == null;
      case FilterOp.equals:
        return str == value;
      case FilterOp.notEquals:
        return str != value;
      case FilterOp.contains:
        return str != null && str.toLowerCase().contains(value.toLowerCase());
      case FilterOp.notContains:
        return str == null || !str.toLowerCase().contains(value.toLowerCase());
    }
  }

  String get label {
    final k = key == 'service' ? 'service.name' : key;
    return op.needsValue ? '$k ${op.symbol} $value' : '$k ${op.label}';
  }

  String encode() => '$key~${op.name}~$value';

  static AttrFilter? decode(String s) {
    final parts = s.split('~');
    if (parts.length < 2 || parts[0].isEmpty) return null;
    final op = FilterOp.values.where((o) => o.name == parts[1]).firstOrNull;
    if (op == null) return null;
    return AttrFilter(parts[0], op, parts.skip(2).join('~'));
  }

  @override
  bool operator ==(Object other) => other is AttrFilter && other.key == key && other.op == op && other.value == value;

  @override
  int get hashCode => Object.hash(key, op, value);
}

/// Everything the Logs page filters on. Kept in the URL so views can be shared.
@immutable
class LogQuery {
  const LogQuery({
    this.range = const TimeRange.relative(RelativePreset.h24),
    this.services = const [],
    this.excludedServices = const [],
    this.severities = const {},
    this.search = '',
    this.filters = const [],
  });

  final TimeRange range;
  final List<String> services;
  final List<String> excludedServices;
  final Set<Severity> severities;
  final String search;
  final List<AttrFilter> filters;

  List<String> get searchTokens => tokenize(search);

  bool get hasFilters =>
      services.isNotEmpty ||
      excludedServices.isNotEmpty ||
      severities.isNotEmpty ||
      search.trim().isNotEmpty ||
      filters.isNotEmpty;

  /// Checks every filter in the app. Filters Firestore can't run are applied
  /// here; re-checking the ones Firestore already ran costs almost nothing.
  bool matches(LogEntry log) {
    if (services.isNotEmpty && !services.contains(log.service)) return false;
    if (excludedServices.contains(log.service)) return false;
    if (severities.isNotEmpty && !severities.contains(log.severity)) return false;
    for (final t in searchTokens) {
      if (!log.tokens.contains(t)) return false;
    }
    for (final f in filters) {
      if (!f.matches(log)) return false;
    }
    return true;
  }

  LogQuery copyWith({
    TimeRange? range,
    List<String>? services,
    List<String>? excludedServices,
    Set<Severity>? severities,
    String? search,
    List<AttrFilter>? filters,
  }) => LogQuery(
    range: range ?? this.range,
    services: services ?? this.services,
    excludedServices: excludedServices ?? this.excludedServices,
    severities: severities ?? this.severities,
    search: search ?? this.search,
    filters: filters ?? this.filters,
  );

  LogQuery cleared() => LogQuery(range: range);

  Map<String, dynamic> toQueryParameters() {
    final p = <String, dynamic>{};
    if (range.isRelative) {
      p['range'] = range.preset!.id;
    } else {
      p['from'] = range.from!.toUtc().toIso8601String();
      p['to'] = range.to!.toUtc().toIso8601String();
    }
    if (services.isNotEmpty) p['service'] = services;
    if (excludedServices.isNotEmpty) p['xservice'] = excludedServices;
    if (severities.isNotEmpty) {
      p['sev'] = Severity.values.where(severities.contains).map((s) => s.id).join(',');
    }
    if (search.trim().isNotEmpty) p['q'] = search.trim();
    if (filters.isNotEmpty) p['f'] = filters.map((f) => f.encode()).toList();
    return p;
  }

  static LogQuery fromUri(Uri uri) {
    final qp = uri.queryParameters;
    final all = uri.queryParametersAll;
    TimeRange range = const TimeRange.relative(RelativePreset.h24);
    final preset = RelativePreset.tryParse(qp['range']);
    final from = DateTime.tryParse(qp['from'] ?? '');
    final to = DateTime.tryParse(qp['to'] ?? '');
    if (preset != null) {
      range = TimeRange.relative(preset);
    } else if (from != null && to != null && from.isBefore(to)) {
      range = TimeRange.absolute(from, to);
    }
    return LogQuery(
      range: range,
      services: (all['service'] ?? const []).where((s) => s.isNotEmpty).toList(),
      excludedServices: (all['xservice'] ?? const []).where((s) => s.isNotEmpty).toList(),
      severities: (qp['sev'] ?? '').split(',').map(Severity.tryParse).whereType<Severity>().toSet(),
      search: qp['q'] ?? '',
      filters: (all['f'] ?? const []).map(AttrFilter.decode).whereType<AttrFilter>().toList(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LogQuery &&
      other.range == range &&
      listEquals(other.services, services) &&
      listEquals(other.excludedServices, excludedServices) &&
      setEquals(other.severities, severities) &&
      other.search == search &&
      listEquals(other.filters, filters);

  @override
  int get hashCode => Object.hash(
    range,
    Object.hashAll(services),
    Object.hashAll(excludedServices),
    Object.hashAllUnordered(severities),
    search,
    Object.hashAll(filters),
  );
}

/// Picks a bar width for the volume chart so the range splits into ≤ [maxBuckets] bars.
Duration bucketSizeFor(Duration span, {int maxBuckets = 40}) {
  const steps = [
    Duration(minutes: 1),
    Duration(minutes: 5),
    Duration(minutes: 15),
    Duration(minutes: 30),
    Duration(hours: 1),
    Duration(hours: 3),
    Duration(hours: 6),
    Duration(hours: 12),
    Duration(days: 1),
    Duration(days: 3),
    Duration(days: 7),
    Duration(days: 14),
    Duration(days: 30),
  ];
  for (final s in steps) {
    if (span.inSeconds / s.inSeconds <= maxBuckets) return s;
  }
  return Duration(seconds: (span.inSeconds / maxBuckets).ceil());
}

/// Splits [from, to) into buckets aligned to the bucket size (in UTC).
List<(DateTime, DateTime)> buildBuckets(DateTime from, DateTime to, {int maxBuckets = 40}) {
  final size = bucketSizeFor(to.difference(from), maxBuckets: maxBuckets);
  final sizeMs = size.inMilliseconds;
  final startMs = (from.millisecondsSinceEpoch ~/ sizeMs) * sizeMs;
  final out = <(DateTime, DateTime)>[];
  for (var t = startMs; t < to.millisecondsSinceEpoch; t += sizeMs) {
    final s = DateTime.fromMillisecondsSinceEpoch(t);
    final e = DateTime.fromMillisecondsSinceEpoch(t + sizeMs);
    out.add((s.isBefore(from) ? from : s, e.isAfter(to) ? to : e));
  }
  return out;
}
