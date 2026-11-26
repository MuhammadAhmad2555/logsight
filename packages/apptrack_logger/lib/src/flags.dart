import 'dart:convert';

/// A feature flag as stored by the AppTrack dashboard
/// (`projects/{projectId}/flags/{key}`).
///
/// Evaluation must match the dashboard (lib/data/flags.dart): enabled, every
/// condition matches, and the person's rollout bucket is below [rollout].
class FeatureFlag {
  const FeatureFlag({
    required this.key,
    this.enabled = false,
    this.rollout = 100,
    this.conditions = const [],
  });

  final String key;
  final bool enabled;

  /// 0–100: share of matching people who get the flag.
  final int rollout;
  final List<FlagCondition> conditions;

  bool isEnabledFor(String distinctId, [Map<String, Object?> properties = const {}]) {
    if (!enabled) return false;
    for (final c in conditions) {
      if (!c.matches(properties)) return false;
    }
    if (rollout >= 100) return true;
    if (rollout <= 0) return false;
    return rolloutBucket(key, distinctId) < rollout;
  }

  /// Parses a Firestore REST document; null if it isn't a valid flag.
  static FeatureFlag? fromFirestore(Map<String, dynamic> doc) {
    final name = doc['name'];
    if (name is! String) return null;
    final key = name.split('/').last;
    final fields = (doc['fields'] as Map?)?.cast<String, dynamic>() ?? const {};
    final d = {for (final e in fields.entries) e.key: fromFirestoreValue(e.value)};
    final rollout = d['rollout'];
    return FeatureFlag(
      key: key,
      enabled: d['enabled'] == true,
      rollout: rollout is num ? rollout.toInt().clamp(0, 100) : 100,
      conditions: [
        for (final c in (d['conditions'] as List?) ?? const [])
          if (FlagCondition.fromMap(c) case final cond?) cond,
      ],
    );
  }
}

/// One targeting condition, e.g. `plan equals pro`.
class FlagCondition {
  const FlagCondition(this.property, this.op, [this.value = '']);

  final String property;

  /// equals, notEquals, contains, notContains, greaterThan, lessThan,
  /// exists, notExists.
  final String op;
  final String value;

  static FlagCondition? fromMap(Object? m) {
    if (m is! Map) return null;
    final p = m['property'], op = m['op'];
    if (p is! String || p.isEmpty || op is! String) return null;
    return FlagCondition(p, op, '${m['value'] ?? ''}');
  }

  bool matches(Map<String, Object?> props) => _test(_lookup(props, property));

  static Object? _lookup(Map<String, Object?> props, String key) {
    if (props.containsKey(key)) return props[key];
    Object? cur = props;
    for (final part in key.split('.')) {
      if (cur is Map && cur.containsKey(part)) {
        cur = cur[part];
      } else {
        return null;
      }
    }
    return cur;
  }

  bool _test(Object? raw) {
    switch (op) {
      case 'exists':
        return raw != null;
      case 'notExists':
        return raw == null;
      case 'notEquals':
        return !FlagCondition(property, 'equals', value)._test(raw);
      case 'notContains':
        return !FlagCondition(property, 'contains', value)._test(raw);
      case 'equals':
      case 'contains':
      case 'greaterThan':
      case 'lessThan':
        if (raw == null) return false;
        if (raw is Iterable) return raw.any(_test);
        return _testOne(raw);
      default:
        return false;
    }
  }

  bool _testOne(Object raw) {
    final str = raw.toString();
    switch (op) {
      case 'equals':
        if (str == value) return true;
        final a = num.tryParse(str), b = num.tryParse(value);
        if (a != null && b != null) return a == b;
        return raw is bool && str == value.trim().toLowerCase();
      case 'contains':
        return str.toLowerCase().contains(value.toLowerCase());
      default: // greaterThan, lessThan
        final a = num.tryParse(str), b = num.tryParse(value.trim());
        final cmp = (a != null && b != null) ? a.compareTo(b) : str.compareTo(value);
        return op == 'greaterThan' ? cmp > 0 : cmp < 0;
    }
  }
}

/// 0–99 bucket for a person and flag. Must match the dashboard.
int rolloutBucket(String flagKey, String distinctId) => fnv1a32('$flagKey.$distinctId') % 100;

/// 32-bit FNV-1a hash of [s]'s UTF-8 bytes (exact on every platform,
/// including JavaScript).
int fnv1a32(String s) {
  var h = 0x811c9dc5;
  for (final b in utf8.encode(s)) {
    h = (h ^ b) & 0xffffffff;
    h = (h + (h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24)) & 0xffffffff;
  }
  return h;
}

/// Decodes a Firestore REST `Value` into a Dart value.
Object? fromFirestoreValue(Object? v) {
  if (v is! Map) return null;
  if (v.containsKey('stringValue')) return v['stringValue'];
  if (v.containsKey('booleanValue')) return v['booleanValue'];
  if (v.containsKey('integerValue')) return int.tryParse('${v['integerValue']}');
  if (v.containsKey('doubleValue')) return (v['doubleValue'] as num?)?.toDouble();
  if (v.containsKey('timestampValue')) return DateTime.tryParse('${v['timestampValue']}');
  if (v.containsKey('nullValue')) return null;
  if (v.containsKey('arrayValue')) {
    return [for (final e in ((v['arrayValue'] as Map?)?['values'] as List?) ?? const []) fromFirestoreValue(e)];
  }
  if (v.containsKey('mapValue')) {
    final f = ((v['mapValue'] as Map?)?['fields'] as Map?) ?? const {};
    return {for (final e in f.entries) '${e.key}': fromFirestoreValue(e.value)};
  }
  return null;
}
