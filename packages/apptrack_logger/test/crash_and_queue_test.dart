import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:apptrack_logger/apptrack_logger.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// Messages of the log writes in a commit body (skips the service write).
List<Map<String, dynamic>> _logFields(Map<String, dynamic> body) => [
  for (final w in (body['writes'] as List).cast<Map<String, dynamic>>())
    if ((w['update']['name'] as String).contains('/logs/')) w['update']['fields'] as Map<String, dynamic>,
];

String _msg(Map<String, dynamic> fields) => fields['message']['stringValue'] as String;

AppTrackLogger _logger(http.Client client, {String? queueFile, int maxQueue = 5000}) => AppTrackLogger(
  firebaseProjectId: 'fb',
  projectId: 'p',
  ingestKey: 'k',
  service: 'svc',
  client: client,
  queueFilePath: queueFile,
  maxQueue: maxQueue,
  flushInterval: const Duration(hours: 1),
);

void main() {
  late Directory dir;
  late String path;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('apptrack_queue_');
    path = '${dir.path}/queue.jsonl';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  group('queue file', () {
    test('unsent logs survive a restart and are sent next launch', () async {
      final offline = _logger(MockClient((_) async => http.Response('', 503)), queueFile: path);
      final when = DateTime.utc(2026, 11, 26, 10);
      offline.info('one', attributes: {'at': when});
      offline.error('two', error: StateError('bad'));
      offline.capture('purchase_completed', properties: {'plan': 'pro'});
      await offline.close();
      // 3 logs/events + 1 event-definition update (kept in memory only).
      expect(offline.pending, 4);

      final bodies = <Map<String, dynamic>>[];
      final online = _logger(
        MockClient((req) async {
          bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
          return http.Response('{}', 200);
        }),
        queueFile: path,
      );
      expect(online.restored, 3);
      await online.flush();
      expect(online.pending, 0);

      // First request: the logs and event; then a "last seen" profile update.
      final writes = (bodies.first['writes'] as List).cast<Map<String, dynamic>>();
      final logs = _logFields(bodies.first);
      expect(logs.map(_msg), ['one', 'two']);
      expect(logs.first['attributes']['mapValue']['fields']['at'], {'timestampValue': '2026-11-26T10:00:00.000Z'});
      expect(logs.first.containsKey('_n'), isFalse);
      expect(logs[1]['error']['mapValue']['fields']['type'], {'stringValue': 'StateError'});
      expect(writes.where((w) => (w['update']['name'] as String).contains('/events/')), hasLength(1));
      // Everything sent: the file is emptied.
      expect(File(path).lengthSync(), 0);
      await online.close();
    });

    test('a line cut short by a crash is skipped', () async {
      final offline = _logger(MockClient((_) async => http.Response('', 503)), queueFile: path);
      offline.info('kept');
      await offline.close();
      File(path).writeAsStringSync('{"n": 99, "q": {"message": "half', mode: FileMode.append);

      final again = _logger(MockClient((_) async => http.Response('', 503)), queueFile: path);
      expect(again.restored, 1);
      await again.close();
    });

    test('logs added or dropped while a batch is in flight are handled by sequence', () async {
      final release = Completer<void>();
      final sent = <String>[];
      final logger = _logger(
        MockClient((req) async {
          await release.future;
          sent.addAll(_logFields(jsonDecode(req.body) as Map<String, dynamic>).map(_msg));
          return http.Response('{}', 200);
        }),
        queueFile: path,
        maxQueue: 3,
      );
      logger.info('a');
      logger.info('b');
      final inFlight = logger.flush(); // sends a, b
      logger.info('c');
      logger.info('d'); // queue full: a is dropped while in flight
      release.complete();
      await inFlight;
      // After a and b are accepted, only they leave the queue (by sequence
      // number, not position), so c and d are sent next and nothing is lost.
      expect(sent, ['a', 'b', 'c', 'd']);
      expect(logger.pending, 0);
      // a was dropped from the full queue while already in flight (it was
      // still delivered); the counter includes it.
      expect(logger.dropped, 1);
      await logger.close();
    });

    test('keeps the newest when more were saved than the queue holds', () async {
      final offline = _logger(MockClient((_) async => http.Response('', 503)), queueFile: path);
      for (var i = 0; i < 5; i++) {
        offline.info('m$i');
      }
      await offline.close();
      final small = _logger(MockClient((_) async => http.Response('', 503)), queueFile: path, maxQueue: 2);
      expect(small.restored, 2);
      expect(small.dropped, 3);
      await small.close();
    });
  });

  test('over-long IDs are cut to the server limits instead of failing the batch', () async {
    Map<String, dynamic>? body;
    final logger = _logger(MockClient((req) async {
      body ??= jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response('{}', 200);
    }))
      ..userId = 'u' * 300
      ..sessionId = 's' * 300;
    logger.info('hi', traceId: 't' * 300);
    await logger.close();
    final f = _logFields(body!).single;
    expect((f['userId']['stringValue'] as String).length, 128);
    expect((f['sessionId']['stringValue'] as String).length, 128);
    expect((f['traceId']['stringValue'] as String).length, 128);
  });

  group('retention', () {
    Future<Map<String, dynamic>> firstLog(AppTrackLogger Function(http.Client) make) async {
      Map<String, dynamic>? body;
      final logger = make(MockClient((req) async {
        body ??= jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('{}', 200);
      }));
      logger.log(LogLevel.info, 'hi', timestamp: DateTime.utc(2026, 11, 26, 10));
      await logger.close();
      return _logFields(body!).single;
    }

    AppTrackLogger make(http.Client c, Duration? retention) => AppTrackLogger(
      firebaseProjectId: 'fb', projectId: 'p', ingestKey: 'k', service: 'svc', client: c, retention: retention,
    );

    test('logs carry expireAt = log time + 90 days by default', () async {
      final f = await firstLog((c) => AppTrackLogger(firebaseProjectId: 'fb', projectId: 'p', ingestKey: 'k', service: 'svc', client: c));
      expect(f['expireAt'], {'timestampValue': '2027-02-24T10:00:00.000Z'});
    });

    test('custom retention is clamped to 1–400 days; null sends none', () async {
      expect((await firstLog((c) => make(c, const Duration(days: 7))))['expireAt'], {'timestampValue': '2026-12-03T10:00:00.000Z'});
      expect((await firstLog((c) => make(c, const Duration(hours: 1))))['expireAt'], {'timestampValue': '2026-11-27T10:00:00.000Z'});
      expect((await firstLog((c) => make(c, const Duration(days: 9999))))['expireAt'], {'timestampValue': '2027-12-31T10:00:00.000Z'});
      expect((await firstLog((c) => make(c, null))).containsKey('expireAt'), isFalse);
    });
  });

  group('crash capture', () {
    late List<Map<String, dynamic>> logs;
    late AppTrackLogger logger;
    setUp(() {
      logs = [];
      logger = _logger(
        MockClient((req) async {
          logs.addAll(_logFields(jsonDecode(req.body) as Map<String, dynamic>));
          return http.Response('{}', 200);
        }),
      );
    });

    Map<String, dynamic> attrs(Map<String, dynamic> f) => f['attributes']['mapValue']['fields'] as Map<String, dynamic>;
    Map<String, dynamic> err(Map<String, dynamic> f) => f['error']['mapValue']['fields'] as Map<String, dynamic>;

    test('recordUncaughtError logs an unhandled error and lets Flutter report it too', () async {
      final handled = logger.recordUncaughtError(const FormatException('Bad JSON\nat line 2'), StackTrace.current);
      expect(handled, isFalse);
      await logger.close();
      final f = logs.single;
      expect(f['severity'], {'stringValue': 'error'});
      expect(_msg(f), 'FormatException: Bad JSON');
      expect(attrs(f)['error.handled'], {'booleanValue': false});
      expect(attrs(f)['error.mechanism'], {'stringValue': 'PlatformDispatcher.onError'});
      expect(err(f)['type'], {'stringValue': 'FormatException'});
      expect(err(f)['stack']['stringValue'], contains('crash_and_queue_test.dart'));
    });

    test('recordFlutterError reads FlutterErrorDetails without depending on Flutter', () async {
      logger.recordFlutterError(
        _FakeFlutterErrorDetails(
          exception: StateError('A RenderFlex overflowed by 42 pixels'),
          stack: StackTrace.current,
          library: 'rendering library',
          context: 'during layout',
        ),
      );
      await logger.close();
      final f = logs.single;
      expect(_msg(f), 'Bad state: A RenderFlex overflowed by 42 pixels');
      expect(attrs(f)['error.library'], {'stringValue': 'rendering library'});
      expect(attrs(f)['error.context'], {'stringValue': 'during layout'});
      expect(attrs(f)['error.mechanism'], {'stringValue': 'FlutterError.onError'});
    });

    test('runGuarded logs errors nothing else caught as fatal', () async {
      logger.runGuarded(() async {
        await Future<void>.delayed(Duration.zero);
        throw ArgumentError('lost in async');
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await logger.close();
      expect(logs.single['severity'], {'stringValue': 'fatal'});
      expect(_msg(logs.single), 'Invalid argument(s): lost in async');
    });

    test('the same error repeating is sent at most a few times a minute', () async {
      for (var i = 0; i < 20; i++) {
        logger.recordUncaughtError(StateError('every frame'), StackTrace.current);
      }
      logger.recordUncaughtError(StateError('something else'), StackTrace.current);
      await logger.close();
      expect(logs.where((f) => _msg(f).contains('every frame')), hasLength(AppTrackLogger.crashRepeatLimit));
      expect(logs.where((f) => _msg(f).contains('something else')), hasLength(1));
    });
  });
}

/// Shaped like Flutter's FlutterErrorDetails.
class _FakeFlutterErrorDetails {
  _FakeFlutterErrorDetails({required this.exception, this.stack, this.library, this.context});
  final Object exception;
  final StackTrace? stack;
  final String? library;
  final Object? context;
  final bool silent = false;
}
