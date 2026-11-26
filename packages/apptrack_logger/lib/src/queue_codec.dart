import 'dart:convert';

/// JSON for queued logs and events: DateTimes are kept as DateTimes, any
/// other value JSON can't hold is stored as its text (as it would be sent).
String encodeQueueLine(Map<String, Object?> line) => jsonEncode(_enc(line));

Map<String, Object?> decodeQueueLine(String line) => _dec(jsonDecode(line)) as Map<String, Object?>;

const _dateKey = r'$dt';

Object? _enc(Object? v) {
  if (v == null || v is bool || v is String) return v;
  if (v is num) return v.isFinite ? v : '$v';
  if (v is DateTime) return {_dateKey: v.toUtc().toIso8601String()};
  if (v is Map) return v.map((k, e) => MapEntry('$k', _enc(e)));
  if (v is Iterable) return v.map(_enc).toList();
  return '$v';
}

Object? _dec(Object? v) {
  if (v is Map) {
    if (v.length == 1 && v[_dateKey] is String) return DateTime.parse(v[_dateKey] as String);
    return v.map((k, e) => MapEntry('$k', _dec(e)));
  }
  if (v is List) return v.map(_dec).toList();
  return v;
}
