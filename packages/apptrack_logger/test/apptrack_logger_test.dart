import 'dart:convert';

import 'package:apptrack_logger/apptrack_logger.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('batches logs into one commit with the right shape', () async {
    final bodies = <Map<String, dynamic>>[];
    final client = MockClient((req) async {
      bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
      return http.Response('{}', 200);
    });
    final logger = AppTrackLogger(
      firebaseProjectId: 'fb',
      projectId: 'p1',
      ingestKey: 'atk_key',
      service: 'svc',
      defaultAttributes: {'env': 'test'},
      client: client,
    );
    logger.info('Payment failed for order', attributes: {'n': 1, 'ok': true, 'nested': {'a': 1.5}});
    logger.error('Boom');
    await logger.close();

    expect(bodies, hasLength(1));
    final all = bodies.single['writes'] as List;
    final service = all.first as Map<String, dynamic>;
    expect(service['update']['name'], endsWith('/projects/p1/services/svc'));
    expect(service['update']['fields']['key'], {'stringValue': 'atk_key'});
    expect(service['updateTransforms'].single['fieldPath'], 'lastSeen');
    final writes = all.skip(1).toList();
    expect(writes, hasLength(2));
    final first = writes.first as Map<String, dynamic>;
    final fields = first['update']['fields'] as Map<String, dynamic>;
    expect(first['update']['name'], startsWith('projects/fb/databases/(default)/documents/projects/p1/logs/'));
    expect(fields['severity'], {'stringValue': 'info'});
    expect(fields['service'], {'stringValue': 'svc'});
    expect(fields['key'], {'stringValue': 'atk_key'});
    expect(fields['ts'], contains('timestampValue'));
    expect(fields['attributes']['mapValue']['fields']['n'], {'integerValue': '1'});
    expect(fields['attributes']['mapValue']['fields']['env'], {'stringValue': 'test'});
    expect(first['currentDocument'], {'exists': false});
    expect(first['updateTransforms'].single['setToServerValue'], 'REQUEST_TIME');
  });

  test('keeps logs queued after a server error and drops them after a rejection', () async {
    var status = 503;
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      return http.Response('{}', status);
    });
    final logger = AppTrackLogger(
        firebaseProjectId: 'fb', projectId: 'p', ingestKey: 'k', service: 's', client: client);
    logger.info('hello');
    await logger.flush();
    expect(calls, 1);
    expect(logger.dropped, 0);
    expect(logger.pending, 1);

    status = 403;
    await logger.close(); // close() skips the backoff wait
    expect(calls, 2);
    expect(logger.dropped, 1);
    expect(logger.pending, 0);
  });

  test('registers the service only once, and skips unsafe names', () async {
    Future<List<int>> serviceWrites(String service) async {
      final counts = <int>[];
      final client = MockClient((req) async {
        final writes = (jsonDecode(req.body) as Map)['writes'] as List;
        counts.add(writes.where((w) => '${w['update']['name']}'.contains('/services/')).length);
        return http.Response('{}', 200);
      });
      final logger = AppTrackLogger(
          firebaseProjectId: 'fb', projectId: 'p', ingestKey: 'k', service: service, client: client);
      logger.info('one');
      await logger.flush();
      logger.info('two');
      await logger.close();
      return counts;
    }

    expect(await serviceWrites('keyo_android'), [1, 0]);
    expect(await serviceWrites('bad/name'), [0, 0]);
  });

  test('tokenize matches the dashboard rules', () {
    expect(tokenize('Payment FAILED: order#42 (a)'), ['payment', 'failed', 'order', '42']);
  });
}
