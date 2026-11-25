import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../models.dart';

/// One readable line per log (same layout as the logging SDK's text files):
/// `2026-11-25T17:39:43.374Z ERROR keyo_ios user=abc: Payment failed {"order_id":42}`
String formatLogLine(LogEntry log) {
  final b = StringBuffer()
    ..write(log.timestamp.toUtc().toIso8601String())
    ..write(' ')
    ..write(log.severity.id.toUpperCase().padRight(5))
    ..write(' ')
    ..write(log.service);
  if (log.userId != null) b.write(' user=${log.userId}');
  if (log.sessionId != null) b.write(' session=${log.sessionId}');
  if (log.traceId != null) b.write(' trace=${log.traceId}');
  b
    ..write(': ')
    ..write(log.message.replaceAll('\r\n', '\n').replaceAll('\n', r'\n'));
  if (log.attributes.isNotEmpty) {
    b
      ..write(' ')
      ..write(jsonEncode(log.attributes, toEncodable: _encodable));
  }
  return b.toString();
}

Object? _encodable(Object? o) {
  if (o is Timestamp) return o.toDate().toUtc().toIso8601String();
  if (o is DateTime) return o.toUtc().toIso8601String();
  if (o is GeoPoint) return {'lat': o.latitude, 'lng': o.longitude};
  if (o is DocumentReference) return o.path;
  return '$o';
}

/// Safe file name for a project or service (e.g. `keyo_ios`).
String safeFileName(String s) {
  final cleaned = s.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
  return cleaned.isEmpty ? 'unnamed' : cleaned;
}

/// CSV (RFC 4180) with one row per log, oldest first.
String formatLogsCsv(List<LogEntry> logs) {
  String cell(Object? v) {
    final s = v?.toString() ?? '';
    return RegExp(r'[",\r\n]').hasMatch(s) ? '"${s.replaceAll('"', '""')}"' : s;
  }

  final b = StringBuffer('timestamp,severity,service,message,userId,sessionId,traceId,attributes\r\n');
  for (final l in logs) {
    b
      ..write(
        [
          l.timestamp.toUtc().toIso8601String(),
          l.severity.id,
          l.service,
          l.message,
          l.userId,
          l.sessionId,
          l.traceId,
          l.attributes.isEmpty ? '' : jsonEncode(l.attributes, toEncodable: _encodable),
        ].map(cell).join(','),
      )
      ..write('\r\n');
  }
  return b.toString();
}
