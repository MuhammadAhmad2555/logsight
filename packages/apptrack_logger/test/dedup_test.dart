import 'dart:convert';
import 'dart:io';

import 'package:apptrack_logger/apptrack_logger.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// Behaves like Firestore's commit: all-or-nothing; 409 if any log/event
/// document already exists; 403 if a message contains "bad". With
/// [loseResponse] it stores the batch but the reply never arrives.
class FakeFirestore {
  final stored = <String, Map<String, dynamic>>{};
  final requests = <List<String>>[];
  bool loseResponse = false;

  static bool _isData(String name) => name.contains('/logs/') || name.contains('/events/');

  late final client = MockClient((req) async {
    final writes = ((jsonDecode(req.body) as Map)['writes'] as List).cast<Map<String, dynamic>>();
    final docs = {
      for (final w in writes)
        if (_isData(w['update']['name'] as String)) w['update']['name'] as String: w['update']['fields'] as Map<String, dynamic>,
    };
    requests.add(docs.keys.toList());
    if (docs.keys.any(stored.containsKey)) return http.Response('{"error":{"status":"ALREADY_EXISTS"}}', 409);
    if (docs.values.any((f) => '${f['message']?['stringValue']}'.contains('bad'))) {
      return http.Response('{"error":{"status":"PERMISSION_DENIED"}}', 403);
    }
    stored.addAll(docs);
    if (loseResponse) throw const SocketException('connection reset');
    return http.Response('{}', 200);
  });

  List<String> get messages => [
    for (final f in stored.values) '${f['message']?['stringValue'] ?? f['event']?['stringValue']}',
  ]..sort();
}

AppTrackLogger _logger(FakeFirestore fs, {String? queueFile}) => AppTrackLogger(
  firebaseProjectId: 'fb',
  projectId: 'p',
  ingestKey: 'k',
  service: 'svc',
  client: fs.client,
  queueFilePath: queueFile,
  flushInterval: const Duration(hours: 1),
);

void main() {
  test('a retry after a lost response reuses the IDs and stores nothing twice', () async {
    final fs = FakeFirestore()..loseResponse = true;
    final logger = _logger(fs);
    logger.info('a');
    logger.info('b');
    await logger.flush(); // stored, but the app thinks it failed
    expect(fs.stored, hasLength(2));
    expect(logger.pending, 2);

    fs.loseResponse = false;
    logger.info('c');
    await logger.close(); // [a, b, c] → 409 → one at a time
    expect(fs.messages, ['a', 'b', 'c']);
    expect(logger.duplicates, 2);
    expect(logger.dropped, 0);
    expect(logger.pending, 0);
    // a and b were re-sent under the same document names.
    expect(fs.requests[1].take(2), fs.requests[0]);
  });

  test('a re-send after a restart reuses the IDs from the queue file', () async {
    final dir = Directory.systemTemp.createTempSync('apptrack_dedup_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/q.jsonl';
    final fs = FakeFirestore()..loseResponse = true;
    final first = _logger(fs, queueFile: path)..info('kept once');
    await first.close(); // stored, but not marked sent: "crash" before the reply
    expect(fs.stored, hasLength(1));

    fs.loseResponse = false;
    final second = _logger(fs, queueFile: path);
    expect(second.restored, 1);
    await second.close();
    expect(fs.messages, ['kept once']);
    expect(second.duplicates, 1);
    expect(File(path).lengthSync(), 0);
  });

  test('one bad log no longer drops the good ones sent with it', () async {
    final fs = FakeFirestore();
    final logger = _logger(fs)
      ..info('good 1')
      ..info('bad one')
      ..info('good 2');
    await logger.close();
    expect(fs.messages, ['good 1', 'good 2']);
    expect(logger.dropped, 1);
    expect(logger.duplicates, 0);
  });

  test('a custom id stores an event once, however often it is sent', () async {
    final fs = FakeFirestore();
    final logger = _logger(fs);
    logger.capture('purchase_completed', id: 'txn_123', properties: {'amount': 9.99});
    await logger.flush();
    logger.capture('purchase_completed', id: 'txn_123', properties: {'amount': 9.99});
    logger.log(LogLevel.info, 'paid', id: 'log-txn_123');
    await logger.close();
    expect(fs.stored.keys.where((k) => k.endsWith('/events/txn_123')), hasLength(1));
    expect(fs.stored.keys.where((k) => k.endsWith('/logs/log-txn_123')), hasLength(1));
    expect(logger.duplicates, 1);
  });

  test('409 ABORTED (contention) is retried, not counted as delivered', () async {
    var calls = 0;
    final stored = <String>[];
    final logger = AppTrackLogger(
      firebaseProjectId: 'fb',
      projectId: 'p',
      ingestKey: 'k',
      service: 'svc',
      flushInterval: const Duration(hours: 1),
      client: MockClient((req) async {
        if (calls++ == 0) return http.Response('{"error":{"code":409,"status":"ABORTED"}}', 409);
        stored.add(req.body);
        return http.Response('{}', 200);
      }),
    );
    logger.info('a');
    await logger.flush();
    expect(logger.pending, 1);
    expect(logger.duplicates, 0);
    await logger.close();
    expect(stored, hasLength(1));
    expect(logger.pending, 0);
  });

  test('an invalid custom id falls back to a generated one', () async {
    final fs = FakeFirestore();
    final logger = _logger(fs);
    for (final bad in ['a/b', '..', '__x__', 'x' * 300, '  ']) {
      logger.capture('e', id: bad);
    }
    await logger.close();
    final ids = fs.stored.keys.map((k) => k.split('/').last).toList();
    expect(ids, hasLength(5));
    expect(ids.every((id) => RegExp(r'^[A-Za-z0-9]{20}$').hasMatch(id)), isTrue);
  });
}
