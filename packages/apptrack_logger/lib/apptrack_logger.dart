/// Send logs from any Dart or Flutter app to AppTrack.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'src/file_sink.dart';

enum LogLevel { trace, debug, info, warn, error, fatal }

/// Queues logs and sends them to AppTrack in batches.
class AppTrackLogger {
  AppTrackLogger({
    required this.firebaseProjectId,
    required this.projectId,
    required this.ingestKey,
    required this.service,
    this.defaultAttributes = const {},
    this.minLevel = LogLevel.trace,
    this.batchSize = 50,
    this.flushInterval = const Duration(seconds: 5),
    this.maxQueue = 5000,
    this.printToConsole = false,
    this.logFilePath,
    String? distinctId,
    this.maxLogFileBytes = 5 * 1024 * 1024,
    http.Client? client,
  })  : assert(batchSize > 0 && batchSize <= 500),
        _client = client ?? http.Client(),
        _fileSink = logFilePath == null ? null : LogFileSink(logFilePath, maxBytes: maxLogFileBytes) {
    _distinctId = distinctId ?? _anonId();
    _timer = Timer.periodic(flushInterval, (_) => flush());
  }

  final String firebaseProjectId;
  final String projectId;
  final String ingestKey;

  /// Shown as `service_name` in AppTrack.
  final String service;

  /// Added to every log, e.g. app version or environment.
  final Map<String, Object?> defaultAttributes;
  final LogLevel minLevel;
  final int batchSize;
  final Duration flushInterval;
  final int maxQueue;
  final bool printToConsole;

  /// If set, every log is also appended to this text file (one line per log),
  /// e.g. `<app documents folder>/logs.txt`. Ignored on the web.
  final String? logFilePath;

  /// When the file grows past this size it's renamed to `logs.1.txt` and a
  /// new one is started, so at most two files are kept.
  final int maxLogFileBytes;

  /// Set these to attach the current user or session to every log.
  String? userId;
  String? sessionId;

  /// Who events belong to (PostHog's distinct_id). Starts as a random
  /// anonymous ID unless one is passed in; [identify] switches it to the
  /// user's ID. Persist it in the app (e.g. shared preferences) and pass it
  /// back in next launch so one person keeps one ID.
  String get distinctId => _distinctId;
  late String _distinctId;

  /// Writes that keep People and event definitions up to date, sent in their
  /// own request so a problem there never drops logs or events.
  final List<Map<String, Object?>> _meta = [];
  final Map<String, Set<String>> _knownEvents = {};

  final http.Client _client;
  final LogFileSink? _fileSink;
  final List<Map<String, Object?>> _queue = [];
  final Random _random = Random.secure();
  late final Timer _timer;
  Future<void>? _inFlight;
  int _failures = 0;
  DateTime _retryAfter = DateTime.fromMillisecondsSinceEpoch(0);
  bool _closed = false;
  bool _serviceRegistered = false;

  /// Logs dropped because the queue was full or the server rejected them.
  int dropped = 0;

  /// Logs queued but not yet delivered (waiting for a batch or a retry).
  /// After `await close()`, `pending == 0 && dropped == 0` means every log
  /// was accepted by the server.
  int get pending => _queue.length + _meta.length;

  Uri get _endpoint => Uri.parse(
      'https://firestore.googleapis.com/v1/projects/$firebaseProjectId/databases/(default)/documents:commit');

  String get _docBase =>
      'projects/$firebaseProjectId/databases/(default)/documents/projects/$projectId/logs/';

  void trace(String message, {Map<String, Object?>? attributes, String? traceId}) =>
      log(LogLevel.trace, message, attributes: attributes, traceId: traceId);
  void debug(String message, {Map<String, Object?>? attributes, String? traceId}) =>
      log(LogLevel.debug, message, attributes: attributes, traceId: traceId);
  void info(String message, {Map<String, Object?>? attributes, String? traceId}) =>
      log(LogLevel.info, message, attributes: attributes, traceId: traceId);
  void warn(String message, {Map<String, Object?>? attributes, String? traceId}) =>
      log(LogLevel.warn, message, attributes: attributes, traceId: traceId);

  /// Logs an error. All error details are optional:
  /// - [error]: the caught exception (its type and message are recorded)
  /// - [stackTrace]: where it happened
  /// - [reason]: your own explanation, e.g. 'Receipt rejected by backend'
  ///
  /// ```dart
  /// try { ... } catch (e, st) {
  ///   logger.error('Purchase failed', error: e, stackTrace: st, reason: 'Store returned no receipt');
  /// }
  /// ```
  void error(
    String message, {
    Map<String, Object?>? attributes,
    String? traceId,
    Object? error,
    StackTrace? stackTrace,
    String? reason,
  }) => log(
    LogLevel.error,
    message,
    attributes: attributes,
    traceId: traceId,
    error: error,
    stackTrace: stackTrace,
    reason: reason,
  );

  /// Like [error], for crashes and unrecoverable failures.
  void fatal(
    String message, {
    Map<String, Object?>? attributes,
    String? traceId,
    Object? error,
    StackTrace? stackTrace,
    String? reason,
  }) => log(
    LogLevel.fatal,
    message,
    attributes: attributes,
    traceId: traceId,
    error: error,
    stackTrace: stackTrace,
    reason: reason,
  );

  String get _root => 'projects/$firebaseProjectId/databases/(default)/documents/projects/$projectId';

  // ================================================================ ACTIVITY

  /// Records a product event (PostHog's `capture`), e.g.
  /// `capture('purchase_completed', properties: {'plan': 'pro', 'amount': 9.99})`.
  /// At most 128 properties per event.
  void capture(String event, {Map<String, Object?>? properties, DateTime? timestamp}) {
    if (_closed) return;
    final name = event.trim();
    if (name.isEmpty) return;
    final props = {...?properties};
    if (props.length > 128) {
      final keep = props.keys.take(128).toSet();
      props.removeWhere((k, _) => !keep.contains(k));
    }
    _queue.add({
      '_kind': 'event',
      'event': name.length > 200 ? name.substring(0, 200) : name,
      'distinctId': _distinctId,
      'ts': (timestamp ?? DateTime.now()).toUtc(),
      'key': ingestKey,
      'service': service,
      if (sessionId != null) 'sessionId': sessionId,
      if (props.isNotEmpty) 'properties': props,
    });
    _registerEvent(name, props.keys);
    _trimQueue();
    if (_queue.length >= batchSize) flush();
  }

  /// A screen view, like PostHog's `$screen` event.
  void screen(String screenName, {Map<String, Object?>? properties}) =>
      capture(r'$screen', properties: {r'$screen_name': screenName, ...?properties});

  /// Links the current (usually anonymous) ID to [userId] and makes [userId]
  /// the ID for all following events and logs. Optional [properties] are
  /// set on the person (e.g. email, name, plan).
  void identify(String userId, {Map<String, Object?>? properties}) {
    final id = userId.trim();
    if (_closed || id.isEmpty) return;
    final previous = _distinctId;
    _distinctId = id;
    this.userId = id;
    final aliases = previous != id ? [previous] : const <String>[];
    _person(id, properties ?? const {}, aliases: aliases);
    capture(r'$identify', properties: {if (previous != id) r'$anon_distinct_id': previous});
  }

  /// Sets properties on the current person (merged with existing ones).
  void setPersonProperties(Map<String, Object?> properties) {
    if (_closed || properties.isEmpty) return;
    _person(_distinctId, properties);
  }

  /// Call on sign-out: starts a new anonymous person and clears [userId].
  void reset() {
    _distinctId = _anonId();
    userId = null;
  }

  String _anonId() => 'anon_${_id()}';

  static bool _docIdOk(String s) =>
      s.isNotEmpty && s.length <= 200 && !s.contains('/') && s != '.' && s != '..' && !RegExp(r'^__.*__$').hasMatch(s);

  static String _quote(String key) => '`${key.replaceAll(r'\', r'\\').replaceAll('`', r'\`')}`';

  void _person(String id, Map<String, Object?> props, {List<String> aliases = const []}) {
    if (!_docIdOk(id)) return;
    final p = props.length > 200 ? Map.fromEntries(props.entries.take(200)) : props;
    _meta.add({
      'update': {
        'name': '$_root/persons/$id',
        'fields': {
          'key': {'stringValue': ingestKey},
          if (p.isNotEmpty) 'properties': toFirestoreValue(p),
        },
      },
      'updateMask': {
        'fieldPaths': ['key', for (final k in p.keys) 'properties.${_quote(k)}'],
      },
      'updateTransforms': [
        {'fieldPath': 'lastSeen', 'setToServerValue': 'REQUEST_TIME'},
        {
          'fieldPath': 'firstSeen',
          'minimum': {'integerValue': '${DateTime.now().millisecondsSinceEpoch}'},
        },
        if (aliases.isNotEmpty)
          {
            'fieldPath': 'aliases',
            'appendMissingElements': {
              'values': [for (final a in aliases) {'stringValue': a}],
            },
          },
      ],
    });
  }

  void _registerEvent(String name, Iterable<String> propertyKeys) {
    if (!_docIdOk(name)) return;
    final known = _knownEvents[name];
    final fresh = propertyKeys.where((k) => known == null || !known.contains(k)).toList();
    if (known != null && fresh.isEmpty) return;
    (_knownEvents[name] ??= {}).addAll(fresh);
    _meta.add({
      'update': {
        'name': '$_root/eventDefs/$name',
        'fields': {
          'key': {'stringValue': ingestKey},
        },
      },
      'updateMask': {
        'fieldPaths': ['key'],
      },
      'updateTransforms': [
        {'fieldPath': 'lastSeen', 'setToServerValue': 'REQUEST_TIME'},
        if (fresh.isNotEmpty)
          {
            'fieldPath': 'properties',
            'appendMissingElements': {
              'values': [for (final k in fresh.take(300)) {'stringValue': k}],
            },
          },
      ],
    });
  }

  void _trimQueue() {
    if (_queue.length > maxQueue) {
      final extra = _queue.length - maxQueue;
      _queue.removeRange(0, extra);
      dropped += extra;
    }
  }

  // ==================================================================== LOGS

  /// Queues one log. Never throws and never blocks.
  void log(
    LogLevel level,
    String message, {
    Map<String, Object?>? attributes,
    String? traceId,
    DateTime? timestamp,
    Object? error,
    StackTrace? stackTrace,
    String? reason,
  }) {
    if (_closed || level.index < minLevel.index) return;
    // Error details are only kept on error and fatal logs.
    final details = level.index >= LogLevel.error.index
        ? errorDetails(error: error, stackTrace: stackTrace, reason: reason)
        : null;
    // ignore: avoid_print
    if (printToConsole) print('[${level.name.toUpperCase()}] $service: $message');
    final attrs = {...defaultAttributes, ...?attributes};
    if (attrs.length > 64) {
      final keys = attrs.keys.take(64).toSet();
      attrs.removeWhere((k, _) => !keys.contains(k));
    }
    final text = message.length > 10000 ? message.substring(0, 10000) : message;
    final ts = (timestamp ?? DateTime.now()).toUtc();
    _fileSink?.write(formatLogLine(
      ts,
      level,
      service,
      text,
      attributes: attrs,
      userId: userId,
      sessionId: sessionId,
      traceId: traceId,
      error: details,
    ));
    _queue.add({
      'ts': ts,
      'severity': level.name,
      'message': text,
      'service': service,
      'key': ingestKey,
      'tokens': tokenize(text),
      if (attrs.isNotEmpty) 'attributes': attrs,
      if (userId != null) 'userId': userId,
      if (sessionId != null) 'sessionId': sessionId,
      'traceId': ?traceId,
      'error': ?details,
    });
    _trimQueue();
    if (_queue.length >= batchSize) flush();
  }

  /// Sends everything queued. Safe to call often; concurrent calls share one send.
  Future<void> flush() {
    final running = _inFlight;
    if (running != null) return running;
    if ((_queue.isEmpty && _meta.isEmpty) || DateTime.now().isBefore(_retryAfter)) return Future.value();
    final f = _drain().whenComplete(() => _inFlight = null);
    _inFlight = f;
    return f;
  }

  Future<void> _drain() async {
    while (_queue.isNotEmpty) {
      final batch = _queue.take(batchSize).toList();
      final status = await _send(batch);
      if (status == _SendResult.ok || status == _SendResult.rejected) {
        _queue.removeRange(0, batch.length);
        if (status == _SendResult.rejected) dropped += batch.length;
        _failures = 0;
        if (status == _SendResult.ok) {
          // Keep "last seen" current for everyone who just sent events.
          final people = {for (final e in batch) if (e['_kind'] == 'event') e['distinctId'] as String};
          for (final id in people) {
            _person(id, const {});
          }
        }
      } else {
        _backoff();
        return;
      }
    }
    while (_meta.isNotEmpty) {
      final batch = _meta.take(400).toList();
      final status = await _commit(batch);
      if (status == _SendResult.retry) {
        _backoff();
        return;
      }
      _meta.removeRange(0, batch.length);
    }
  }

  void _backoff() {
    _failures++;
    final backoff = Duration(seconds: min(300, pow(2, _failures).toInt()));
    _retryAfter = DateTime.now().add(backoff);
  }

  Future<_SendResult> _commit(List<Map<String, Object?>> writes) async {
    try {
      final res = await _client
          .post(_endpoint, headers: {'Content-Type': 'application/json'}, body: jsonEncode({'writes': writes}))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode == 200) return _SendResult.ok;
      if (res.statusCode == 400 || res.statusCode == 403) {
        // ignore: avoid_print
        if (printToConsole) print('AppTrack rejected ${writes.length} profile updates: ${res.body}');
        return _SendResult.rejected;
      }
      return _SendResult.retry;
    } catch (_) {
      return _SendResult.retry;
    }
  }

  Future<_SendResult> _send(List<Map<String, Object?>> batch) async {
    final registerService = !_serviceRegistered && _serviceIdOk(service);
    final body = jsonEncode({
      'writes': [
        // Once per logger: list this service.name in the project's services
        // so the dashboard can show it in the service switcher.
        if (registerService)
          {
            'update': {
              'name': 'projects/$firebaseProjectId/databases/(default)/documents/projects/$projectId/services/$service',
              'fields': {
                'key': {'stringValue': ingestKey},
              },
            },
            'updateMask': {
              'fieldPaths': ['key'],
            },
            'updateTransforms': [
              {'fieldPath': 'lastSeen', 'setToServerValue': 'REQUEST_TIME'},
            ],
          },
        for (final item in batch)
          {
            'update': {
              'name': item['_kind'] == 'event' ? '$_root/events/${_id()}' : '$_docBase${_id()}',
              'fields': _fields(Map.of(item)..remove('_kind')),
            },
            'currentDocument': {'exists': false},
            'updateTransforms': [
              {'fieldPath': 'receivedAt', 'setToServerValue': 'REQUEST_TIME'},
            ],
          },
      ],
    });
    try {
      final res = await _client
          .post(_endpoint, headers: {'Content-Type': 'application/json'}, body: body)
          .timeout(const Duration(seconds: 20));
      if (res.statusCode == 200) {
        if (registerService) _serviceRegistered = true;
        return _SendResult.ok;
      }
      // 400/403: bad data or a disabled key. Retrying won't help.
      if (res.statusCode == 400 || res.statusCode == 403) {
        // ignore: avoid_print
        if (printToConsole) print('AppTrack rejected ${batch.length} logs/events: ${res.body}');
        return _SendResult.rejected;
      }
      return _SendResult.retry;
    } catch (_) {
      return _SendResult.retry;
    }
  }

  String _id() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(20, (_) => chars[_random.nextInt(chars.length)]).join();
  }

  /// Flushes and stops the timer. The logger can't be used afterwards.
  Future<void> close() async {
    _timer.cancel();
    _retryAfter = DateTime.fromMillisecondsSinceEpoch(0);
    await flush();
    _closed = true;
    _fileSink?.close();
    _client.close();
  }
}

enum _SendResult { ok, retry, rejected }

/// Service names that are safe as a Firestore document ID.
bool _serviceIdOk(String s) =>
    s.isNotEmpty && s.length <= 100 && RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(s) && s != '.' && s != '..';

Map<String, Object?> _fields(Map<String, Object?> m) => m.map((k, v) => MapEntry(k, toFirestoreValue(v)));

/// Encodes a Dart value as a Firestore REST `Value`.
Map<String, Object?> toFirestoreValue(Object? v) {
  if (v == null) return {'nullValue': null};
  if (v is bool) return {'booleanValue': v};
  if (v is int) return {'integerValue': '$v'};
  if (v is double) {
    if (v.isNaN || v.isInfinite) return {'stringValue': '$v'};
    return {'doubleValue': v};
  }
  if (v is DateTime) return {'timestampValue': v.toUtc().toIso8601String()};
  if (v is Map) {
    return {
      'mapValue': {'fields': v.map((k, e) => MapEntry('$k', toFirestoreValue(e)))},
    };
  }
  if (v is Iterable) {
    return {
      'arrayValue': {'values': v.map(toFirestoreValue).toList()},
    };
  }
  return {'stringValue': '$v'};
}

/// One line of the text log file, e.g.
/// `2026-11-25T17:39:43.374Z ERROR keyo_ios user=abc: Payment failed {"order_id":42}`
String formatLogLine(
  DateTime ts,
  LogLevel level,
  String service,
  String message, {
  Map<String, Object?> attributes = const {},
  String? userId,
  String? sessionId,
  String? traceId,
  Map<String, String>? error,
}) {
  final b = StringBuffer()
    ..write(ts.toUtc().toIso8601String())
    ..write(' ')
    ..write(level.name.toUpperCase().padRight(5))
    ..write(' ')
    ..write(service);
  if (userId != null) b.write(' user=$userId');
  if (sessionId != null) b.write(' session=$sessionId');
  if (traceId != null) b.write(' trace=$traceId');
  b
    ..write(': ')
    ..write(message.replaceAll('\r\n', '\n').replaceAll('\n', '\\n'));
  if (attributes.isNotEmpty) {
    b
      ..write(' ')
      ..write(jsonEncode(attributes, toEncodable: (o) => o is DateTime ? o.toUtc().toIso8601String() : '$o'));
  }
  if (error != null && error.isNotEmpty) b..write(' error=')..write(jsonEncode(error));
  return b.toString();
}

/// Must match the dashboard's tokenizer (lib/core/tokenizer.dart).
List<String> tokenize(String text, {int maxTokens = 64}) {
  final seen = <String>{};
  for (final raw in text.toLowerCase().split(RegExp(r'[^a-z0-9_]+'))) {
    if (raw.length < 2 || raw.length > 40) continue;
    seen.add(raw);
    if (seen.length >= maxTokens) break;
  }
  return seen.toList();
}

/// Builds the optional `error` field of a log, or null when there's nothing
/// to record. Long values are cut to stay within the server's limits.
Map<String, String>? errorDetails({Object? error, StackTrace? stackTrace, String? reason}) {
  String? cut(String? v, int max) {
    final t = v?.trim();
    if (t == null || t.isEmpty) return null;
    return t.length > max ? t.substring(0, max) : t;
  }

  final out = <String, String>{
    'type': ?cut(error?.runtimeType.toString(), 200),
    'message': ?cut(error?.toString(), 4000),
    'reason': ?cut(reason, 4000),
    'stack': ?cut(stackTrace?.toString(), 16000),
  };
  return out.isEmpty ? null : out;
}
