import 'dart:convert';

import 'package:apptrack_logger/apptrack_logger.dart';
import 'package:apptrack_logger/src/flags.dart' show fnv1a32;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

Map<String, dynamic> _flagDoc(String key, {bool enabled = true, int rollout = 100, List<Map<String, String>>? conditions}) => {
  'name': 'projects/fb/databases/(default)/documents/projects/p1/flags/$key',
  'fields': {
    'enabled': {'booleanValue': enabled},
    'rollout': {'integerValue': '$rollout'},
    'conditions': {
      'arrayValue': {
        'values': [
          for (final c in conditions ?? const <Map<String, String>>[])
            {
              'mapValue': {
                'fields': {for (final e in c.entries) e.key: {'stringValue': e.value}},
              },
            },
        ],
      },
    },
  },
};

void main() {
  group('rollout hashing (same reference values as the dashboard)', () {
    test('FNV-1a', () {
      expect(fnv1a32(''), 0x811c9dc5);
      expect(fnv1a32('a'), 0xe40c292c);
      expect(fnv1a32('foobar'), 0xbf9cf968);
    });

    test('buckets', () {
      expect(rolloutBucket('new-checkout', 'user_1'), 21);
      expect(rolloutBucket('new-checkout', 'user_2'), 64);
      expect(rolloutBucket('beta', 'anon_xyz'), 81);
      expect(rolloutBucket('dark-mode', 'ahmad@example.com'), 97);
    });
  });

  test('loads flags and evaluates them for the current person', () async {
    Uri? asked;
    final client = MockClient((req) async {
      if (req.method == 'GET') {
        asked = req.url;
        return http.Response(
          jsonEncode({
            'documents': [
              _flagDoc('everyone'),
              _flagDoc('off', enabled: false),
              _flagDoc('pro-only', conditions: [
                {'property': 'plan', 'op': 'equals', 'value': 'pro'},
              ]),
              _flagDoc('new-checkout', rollout: 50),
            ],
          }),
          200,
        );
      }
      return http.Response('{}', 200);
    });
    final logger = AppTrackLogger(
      firebaseProjectId: 'fb',
      projectId: 'p1',
      ingestKey: 'k',
      service: 's',
      distinctId: 'user_1',
      client: client,
    );
    expect(logger.isFeatureEnabled('everyone'), isFalse, reason: 'not loaded yet → fallback');
    expect(logger.isFeatureEnabled('everyone', fallback: true), isTrue);

    expect(await logger.reloadFeatureFlags(), isTrue);
    expect(asked!.path, '/v1/projects/fb/databases/(default)/documents/projects/p1/flags');
    expect(logger.isFeatureEnabled('everyone'), isTrue);
    expect(logger.isFeatureEnabled('off'), isFalse);
    expect(logger.isFeatureEnabled('missing', fallback: true), isTrue);
    // user_1 is in bucket 21 of new-checkout, inside a 50% rollout.
    expect(logger.isFeatureEnabled('new-checkout'), isTrue);

    expect(logger.isFeatureEnabled('pro-only'), isFalse);
    logger.setPersonProperties({'plan': 'pro'});
    expect(logger.isFeatureEnabled('pro-only'), isTrue);
    expect(logger.featureFlags, {'everyone': true, 'off': false, 'pro-only': true, 'new-checkout': true});

    logger.reset();
    expect(logger.isFeatureEnabled('pro-only'), isFalse, reason: 'reset clears person properties');
    await logger.close();
  });

  test('keeps the old flags when loading fails', () async {
    var fail = false;
    final client = MockClient((req) async {
      if (fail) return http.Response('nope', 503);
      return http.Response(jsonEncode({'documents': [_flagDoc('a')]}), 200);
    });
    final logger = AppTrackLogger(firebaseProjectId: 'fb', projectId: 'p', ingestKey: 'k', service: 's', client: client);
    expect(await logger.reloadFeatureFlags(), isTrue);
    fail = true;
    expect(await logger.reloadFeatureFlags(), isFalse);
    expect(logger.isFeatureEnabled('a'), isTrue);
    await logger.close();
  });

  test('request() logs method, route, status and duration with the request token', () async {
    final bodies = <Map<String, dynamic>>[];
    final client = MockClient((req) async {
      bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
      return http.Response('{}', 200);
    });
    final logger = AppTrackLogger(firebaseProjectId: 'fb', projectId: 'p', ingestKey: 'k', service: 's', client: client);
    logger.request('get', '/api/orders/:id', statusCode: 503, duration: const Duration(milliseconds: 1234));
    logger.request('POST', '/api/orders', statusCode: 422, attributes: {'http.route': 'ignored', 'region': 'eu'});
    logger.request('GET', '/api/ping', duration: const Duration(microseconds: 1500));
    await logger.close();

    final writes = (bodies.single['writes'] as List).skip(1).map((w) => w['update']['fields'] as Map).toList();
    Map attrs(int i) => writes[i]['attributes']['mapValue']['fields'] as Map;
    List tokens(int i) => (writes[i]['tokens']['arrayValue']['values'] as List).map((v) => v['stringValue']).toList();

    expect(writes[0]['severity'], {'stringValue': 'error'});
    expect(writes[0]['message'], {'stringValue': 'GET /api/orders/:id 503 (1234 ms)'});
    expect(attrs(0)['http.method'], {'stringValue': 'GET'});
    expect(attrs(0)['http.route'], {'stringValue': '/api/orders/:id'});
    expect(attrs(0)['http.status_code'], {'integerValue': '503'});
    expect(attrs(0)['duration_ms'], {'doubleValue': 1234.0});
    expect(tokens(0).first, 'http_request');

    expect(writes[1]['severity'], {'stringValue': 'warn'});
    expect(attrs(1)['http.route'], {'stringValue': '/api/orders'}, reason: 'request fields win');
    expect(attrs(1)['region'], {'stringValue': 'eu'});

    expect(writes[2]['severity'], {'stringValue': 'info'});
    expect(attrs(2)['duration_ms'], {'doubleValue': 1.5});
    expect(attrs(2).containsKey('http.status_code'), isFalse);
  });
}
