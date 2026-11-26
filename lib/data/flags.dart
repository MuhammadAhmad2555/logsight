import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'log_query.dart';

/// One targeting condition on a person/app property, e.g. `plan = pro`.
@immutable
class FlagCondition {
  const FlagCondition(this.property, this.op, [this.value = '']);

  final String property;
  final FilterOp op;
  final String value;

  /// Operators offered for conditions (the same ones the SDK evaluates).
  static const ops = [
    FilterOp.equals,
    FilterOp.notEquals,
    FilterOp.contains,
    FilterOp.greaterThan,
    FilterOp.lessThan,
    FilterOp.exists,
    FilterOp.notExists,
  ];

  bool matches(Map<String, Object?> props) => AttrFilter(property, op, value).test(_lookup(props, property));

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

  String get label => AttrFilter(property, op, value).label;

  Map<String, Object> toMap() => {'property': property, 'op': op.name, 'value': value};

  static FlagCondition? fromMap(Object? m) {
    if (m is! Map) return null;
    final op = FilterOp.values.where((o) => o.name == m['op']).firstOrNull;
    final prop = m['property'];
    if (op == null || prop is! String || prop.isEmpty) return null;
    return FlagCondition(prop, op, '${m['value'] ?? ''}');
  }

  @override
  bool operator ==(Object other) =>
      other is FlagCondition && other.property == property && other.op == op && other.value == value;

  @override
  int get hashCode => Object.hash(property, op, value);
}

/// A feature flag. The document ID is the flag key apps ask for.
///
/// A flag is on for a person when it is [enabled], every condition matches
/// the person's properties, and the person falls inside the [rollout]
/// percentage. The rollout bucket comes from a hash of `key.distinctId`, so a
/// person stays in or out as the percentage changes (raising 20% → 50% keeps
/// the first 20% in). The SDK uses the same hash ([rolloutBucket]).
@immutable
class FeatureFlag {
  const FeatureFlag({
    required this.key,
    this.name = '',
    this.description = '',
    this.enabled = false,
    this.rollout = 100,
    this.conditions = const [],
    this.updatedAt,
    this.updatedBy,
  });

  final String key;
  final String name;
  final String description;
  final bool enabled;

  /// 0–100: share of matching people who get the flag.
  final int rollout;
  final List<FlagCondition> conditions;
  final DateTime? updatedAt;
  final String? updatedBy;

  String get title => name.trim().isEmpty ? key : name;

  static final keyPattern = RegExp(r'^[a-z0-9][a-z0-9_\-]{0,63}$');

  bool isEnabledFor(String distinctId, [Map<String, Object?> properties = const {}]) {
    if (!enabled) return false;
    for (final c in conditions) {
      if (!c.matches(properties)) return false;
    }
    if (rollout >= 100) return true;
    if (rollout <= 0) return false;
    return rolloutBucket(key, distinctId) < rollout;
  }

  FeatureFlag copyWith({bool? enabled}) => FeatureFlag(
    key: key,
    name: name,
    description: description,
    enabled: enabled ?? this.enabled,
    rollout: rollout,
    conditions: conditions,
    updatedAt: updatedAt,
    updatedBy: updatedBy,
  );

  Map<String, Object?> toMap() => {
    'name': name.trim(),
    'description': description.trim(),
    'enabled': enabled,
    'rollout': rollout.clamp(0, 100),
    'conditions': [for (final c in conditions) c.toMap()],
  };

  factory FeatureFlag.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return FeatureFlag(
      key: doc.id,
      name: d['name'] as String? ?? '',
      description: d['description'] as String? ?? '',
      enabled: d['enabled'] as bool? ?? false,
      rollout: (d['rollout'] as num?)?.toInt().clamp(0, 100) ?? 100,
      conditions: ((d['conditions'] as List?) ?? const []).map(FlagCondition.fromMap).whereType<FlagCondition>().toList(),
      updatedAt: (d['updatedAt'] as Timestamp?)?.toDate(),
      updatedBy: d['updatedBy'] as String?,
    );
  }
}

/// 0–99 bucket for a person and flag: FNV-1a (32-bit) of `key.distinctId`.
/// Must match the SDK's `rolloutBucket` (packages/apptrack_logger).
int rolloutBucket(String flagKey, String distinctId) => fnv1a32('$flagKey.$distinctId') % 100;

/// 32-bit FNV-1a hash of [s]'s UTF-8 bytes.
int fnv1a32(String s) {
  var h = 0x811c9dc5;
  for (final b in utf8.encode(s)) {
    h = (h ^ b) & 0xffffffff;
    // h * 16777619 (the FNV prime) written as shifts, so it stays exact when
    // compiled to JavaScript, where plain multiplication loses bits.
    h = (h + (h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24)) & 0xffffffff;
  }
  return h;
}

class FlagsRepository {
  FlagsRepository(this._db);

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> _flags(String pid) =>
      _db.collection('projects').doc(pid).collection('flags');

  Stream<List<FeatureFlag>> watch(String pid) => _flags(pid).snapshots().map(
    (s) => s.docs.map(FeatureFlag.fromDoc).toList()..sort((a, b) => a.key.compareTo(b.key)),
  );

  Future<bool> exists(String pid, String key) async => (await _flags(pid).doc(key).get()).exists;

  Future<void> save(String pid, FeatureFlag f, {required String uid}) => _flags(pid).doc(f.key).set({
    ...f.toMap(),
    'updatedBy': uid,
    'updatedAt': FieldValue.serverTimestamp(),
  });

  Future<void> delete(String pid, String key) => _flags(pid).doc(key).delete();
}
