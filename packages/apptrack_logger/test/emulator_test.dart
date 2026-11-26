// Runs only against the Firestore emulator, with the project's real rules:
//   firebase emulators:exec --only firestore --project demo-logsight \
//     'cd packages/apptrack_logger && dart test test/emulator_test.dart'
import 'dart:convert';
import 'dart:io';

import 'package:apptrack_logger/apptrack_logger.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// Real HTTP, but the reply to the first commit is "lost" after the server
/// has already stored it.
class _LoseFirstReply extends http.BaseClient {
  final _inner = http.Client();
  bool _lost = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final res = await _inner.send(request);
    if (!_lost && request.url.path.endsWith(':commit')) {
      _lost = true;
      await res.stream.drain<void>();
      throw const SocketException('reply lost');
    }
    return res;
  }
}

void main() {
  final host = Platform.environment['FIRESTORE_EMULATOR_HOST'];
  const project = 'demo-logsight';
  final key = 'atk_${'k' * 40}';
  final docs = 'http://$host/v1/projects/$project/databases/(default)/documents';

  Future<List<String>> list(String collection) async {
    final res = await http.get(Uri.parse('$docs/projects/p1/$collection?pageSize=300'), headers: {'Authorization': 'Bearer owner'});
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return [
      for (final d in (body['documents'] as List?) ?? const [])
        ((d as Map)['fields'] as Map)['message']?['stringValue'] as String? ??
            (d['fields'] as Map)['event']['stringValue'] as String,
    ]..sort();
  }

  test('lost reply + retry and a repeated custom ID: everything stored exactly once', () async {
    final seeded = await http.post(
      Uri.parse('$docs/projects/p1/ingestKeys?documentId=$key'),
      headers: {'Authorization': 'Bearer owner', 'Content-Type': 'application/json'},
      body: jsonEncode({'fields': {'active': {'booleanValue': true}}}),
    );
    expect(seeded.statusCode, 200);

    final logger = AppTrackLogger(
      firebaseProjectId: project,
      projectId: 'p1',
      ingestKey: key,
      service: 'svc',
      apiBase: 'http://$host',
      client: _LoseFirstReply(),
      flushInterval: const Duration(hours: 1),
    );
    logger.info('one');
    logger.capture('purchase_completed', id: 'txn_1');
    await logger.flush(); // stored, reply lost → still queued
    expect(logger.pending, greaterThanOrEqualTo(2));

    logger.info('two');
    logger.capture('purchase_completed', id: 'txn_1'); // same purchase again
    logger.log(LogLevel.info, 'x' * 10, attributes: {for (var i = 0; i < 64; i++) 'a$i': i}); // fine
    await logger.close();

    expect(await list('logs'), ['one', 'two', 'x' * 10]);
    expect(await list('events'), ['purchase_completed']);
    expect(logger.duplicates, 3); // one, txn_1 (retry) and txn_1 (repeat)
    expect(logger.dropped, 0);
    expect(logger.pending, 0);
  }, skip: host == null ? 'needs the Firestore emulator' : false);
}
