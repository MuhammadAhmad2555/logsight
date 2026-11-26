import 'package:flutter_test/flutter_test.dart';
import 'package:trackapp/core/severity.dart';
import 'package:trackapp/core/tokenizer.dart';
import 'package:trackapp/data/log_query.dart';
import 'package:trackapp/data/models.dart';

LogEntry _log({
  String service = 'keyo_ios',
  Severity severity = Severity.info,
  String message = 'Payment failed for order 42',
  Map<String, dynamic> attributes = const {},
}) => LogEntry(
  id: 'x',
  timestamp: DateTime(2026, 11, 1),
  severity: severity,
  message: message,
  service: service,
  attributes: attributes,
  tokens: tokenize(message).toSet(),
);

void main() {
  group('tokenize', () {
    test('lowercases, splits on punctuation and drops short words', () {
      expect(tokenize('Payment FAILED: order#42 (a)'), ['payment', 'failed', 'order', '42']);
    });

    test('keeps underscores and removes duplicates', () {
      expect(tokenize('user_id user_id x'), ['user_id']);
    });

    test('caps the token count', () {
      final text = List.generate(100, (i) => 'word$i').join(' ');
      expect(tokenize(text).length, 64);
    });
  });

  group('LogQuery URL round trip', () {
    test('keeps every filter', () {
      final q = LogQuery(
        range: TimeRange.absolute(DateTime.utc(2026, 7, 1, 7, 28), DateTime.utc(2026, 11, 15, 2, 28)),
        services: const ['keyo_ios'],
        excludedServices: const ['kyberq_ios'],
        severities: const {Severity.error, Severity.warn},
        search: 'payment failed',
        filters: const [AttrFilter('app.version', FilterOp.equals, '2.1~beta')],
      );
      final uri = Uri(path: '/p/abc/logs', queryParameters: q.toQueryParameters());
      expect(LogQuery.fromUri(Uri.parse(uri.toString())), q);
    });

    test('defaults to the last 24 hours', () {
      expect(LogQuery.fromUri(Uri.parse('/p/abc/logs')).range, const TimeRange.relative(RelativePreset.h24));
    });

    test('ignores bad values', () {
      final q = LogQuery.fromUri(Uri.parse('/p/a/logs?range=nope&sev=loud,error&f=bad'));
      expect(q.severities, {Severity.error});
      expect(q.filters, isEmpty);
    });
  });

  group('LogQuery.matches', () {
    test('service include and exclude', () {
      const q = LogQuery(services: ['keyo_ios'], excludedServices: ['kyberq_ios']);
      expect(q.matches(_log()), isTrue);
      expect(q.matches(_log(service: 'kyberq_ios')), isFalse);
      expect(q.matches(_log(service: 'other')), isFalse);
    });

    test('search needs every whole word', () {
      expect(const LogQuery(search: 'payment order').matches(_log()), isTrue);
      expect(const LogQuery(search: 'payment refund').matches(_log()), isFalse);
      expect(const LogQuery(search: 'pay').matches(_log()), isFalse);
    });

    test('severity and attribute filters, including nested paths', () {
      final log = _log(
        severity: Severity.error,
        attributes: {
          'device': {'model': 'iPhone 17'},
          'retries': 3,
        },
      );
      expect(const LogQuery(severities: {Severity.error}).matches(log), isTrue);
      expect(const LogQuery(severities: {Severity.info}).matches(log), isFalse);
      expect(const LogQuery(filters: [AttrFilter('device.model', FilterOp.contains, 'iphone')]).matches(log), isTrue);
      expect(const LogQuery(filters: [AttrFilter('retries', FilterOp.equals, '3')]).matches(log), isTrue);
      expect(const LogQuery(filters: [AttrFilter('missing', FilterOp.notExists)]).matches(log), isTrue);
      expect(const LogQuery(filters: [AttrFilter('retries', FilterOp.notEquals, '3')]).matches(log), isFalse);
    });

    test('custom attributes: numbers, lists, booleans and > <', () {
      final log = _log(attributes: {'duration_ms': 750, 'price': 9.5, 'tags': ['beta', 'ios'], 'premium': true});
      bool m(String k, FilterOp op, [String v = '']) => LogQuery(filters: [AttrFilter(k, op, v)]).matches(log);
      expect(m('duration_ms', FilterOp.greaterThan, '500'), isTrue);
      expect(m('duration_ms', FilterOp.lessThan, '500'), isFalse);
      expect(m('price', FilterOp.equals, '9.50'), isTrue);
      expect(m('tags', FilterOp.equals, 'beta'), isTrue);
      expect(m('tags', FilterOp.notEquals, 'beta'), isFalse);
      expect(m('tags', FilterOp.notContains, 'android'), isTrue);
      expect(m('premium', FilterOp.equals, 'True'), isTrue);
      expect(m('missing', FilterOp.greaterThan, '1'), isFalse);
      expect(m('error.type', FilterOp.notExists), isTrue);
    });

    test('new operators survive the URL', () {
      const f = AttrFilter('duration_ms', FilterOp.greaterThan, '500');
      expect(AttrFilter.decode(f.encode()), f);
    });
  });

  group('volume buckets', () {
    test('choose a bar size that keeps the count at or under the limit', () {
      expect(bucketSizeFor(const Duration(hours: 24)), const Duration(hours: 1));
      expect(bucketSizeFor(const Duration(minutes: 15)), const Duration(minutes: 1));
      expect(bucketSizeFor(const Duration(days: 30)), const Duration(days: 1));
    });

    test('cover the whole range without gaps', () {
      final from = DateTime(2026, 11, 1, 10, 17);
      final to = DateTime(2026, 11, 2, 10, 17);
      final b = buildBuckets(from, to);
      expect(b.first.$1, from);
      expect(b.last.$2, to);
      for (var i = 1; i < b.length; i++) {
        expect(b[i].$1, b[i - 1].$2);
      }
      expect(b.length, lessThanOrEqualTo(40));
    });
  });
}
