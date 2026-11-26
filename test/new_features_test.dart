import 'package:flutter_test/flutter_test.dart';
import 'package:trackapp/core/severity.dart';
import 'package:trackapp/core/tokenizer.dart';
import 'package:trackapp/data/dashboards.dart';
import 'package:trackapp/data/endpoints.dart';
import 'package:trackapp/data/flags.dart';
import 'package:trackapp/data/log_query.dart';
import 'package:trackapp/data/models.dart';
import 'package:trackapp/features/flags/flags_screen.dart' show parseTestProperties;

LogEntry _req(String method, String route, int status, num ms, {DateTime? at, String service = 'keyo_ios'}) => LogEntry(
  id: 'x',
  timestamp: at ?? DateTime(2026, 11, 26, 10),
  severity: status >= 500 ? Severity.error : (status >= 400 ? Severity.warn : Severity.info),
  message: '$method $route $status',
  service: service,
  attributes: {'http.method': method, 'http.route': route, 'http.status_code': status, 'duration_ms': ms},
  tokens: {requestToken, ...tokenize('$method $route')},
);

void main() {
  group('feature flag hashing', () {
    test('FNV-1a matches the reference values', () {
      expect(fnv1a32(''), 0x811c9dc5);
      expect(fnv1a32('a'), 0xe40c292c);
      expect(fnv1a32('foobar'), 0xbf9cf968);
    });

    test('rollout buckets match the SDK (same reference values)', () {
      expect(rolloutBucket('new-checkout', 'user_1'), 21);
      expect(rolloutBucket('new-checkout', 'user_2'), 64);
      expect(rolloutBucket('beta', 'anon_xyz'), 81);
      expect(rolloutBucket('dark-mode', 'ahmad@example.com'), 97);
    });

    test('a 20% rollout reaches about 20% of people', () {
      const f = FeatureFlag(key: 'new-checkout', enabled: true, rollout: 20);
      final on = List.generate(10000, (i) => f.isEnabledFor('u$i')).where((x) => x).length;
      expect(on, 2021);
    });
  });

  group('feature flag evaluation', () {
    test('off, rollout and conditions', () {
      const off = FeatureFlag(key: 'x', enabled: false);
      expect(off.isEnabledFor('u'), isFalse);
      const all = FeatureFlag(key: 'x', enabled: true);
      expect(all.isEnabledFor('anyone'), isTrue);
      const none = FeatureFlag(key: 'x', enabled: true, rollout: 0);
      expect(none.isEnabledFor('anyone'), isFalse);

      const pro = FeatureFlag(
        key: 'x',
        enabled: true,
        conditions: [
          FlagCondition('plan', FilterOp.equals, 'pro'),
          FlagCondition('app.version', FilterOp.greaterThan, '2'),
        ],
      );
      expect(pro.isEnabledFor('u', {'plan': 'pro', 'app': {'version': 3}}), isTrue);
      expect(pro.isEnabledFor('u', {'plan': 'pro', 'app': {'version': 1}}), isFalse);
      expect(pro.isEnabledFor('u', {'plan': 'free', 'app': {'version': 3}}), isFalse);
      expect(pro.isEnabledFor('u'), isFalse);
    });

    test('test properties are parsed with types', () {
      expect(parseTestProperties('plan=pro, age=30, beta=true'), {'plan': 'pro', 'age': 30, 'beta': true});
      expect(parseTestProperties('garbage, =x'), isEmpty);
    });

    test('conditions round-trip through Firestore maps', () {
      const c = FlagCondition('country', FilterOp.notEquals, 'PK');
      expect(FlagCondition.fromMap(c.toMap()), c);
      expect(FlagCondition.fromMap({'property': 'x', 'op': 'nope'}), isNull);
    });

    test('flag keys', () {
      expect(FeatureFlag.keyPattern.hasMatch('new-checkout'), isTrue);
      expect(FeatureFlag.keyPattern.hasMatch('beta_2'), isTrue);
      expect(FeatureFlag.keyPattern.hasMatch('New Checkout'), isFalse);
      expect(FeatureFlag.keyPattern.hasMatch('-x'), isFalse);
    });
  });

  group('endpoints', () {
    test('groups by method and route with error rate and percentiles', () {
      final logs = [
        for (var i = 1; i <= 20; i++) _req('GET', '/api/orders/:id', i == 20 ? 503 : 200, i * 10),
        _req('POST', '/api/orders', 201, 300),
        _req('POST', '/api/orders', 422, 50),
        _req('get', '/api/orders/:id', 404, 5, service: 'keyo_android'),
      ];
      final stats = endpointStats(logs);
      expect(stats.map((s) => '${s.method} ${s.route}'), ['GET /api/orders/:id', 'POST /api/orders']);
      final get = stats.first;
      expect(get.calls, 21);
      expect(get.serverErrors, 1);
      expect(get.clientErrors, 1);
      expect(get.p50, 100);
      expect(get.p95, 190);
      expect(get.services, {'keyo_ios', 'keyo_android'});
      expect(stats.last.clientErrors, 1);
      expect(stats.last.serverErrors, 0);
    });

    test('logs without a route are skipped; other attribute spellings work', () {
      final otel = LogEntry(
        id: 'y',
        timestamp: DateTime(2026),
        severity: Severity.error,
        message: 'boom',
        service: 's',
        attributes: {'http.request.method': 'DELETE', 'url.path': '/v1/items'},
        tokens: const {},
      );
      final plain = _req('GET', '', 200, 1);
      final stats = endpointStats([otel, plain]);
      expect(stats.single.method, 'DELETE');
      expect(stats.single.routeKey, 'url.path');
      expect(stats.single.serverErrors, 1, reason: 'error log without status counts as failed');
      expect(stats.single.p50, isNull);
    });

    test('percentile', () {
      expect(percentile([], 50), isNull);
      expect(percentile([1, 2, 3, 4], 50), 2);
      expect(percentile([1, 2, 3, 4], 95), 4);
    });
  });

  group('dashboards', () {
    test('tile queries drop the time range and keep filters', () {
      final q = LogQuery(
        range: const TimeRange.relative(RelativePreset.d7),
        services: const ['keyo_ios'],
        severities: const {Severity.error},
        filters: const [AttrFilter('app.version', FilterOp.equals, '2.1')],
      );
      final stored = DashboardTile.queryWithoutRange(q.toQueryParameters());
      expect(stored.contains('range'), isFalse);
      final tile = DashboardTile(id: 't', title: 'Errors', source: TileSource.logs, viz: TileViz.number, query: stored);
      final back = tile.logQuery(const TimeRange.relative(RelativePreset.h1));
      expect(back.range, const TimeRange.relative(RelativePreset.h1));
      expect(back.services, ['keyo_ios']);
      expect(back.severities, {Severity.error});
      expect(back.filters, q.filters);
    });

    test('tiles round-trip through Firestore maps', () {
      const t = DashboardTile(id: 'a1', title: 'Volume', source: TileSource.events, viz: TileViz.bars, query: 'event=x');
      final back = DashboardTile.fromMap(t.toMap())!;
      expect([back.id, back.title, back.source, back.viz, back.query], [t.id, t.title, t.source, t.viz, t.query]);
      expect(DashboardTile.fromMap({'source': 'nope', 'viz': 'bars'}), isNull);
    });
  });
}
