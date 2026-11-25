import 'dart:convert';

import '../core/severity.dart';
import 'models.dart';

/// Logs sharing one message template.
class PatternGroup {
  PatternGroup(this.pattern);

  final String pattern;
  int count = 0;
  final Map<Severity, int> bySeverity = {};
  final Set<String> services = {};
  DateTime? firstSeen;
  DateTime? lastSeen;
  LogEntry? sample;

  /// The most severe level seen in this pattern.
  Severity get topSeverity => bySeverity.keys.fold(Severity.trace, (a, b) => b.index > a.index ? b : a);

  void add(LogEntry l) {
    count++;
    bySeverity[l.severity] = (bySeverity[l.severity] ?? 0) + 1;
    services.add(l.service);
    if (firstSeen == null || l.timestamp.isBefore(firstSeen!)) firstSeen = l.timestamp;
    if (lastSeen == null || l.timestamp.isAfter(lastSeen!)) {
      lastSeen = l.timestamp;
      sample = l;
    }
  }
}

/// Groups logs by pattern, most frequent first.
List<PatternGroup> groupPatterns(Iterable<LogEntry> logs) {
  final groups = <String, PatternGroup>{};
  for (final l in logs) {
    groups.putIfAbsent(l.pattern, () => PatternGroup(l.pattern)).add(l);
  }
  return groups.values.toList()..sort((a, b) => b.count.compareTo(a.count));
}

/// Errors (error + fatal) grouped by fingerprint, like PostHog's error tracking.
class IssueGroup {
  IssueGroup(this.fingerprint, this.service, this.pattern);

  final String fingerprint;
  final String service;
  final String pattern;
  int count = 0;
  final Set<String> users = {};
  DateTime? firstSeen;
  DateTime? lastSeen;
  LogEntry? latest;
  IssueState? state;

  IssueStatus get status => state?.status ?? IssueStatus.open;

  /// Resolved, but errors came back after it was resolved.
  bool get regressed =>
      state?.status == IssueStatus.resolved &&
      state?.resolvedAt != null &&
      lastSeen != null &&
      lastSeen!.isAfter(state!.resolvedAt!);

  String get title {
    final type = latest?.attributes['exception.type']?.toString();
    return type == null || type.isEmpty ? pattern : '$type: $pattern';
  }

  void add(LogEntry l) {
    count++;
    if (l.userId != null) users.add(l.userId!);
    if (firstSeen == null || l.timestamp.isBefore(firstSeen!)) firstSeen = l.timestamp;
    if (lastSeen == null || l.timestamp.isAfter(lastSeen!)) {
      lastSeen = l.timestamp;
      latest = l;
    }
  }
}

List<IssueGroup> groupIssues(Iterable<LogEntry> logs, Map<String, IssueState> states) {
  final groups = <String, IssueGroup>{};
  for (final l in logs) {
    if (l.severity.index < Severity.error.index) continue;
    groups.putIfAbsent(l.fingerprint, () => IssueGroup(l.fingerprint, l.service, l.pattern)).add(l);
  }
  for (final g in groups.values) {
    g.state = states[g.fingerprint];
  }
  return groups.values.toList()..sort((a, b) {
    // Regressions first, then open, then by most recent.
    int rank(IssueGroup g) => g.regressed ? 0 : (g.status == IssueStatus.open ? 1 : 2);
    final r = rank(a).compareTo(rank(b));
    return r != 0 ? r : b.lastSeen!.compareTo(a.lastSeen!);
  });
}

/// Logs sharing one value of a field or attribute (for "Group by").
class ValueGroup {
  ValueGroup(this.value);

  /// The value as text, or null when the log doesn't have the field.
  final String? value;
  int count = 0;
  int errors = 0;
  final Set<String> users = {};
  DateTime? lastSeen;

  void add(LogEntry l) {
    count++;
    if (l.severity.index >= Severity.error.index) errors++;
    if (l.userId != null) users.add(l.userId!);
    if (lastSeen == null || l.timestamp.isAfter(lastSeen!)) lastSeen = l.timestamp;
  }
}

/// Text form of a field value for grouping (maps and lists as JSON).
String? groupValueOf(LogEntry l, String key) {
  final v = l.field(key);
  if (v == null) return null;
  if (v is Map || v is List) return jsonEncode(v, toEncodable: (o) => o.toString());
  return v.toString();
}

/// Groups logs by the value of [key] (built-in field or attribute, dot paths
/// allowed), largest group first; "not set" goes last.
List<ValueGroup> groupByField(Iterable<LogEntry> logs, String key) {
  final groups = <String?, ValueGroup>{};
  for (final l in logs) {
    final v = groupValueOf(l, key);
    groups.putIfAbsent(v, () => ValueGroup(v)).add(l);
  }
  return groups.values.toList()..sort((a, b) {
    if (a.value == null) return 1;
    if (b.value == null) return -1;
    return b.count.compareTo(a.count);
  });
}
