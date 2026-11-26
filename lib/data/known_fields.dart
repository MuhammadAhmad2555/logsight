import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Remembers the attribute names (and a few example values) seen in a
/// project's logs or events, so the filter picker offers every custom
/// attribute — not only those in the logs loaded right now. Stored on the
/// device (SharedPreferences: localStorage on web), per project and kind.
class KnownFields {
  KnownFields(this._prefs, this._id);

  final SharedPreferences _prefs;
  final String _id;

  static const _maxKeys = 400;
  static const _maxValuesPerKey = 40;

  final Set<String> keys = {};
  final Map<String, Set<String>> values = {};
  bool _loaded = false;
  bool _dirty = false;

  String get _prefKey => 'known_fields_$_id';

  /// Forgets the fields remembered for a project's logs and events.
  static Future<void> forgetProject(SharedPreferences prefs, String projectId) async {
    for (final kind in ['logs', 'activity']) {
      await prefs.remove('known_fields_${kind}_$projectId');
    }
  }

  void _load() {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = _prefs.getString(_prefKey);
      if (raw == null) return;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      for (final e in m.entries) {
        keys.add(e.key);
        values[e.key] = ((e.value as List?) ?? const []).map((v) => '$v').toSet();
      }
    } catch (_) {}
  }

  /// Records [key] and, if given, one of its values.
  void add(String key, [String? value]) {
    _load();
    if (key.isEmpty) return;
    if (!keys.contains(key)) {
      if (keys.length >= _maxKeys) return;
      keys.add(key);
      _dirty = true;
    }
    if (value == null || value.isEmpty || value.length > 200) return;
    final set = values.putIfAbsent(key, () => <String>{});
    if (set.length < _maxValuesPerKey && set.add(value)) _dirty = true;
  }

  /// Records a nested map as dot paths (device.model), up to 3 levels deep.
  void addMap(Map<String, dynamic> m, [String prefix = '']) {
    for (final e in m.entries) {
      final k = prefix.isEmpty ? e.key : '$prefix.${e.key}';
      final v = e.value;
      if (v is Map && v.isNotEmpty && prefix.split('.').length < 3) {
        addMap(v.cast<String, dynamic>(), k);
      } else if (v is Iterable) {
        add(k);
        for (final item in v) {
          if (item != null && item is! Map && item is! Iterable) add(k, '$item'.trim());
        }
      } else {
        add(k, v == null || v is Map ? null : '$v'.trim());
      }
    }
  }

  /// Writes pending changes to storage.
  void save() {
    if (!_dirty) return;
    _dirty = false;
    _prefs.setString(_prefKey, jsonEncode({for (final k in keys) k: (values[k] ?? const <String>{}).toList()}));
  }

  List<String> sortedKeys() {
    _load();
    return keys.toList()..sort();
  }

  Map<String, List<String>> sortedValues() {
    _load();
    return {for (final e in values.entries) e.key: e.value.toList()..sort()};
  }
}
