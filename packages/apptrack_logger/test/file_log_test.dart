import 'dart:io';

import 'package:apptrack_logger/apptrack_logger.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('logsight_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  AppTrackLogger logger(String path, {int maxBytes = 5 * 1024 * 1024}) => AppTrackLogger(
        firebaseProjectId: 'fb',
        projectId: 'p',
        ingestKey: 'k',
        service: 'keyo_ios',
        logFilePath: path,
        maxLogFileBytes: maxBytes,
        client: MockClient((_) async => http.Response('{}', 200)),
      );

  test('writes one readable line per log, also without network', () async {
    final path = '${dir.path}/sub/logs.txt';
    final l = logger(path)..userId = 'u1';
    l.error('Payment failed\nretry later', attributes: {'order_id': 42});
    l.info('App opened');
    await l.close();

    final lines = File(path).readAsLinesSync();
    expect(lines, hasLength(2));
    expect(lines[0], matches(RegExp(r'^\d{4}-\d\d-\d\dT[\d:.]+Z ERROR keyo_ios user=u1: ')));
    expect(lines[0], endsWith(r'Payment failed\nretry later {"order_id":42}'));
    expect(lines[1], contains('INFO  keyo_ios user=u1: App opened'));
  });

  test('appends across app launches', () async {
    final path = '${dir.path}/logs.txt';
    await (logger(path)..info('first launch')).close();
    await (logger(path)..info('second launch')).close();
    expect(File(path).readAsLinesSync(), hasLength(2));
  });

  test('rotates to logs.1.txt when the file is too big', () async {
    final path = '${dir.path}/logs.txt';
    final l = logger(path, maxBytes: 300);
    for (var i = 0; i < 20; i++) {
      l.info('message number $i with some padding text');
    }
    await l.close();
    expect(File('${dir.path}/logs.1.txt').existsSync(), isTrue);
    expect(File(path).lengthSync(), lessThanOrEqualTo(300 + 200));
  });
}
