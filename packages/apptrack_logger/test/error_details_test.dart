import 'dart:convert';

import 'package:apptrack_logger/apptrack_logger.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  Future<List<Map<String, dynamic>>> send(void Function(AppTrackLogger l) body) async {
    final bodies = <Map<String, dynamic>>[];
    final client = MockClient((req) async {
      bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
      return http.Response('{}', 200);
    });
    final logger = AppTrackLogger(firebaseProjectId: 'fb', projectId: 'p', ingestKey: 'k', service: 's', client: client);
    body(logger);
    await logger.close();
    return [
      for (final b in bodies)
        for (final w in b['writes'] as List)
          if ((w['update']['name'] as String).contains('/logs/')) w['update']['fields'] as Map<String, dynamic>,
    ];
  }

  test('error() records type, message, reason and stack trace', () async {
    final logs = await send((l) {
      try {
        throw const FormatException('bad receipt');
      } catch (e, st) {
        l.error('Purchase failed', error: e, stackTrace: st, reason: 'Store returned no receipt');
      }
    });
    final err = logs.single['error']['mapValue']['fields'] as Map<String, dynamic>;
    expect(err['type'], {'stringValue': 'FormatException'});
    expect(err['message']['stringValue'], contains('bad receipt'));
    expect(err['reason'], {'stringValue': 'Store returned no receipt'});
    expect(err['stack']['stringValue'], contains('error_details_test.dart'));
  });

  test('error details are optional and only kept on error/fatal', () async {
    final logs = await send((l) {
      l.error('Plain error');
      l.fatal('Only a reason', reason: 'Disk full');
      l.log(LogLevel.warn, 'Warn with error', error: Exception('x'));
    });
    expect(logs[0].containsKey('error'), isFalse);
    expect(logs[1]['error']['mapValue']['fields'].keys, ['reason']);
    expect(logs[2].containsKey('error'), isFalse);
  });

  test('errorDetails trims and caps lengths', () {
    expect(errorDetails(), isNull);
    expect(errorDetails(reason: '   '), isNull);
    final d = errorDetails(reason: 'r' * 5000, stackTrace: StackTrace.fromString('s' * 20000))!;
    expect(d['reason']!.length, 4000);
    expect(d['stack']!.length, 16000);
  });

  test('file log line includes error details', () {
    final line = formatLogLine(DateTime.utc(2026), LogLevel.error, 's', 'Boom', error: {'type': 'StateError'});
    expect(line, endsWith('error={"type":"StateError"}'));
  });
}
