/// Send logs from any Dart or Flutter app to AppTrack.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'src/file_sink.dart';
import 'src/flags.dart';
import 'src/queue_store.dart';

export 'src/flags.dart' show FeatureFlag, FlagCondition, rolloutBucket;

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
    this.queueFilePath,
    this.retention = const Duration(days: 90),
    this.apiBase = 'https://firestore.googleapis.com',
    String? distinctId,
    this.maxLogFileBytes = 5 * 1024 * 1024,
    http.Client? client,
  })  : assert(batchSize > 0 && batchSize <= 500),
        _client = client ?? http.Client(),
        _fileSink = logFilePath == null ? null : LogFileSink(logFilePath, maxBytes: maxLogFileBytes),
        _store = queueFilePath == null ? null : QueueStore(queueFilePath) {
    _distinctId = distinctId ?? _anonId();
    _restoreQueue();
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

  /// If set, logs and events waiting to be sent are also kept in this file,
  /// so they survive the app being killed, crashing or going offline and are
  /// sent on the next launch, e.g. `<app support folder>/apptrack_queue.jsonl`.
  /// Use one file per logger. Ignored on the web (the queue stays in memory).
  final String? queueFilePath;

  /// How long LogSight keeps each log: sent as `expireAt` (log time +
  /// retention), which Firestore's TTL policy uses to delete it
  /// automatically once the project turns TTL on. 1–400 days; null sends no
  /// expiry. Events are not affected.
  final Duration? retention;

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

  /// Where the Firestore REST API is. Only change it for tests (e.g. the
  /// Firestore emulator at `http://localhost:8080`).
  final String apiBase;

  /// [retention] clamped to what the server accepts (1–400 days).
  late final Duration? _retention = retention == null
      ? null
      : Duration(
          microseconds: retention!.inMicroseconds.clamp(
            const Duration(days: 1).inMicroseconds,
            const Duration(days: 400).inMicroseconds,
          ),
        );

  final http.Client _client;
  final LogFileSink? _fileSink;
  final QueueStore? _store;

  /// Logs and events waiting to be sent, oldest first. Each has a sequence
  /// number in `_n` (also used by the queue file).
  final List<Map<String, Object?>> _queue = [];
  int _seq = 0;
  final Random _random = Random.secure();
  late final Timer _timer;
  Future<void>? _inFlight;
  int _failures = 0;
  DateTime _retryAfter = DateTime.fromMillisecondsSinceEpoch(0);
  bool _closed = false;
  bool _serviceRegistered = false;

  /// Logs dropped because the queue was full or the server rejected them.
  int dropped = 0;

  /// Logs and events restored from [queueFilePath] at startup (left unsent
  /// by an earlier run).
  int restored = 0;

  /// Sends the server had already stored (a retry after a lost response, a
  /// re-send after a restart, or a repeated custom `id`). They are skipped,
  /// so nothing is stored twice.
  int duplicates = 0;

  /// Logs queued but not yet delivered (waiting for a batch or a retry).
  /// After `await close()`, `pending == 0 && dropped == 0` means every log
  /// was accepted by the server.
  int get pending => _queue.length + _meta.length;

  Uri get _endpoint => Uri.parse('$apiBase/v1/projects/$firebaseProjectId/databases/(default)/documents:commit');

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
  ///
  /// [id] makes the event idempotent: events with the same ID are stored
  /// once, e.g. `capture('purchase_completed', id: transactionId)`. Without
  /// it each call gets its own ID (retries never create copies either way).
  void capture(String event, {Map<String, Object?>? properties, DateTime? timestamp, String? id}) {
    if (_closed) return;
    final name = event.trim();
    if (name.isEmpty) return;
    final props = {...?properties};
    if (props.length > 128) {
      final keep = props.keys.take(128).toSet();
      props.removeWhere((k, _) => !keep.contains(k));
    }
    _enqueue({
      '_kind': 'event',
      'event': name.length > 200 ? name.substring(0, 200) : name,
      'distinctId': _cut(_distinctId, 200),
      'ts': (timestamp ?? DateTime.now()).toUtc(),
      'key': ingestKey,
      'service': service,
      if (sessionId != null) 'sessionId': _cut(sessionId!, 128),
      if (props.isNotEmpty) 'properties': props,
    }, id: id);
    _registerEvent(name, props.keys);
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
    _personProps.addAll(properties ?? const {});
    final aliases = previous != id ? [previous] : const <String>[];
    _person(id, properties ?? const {}, aliases: aliases);
    capture(r'$identify', properties: {if (previous != id) r'$anon_distinct_id': previous});
  }

  /// Sets properties on the current person (merged with existing ones).
  void setPersonProperties(Map<String, Object?> properties) {
    if (_closed || properties.isEmpty) return;
    _personProps.addAll(properties);
    _person(_distinctId, properties);
  }

  /// Call on sign-out: starts a new anonymous person and clears [userId].
  void reset() {
    _distinctId = _anonId();
    userId = null;
    _personProps.clear();
  }

  // =========================================================== FEATURE FLAGS

  /// Properties of the current person (from [identify] and
  /// [setPersonProperties]); feature flag conditions are checked against them.
  final Map<String, Object?> _personProps = {};
  Map<String, FeatureFlag> _flags = const {};
  DateTime? _flagsLoadedAt;

  /// When flags were last loaded (null before the first [reloadFeatureFlags]).
  DateTime? get featureFlagsLoadedAt => _flagsLoadedAt;

  /// Loads the project's feature flags. Call at startup (and e.g. when the
  /// app resumes) before asking [isFeatureEnabled]. Returns false if they
  /// couldn't be loaded; the previously loaded flags are kept.
  Future<bool> reloadFeatureFlags() async {
    final flags = <String, FeatureFlag>{};
    String? pageToken;
    try {
      do {
        final uri = Uri.parse(
          '$apiBase/v1/$_root/flags',
        ).replace(queryParameters: {'pageSize': '300', 'pageToken': ?pageToken});
        final res = await _client.get(uri).timeout(const Duration(seconds: 15));
        if (res.statusCode != 200) return false;
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        for (final doc in (body['documents'] as List?) ?? const []) {
          final f = FeatureFlag.fromFirestore(doc as Map<String, dynamic>);
          if (f != null) flags[f.key] = f;
        }
        pageToken = body['nextPageToken'] as String?;
      } while (pageToken != null && pageToken.isNotEmpty);
    } catch (_) {
      return false;
    }
    _flags = flags;
    _flagsLoadedAt = DateTime.now();
    return true;
  }

  /// Whether flag [key] is on for the current person. Unknown flags (or
  /// flags not loaded yet) return [fallback]. Extra [properties] are checked
  /// on top of the person's.
  bool isFeatureEnabled(String key, {bool fallback = false, Map<String, Object?>? properties}) {
    final f = _flags[key];
    if (f == null) return fallback;
    return f.isEnabledFor(_distinctId, {..._personProps, ...?properties});
  }

  /// Every loaded flag and whether it is on for the current person.
  Map<String, bool> get featureFlags => {
    for (final f in _flags.values) f.key: f.isEnabledFor(_distinctId, _personProps),
  };

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

  /// Queues an item. Its Firestore document ID is fixed here (custom [id] if
  /// valid, else random), so every retry and every re-send after a restart
  /// writes the same document and can't create a copy.
  void _enqueue(Map<String, Object?> item, {String? id}) {
    final custom = id?.trim();
    item['_id'] = custom != null && _docIdOk(custom) ? custom : _id();
    item['_n'] = ++_seq;
    _queue.add(item);
    _store?.added(item);
    if (_queue.length > maxQueue) {
      final extra = _queue.length - maxQueue;
      final last = _queue[extra - 1]['_n'] as int;
      _queue.removeRange(0, extra);
      dropped += extra;
      _store?.removedUpTo(last, _queue);
    }
    if (_queue.length >= batchSize) flush();
  }

  /// Removes everything up to sequence number [seq] (sent or rejected).
  void _removeUpTo(int seq) {
    _queue.removeWhere((e) => (e['_n'] as int) <= seq);
    _store?.removedUpTo(seq, _queue);
  }

  void _restoreQueue() {
    final items = _store?.load() ?? const [];
    if (items.isEmpty) return;
    // Keep the newest if more were saved than the queue holds.
    final keep = items.length > maxQueue ? items.sublist(items.length - maxQueue) : items;
    dropped += items.length - keep.length;
    // Items saved by SDK versions before document IDs were fixed at creation.
    for (final item in keep) {
      item['_id'] ??= _id();
    }
    _queue.addAll(keep);
    _seq = keep.last['_n'] as int;
    restored = keep.length;
    // Send them soon, not after the first flush interval.
    Timer.run(flush);
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
    String? id,
  }) => _log(
    level,
    message,
    attributes: attributes,
    traceId: traceId,
    timestamp: timestamp,
    error: error,
    stackTrace: stackTrace,
    reason: reason,
    id: id,
  );

  /// Logs one API request for the Endpoints page: calls, error rate and
  /// latency per route. Use the route pattern, not the full URL, so calls
  /// group together:
  ///
  /// ```dart
  /// final sw = Stopwatch()..start();
  /// final res = await http.get(uri);
  /// appTrack.request('GET', '/api/orders/:id', statusCode: res.statusCode, duration: sw.elapsed);
  /// ```
  ///
  /// 5xx (or a thrown [error] without a status) is logged as an error, 4xx as
  /// a warning, anything else as info.
  void request(
    String method,
    String route, {
    int? statusCode,
    Duration? duration,
    Map<String, Object?>? attributes,
    String? traceId,
    Object? error,
    StackTrace? stackTrace,
  }) {
    final m = method.trim().toUpperCase();
    final r = route.trim();
    if (r.isEmpty) return;
    final ms = duration == null ? null : duration.inMicroseconds / 1000;
    final level = statusCode == null
        ? (error != null ? LogLevel.error : LogLevel.info)
        : (statusCode >= 500 ? LogLevel.error : (statusCode >= 400 ? LogLevel.warn : LogLevel.info));
    final text = [
      m,
      r,
      if (statusCode != null) '$statusCode',
      if (ms != null) '(${ms.round()} ms)',
      if (statusCode == null && error != null) 'failed',
    ].join(' ');
    final http = <String, Object?>{
      'http.method': m,
      'http.route': r,
      'http.status_code': ?statusCode,
      if (ms != null) 'duration_ms': (ms * 10).round() / 10,
    };
    _log(
      level,
      text,
      // Request fields first (so the 64-attribute cap never drops them) and
      // last (so they win over same-named custom attributes).
      attributes: {...http, ...?attributes, ...http},
      traceId: traceId,
      error: error,
      stackTrace: stackTrace,
      extraTokens: const [requestToken],
    );
  }

  /// Token added to request logs so the dashboard can find them quickly.
  static const requestToken = 'http_request';

  void _log(
    LogLevel level,
    String message, {
    Map<String, Object?>? attributes,
    String? traceId,
    DateTime? timestamp,
    Object? error,
    StackTrace? stackTrace,
    String? reason,
    List<String> extraTokens = const [],
    String? id,
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
    _enqueue({
      'ts': ts,
      'severity': level.name,
      'message': text,
      'service': service,
      'key': ingestKey,
      'tokens': extraTokens.isEmpty
          ? tokenize(text)
          : {...extraTokens, ...tokenize(text, maxTokens: 64 - extraTokens.length)}.toList(),
      if (attrs.isNotEmpty) 'attributes': attrs,
      // Cut to the server's limits: one over-long value would get the whole
      // batch rejected.
      if (userId != null) 'userId': _cut(userId!, 128),
      if (sessionId != null) 'sessionId': _cut(sessionId!, 128),
      if (traceId != null) 'traceId': _cut(traceId, 128),
      'error': ?details,
      if (_retention != null) 'expireAt': ts.add(_retention),
    }, id: id);
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
      if (status == _SendResult.retry) {
        _backoff();
        return;
      }
      _failures = 0;
      if (status == _SendResult.ok) {
        _delivered(batch);
      } else if (batch.length == 1) {
        _resolved(batch.single, status);
      } else {
        // A commit is all-or-nothing: one item already stored (409) or one bad
        // item (400/403) fails the whole batch. Send them one at a time so
        // only those are skipped and the rest are stored.
        for (final item in batch) {
          final one = await _send([item]);
          if (one == _SendResult.retry) {
            _backoff();
            return;
          }
          if (one == _SendResult.ok) {
            _delivered([item]);
          } else {
            _resolved(item, one);
          }
        }
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

  /// Removes items the server stored and keeps "last seen" current for
  /// everyone who just sent events. By sequence number: while a batch is in
  /// flight, newer items may be added and older ones dropped (queue full).
  void _delivered(List<Map<String, Object?>> items) {
    _removeUpTo(items.last['_n'] as int);
    final people = {for (final e in items) if (e['_kind'] == 'event') e['distinctId'] as String};
    for (final id in people) {
      _person(id, const {});
    }
  }

  /// One item the server didn't store: already there, or rejected.
  void _resolved(Map<String, Object?> item, _SendResult status) {
    _removeUpTo(item['_n'] as int);
    if (status == _SendResult.exists) {
      duplicates++;
    } else {
      dropped++;
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
              'name': item['_kind'] == 'event' ? '$_root/events/${item['_id']}' : '$_docBase${item['_id']}',
              'fields': _fields(Map.of(item)..remove('_kind')..remove('_n')..remove('_id')),
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
      // 409 ALREADY_EXISTS: a document with this ID is already stored (sent
      // before). Other 409s (ABORTED: contention) are retried.
      if (res.statusCode == 409) return res.body.contains('ALREADY_EXISTS') ? _SendResult.exists : _SendResult.retry;
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
    _store?.close();
    _client.close();
  }

  // ================================================================= CRASHES

  /// Uncaught errors sent per error (type + first line) per minute; repeats
  /// beyond this (e.g. an error thrown on every frame) are skipped.
  static const crashRepeatLimit = 5;
  final Map<String, (DateTime, int)> _recentCrashes = {};

  /// Records a Flutter framework error (build, layout, paint…). Set it as
  /// Flutter's handler at startup:
  ///
  /// ```dart
  /// FlutterError.onError = (details) {
  ///   FlutterError.presentError(details); // keep the console output
  ///   appTrack.recordFlutterError(details);
  /// };
  /// ```
  ///
  /// [details] is a `FlutterErrorDetails` (typed loosely so this package
  /// works without Flutter).
  void recordFlutterError(Object details, {bool fatal = false}) {
    try {
      final d = details as dynamic;
      final Object error = d.exception as Object;
      final stack = d.stack as StackTrace?;
      String? text(Object? v) {
        final s = v?.toString().trim();
        return s == null || s.isEmpty ? null : s;
      }

      _recordUncaught(
        error,
        stack,
        mechanism: 'FlutterError.onError',
        fatal: fatal,
        attributes: {
          'error.library': ?text(d.library),
          'error.context': ?text(d.context),
          if (d.silent == true) 'error.silent': true,
        },
      );
    } catch (_) {
      _recordUncaught(details, null, mechanism: 'FlutterError.onError', fatal: fatal);
    }
  }

  /// Records an uncaught error. Set it as the handler for errors outside
  /// Flutter's callbacks (async code, platform channels):
  ///
  /// ```dart
  /// PlatformDispatcher.instance.onError = appTrack.recordUncaughtError;
  /// ```
  ///
  /// Returns false, so Flutter still reports the error as usual.
  bool recordUncaughtError(Object error, StackTrace stackTrace, {bool fatal = false}) {
    _recordUncaught(error, stackTrace, mechanism: 'PlatformDispatcher.onError', fatal: fatal);
    return false;
  }

  /// Runs [body] and records any error it doesn't catch, including in async
  /// code it starts. For Dart apps and servers without Flutter:
  ///
  /// ```dart
  /// void main() => appTrack.runGuarded(() async { ... });
  /// ```
  ///
  /// Errors caught here are logged as `fatal`, since nothing else handled them.
  void runGuarded(FutureOr<void> Function() body) {
    runZonedGuarded(
      body,
      (error, stack) => _recordUncaught(error, stack, mechanism: 'runGuarded', fatal: true),
    );
  }

  void _recordUncaught(
    Object error,
    StackTrace? stack, {
    required String mechanism,
    bool fatal = false,
    Map<String, Object?> attributes = const {},
  }) {
    if (_closed) return;
    try {
      final text = error.toString().trim();
      final firstLine = text.split('\n').first.trim();
      final message = firstLine.isEmpty ? '${error.runtimeType}' : firstLine;
      final key = '${error.runtimeType}|$message';
      final now = DateTime.now();
      final seen = _recentCrashes[key];
      final count = seen != null && now.difference(seen.$1) < const Duration(minutes: 1) ? seen.$2 + 1 : 1;
      _recentCrashes[key] = (count == 1 ? now : seen!.$1, count);
      if (_recentCrashes.length > 200) _recentCrashes.remove(_recentCrashes.keys.first);
      if (count > crashRepeatLimit) return;

      _log(
        fatal ? LogLevel.fatal : LogLevel.error,
        message.length > 500 ? message.substring(0, 500) : message,
        error: error,
        stackTrace: stack,
        attributes: {'error.handled': false, 'error.mechanism': mechanism, ...attributes},
      );
      flush();
    } catch (_) {
      // Never let error reporting throw.
    }
  }
}

enum _SendResult { ok, retry, rejected, exists }

String _cut(String s, int max) => s.length > max ? s.substring(0, max) : s;

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
