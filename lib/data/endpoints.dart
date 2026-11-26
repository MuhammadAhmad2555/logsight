import 'package:flutter/foundation.dart';

import '../core/severity.dart';
import 'models.dart';

/// Token the SDK adds to request logs (`logger.request(...)`), so the
/// Endpoints page can ask Firestore for request logs only.
const requestToken = 'http_request';

/// Attribute names read from request logs. The SDK writes the first name in
/// each list; the others are common OpenTelemetry spellings, so logs from
/// other tools work too.
const _methodKeys = ['http.method', 'http.request.method', 'method'];
const _routeKeys = ['http.route', 'url.path', 'http.target', 'http.path', 'route', 'path'];
const _statusKeys = ['http.status_code', 'http.response.status_code', 'status_code', 'status'];
const _durationKeys = ['duration_ms', 'http.duration_ms', 'latency_ms', 'elapsed_ms'];

Object? _first(LogEntry log, List<String> keys) {
  for (final k in keys) {
    final v = log.field(k);
    if (v != null) return v;
  }
  return null;
}

num? _num(Object? v) => v is num ? v : num.tryParse('${v ?? ''}');

/// The attribute name a log uses for its route, for linking to Logs.
String? routeKeyOf(LogEntry log) {
  for (final k in _routeKeys) {
    if (log.field(k) != null) return k;
  }
  return null;
}

/// Stats for one method + route, e.g. `GET /api/orders/:id`.
@immutable
class EndpointStats {
  const EndpointStats({
    required this.method,
    required this.route,
    required this.routeKey,
    required this.calls,
    required this.serverErrors,
    required this.clientErrors,
    required this.p50,
    required this.p95,
    required this.avg,
    required this.lastSeen,
    required this.services,
  });

  final String method;
  final String route;

  /// Attribute the route came from (http.route, url.path, ...).
  final String routeKey;
  final int calls;

  /// 5xx responses, or error/fatal logs without a status code.
  final int serverErrors;

  /// 4xx responses.
  final int clientErrors;

  /// Latency percentiles in milliseconds (null when no durations were sent).
  final double? p50;
  final double? p95;
  final double? avg;
  final DateTime lastSeen;
  final Set<String> services;

  double get errorRate => calls == 0 ? 0 : serverErrors / calls;
}

/// Groups request logs by method and route. Logs without a route are skipped.
List<EndpointStats> endpointStats(Iterable<LogEntry> logs) {
  final groups = <String, List<LogEntry>>{};
  final keys = <String, (String, String, String)>{};
  for (final l in logs) {
    final route = _first(l, _routeKeys)?.toString().trim();
    if (route == null || route.isEmpty) continue;
    final method = (_first(l, _methodKeys)?.toString().trim().toUpperCase()).orIfEmpty('—');
    final id = '$method $route';
    groups.putIfAbsent(id, () => []).add(l);
    keys[id] = (method, route, routeKeyOf(l)!);
  }
  final out = <EndpointStats>[];
  for (final e in groups.entries) {
    final list = e.value;
    var server = 0, client = 0;
    final durations = <double>[];
    var last = list.first.timestamp;
    for (final l in list) {
      final status = _num(_first(l, _statusKeys))?.toInt();
      if (status != null) {
        if (status >= 500) server++;
        if (status >= 400 && status < 500) client++;
      } else if (l.severity.index >= Severity.error.index) {
        server++;
      }
      final d = _num(_first(l, _durationKeys));
      if (d != null && d >= 0) durations.add(d.toDouble());
      if (l.timestamp.isAfter(last)) last = l.timestamp;
    }
    durations.sort();
    final (method, route, routeKey) = keys[e.key]!;
    out.add(
      EndpointStats(
        method: method,
        route: route,
        routeKey: routeKey,
        calls: list.length,
        serverErrors: server,
        clientErrors: client,
        p50: percentile(durations, 50),
        p95: percentile(durations, 95),
        avg: durations.isEmpty ? null : durations.reduce((a, b) => a + b) / durations.length,
        lastSeen: last,
        services: {for (final l in list) l.service},
      ),
    );
  }
  out.sort((a, b) => b.calls.compareTo(a.calls));
  return out;
}

/// Nearest-rank percentile of sorted [values] (null if empty).
double? percentile(List<double> values, num p) {
  if (values.isEmpty) return null;
  final rank = ((p / 100) * values.length).ceil().clamp(1, values.length);
  return values[rank - 1];
}

extension on String? {
  String orIfEmpty(String fallback) => (this == null || this!.isEmpty) ? fallback : this!;
}
