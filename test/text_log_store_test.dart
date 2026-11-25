import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trackapp/core/severity.dart';
import 'package:trackapp/data/models.dart';
import 'package:trackapp/data/text_logs/text_log_format.dart';
import 'package:trackapp/data/text_logs/text_log_store.dart';

LogEntry _log(String id, int minute, {String service = 'keyo_ios', String message = 'hello'}) => LogEntry(
  id: id,
  timestamp: DateTime.utc(2026, 11, 25, 10, minute),
  severity: Severity.error,
  message: message,
  service: service,
  attributes: const {'order_id': 42},
  tokens: const {},
  userId: 'u1',
);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('logsight_text'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('formats one readable line and escapes newlines', () {
    expect(
      formatLogLine(_log('a', 5, message: 'Payment failed\nretry')),
      r'2026-11-25T10:05:00.000Z ERROR keyo_ios user=u1: Payment failed\nretry {"order_id":42}',
    );
  });

  test('saves each log once, oldest first, in all.txt and per service.name', () async {
    final store = TextLogStore('proj1', basePath: dir.path);
    // Pages arrive newest first; the file should still read oldest first.
    expect(await store.append([_log('b', 2), _log('a', 1)]), 2);
    expect(await store.append([_log('c', 3, service: 'keyo_android'), _log('b', 2)]), 1);

    final base = '${dir.path}/LogSight/proj1';
    final all = File('$base/all.txt').readAsLinesSync();
    expect(all, hasLength(3));
    expect(all.first, startsWith('2026-11-25T10:01'));
    expect(File('$base/keyo_ios.txt').readAsLinesSync(), hasLength(2));
    expect(File('$base/keyo_android.txt').readAsLinesSync(), hasLength(1));

    // A new store (e.g. after restarting the app) still skips saved logs.
    final again = TextLogStore('proj1', basePath: dir.path);
    expect(await again.append([_log('a', 1), _log('d', 4)]), 1);
    expect(File('$base/all.txt').readAsLinesSync(), hasLength(4));
  });

  test('export writes the current view to exports/', () async {
    final store = TextLogStore('proj1', basePath: dir.path);
    final path = await store.export([_log('b', 2), _log('a', 1)], 'keyo_ios');
    expect(path, contains('/LogSight/proj1/exports/keyo_ios-'));
    final lines = File(path!).readAsLinesSync();
    expect(lines, hasLength(2));
    expect(lines.first, startsWith('2026-11-25T10:01'));
  });
}
