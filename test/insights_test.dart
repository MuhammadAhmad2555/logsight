import 'package:flutter_test/flutter_test.dart';
import 'package:trackapp/core/patterns.dart';
import 'package:trackapp/core/severity.dart';
import 'package:trackapp/data/insights.dart';
import 'package:trackapp/data/log_query.dart';
import 'package:trackapp/data/models.dart';
import 'package:trackapp/data/text_logs/text_log_format.dart';

LogEntry _log(
  String id,
  String message, {
  Severity severity = Severity.error,
  String service = 'keyo_ios',
  int minute = 0,
  String? user,
}) => LogEntry(
  id: id,
  timestamp: DateTime.utc(2026, 11, 26, 10, minute),
  severity: severity,
  message: message,
  service: service,
  attributes: const {},
  tokens: const {},
  userId: user,
);

void main() {
  group('patternOf', () {
    test('replaces variable parts', () {
      expect(patternOf('Payment failed for order 42 after 350ms'), 'Payment failed for order <num> after <num>');
      expect(patternOf('User a1b2c3d4e5 signed in from 10.0.0.12'), 'User <id> signed in from <ip>');
      expect(patternOf('Email sent to ana@example.com'), 'Email sent to <email>');
      expect(patternOf('GET https://api.keyo.app/v1/x?id=9 failed'), 'GET <url> failed');
      expect(patternOf('Request 3f2b1c9e-1d2a-4b5c-8e9f-0a1b2c3d4e5f timed out'), 'Request <uuid> timed out');
      expect(patternOf('Key "abc" missing'), 'Key "<str>" missing');
    });

    test('same template for different values', () {
      expect(patternOf('Payment failed for order 7'), patternOf('Payment failed for order 9001'));
    });
  });

  test('stableHash is stable and 16 hex chars', () {
    expect(stableHash('hello'), stableHash('hello'));
    expect(stableHash('hello'), isNot(stableHash('hellp')));
    expect(stableHash('x'), matches(RegExp(r'^[0-9a-f]{16}$')));
  });

  test('groupPatterns counts and orders by frequency', () {
    final groups = groupPatterns([
      _log('1', 'Payment failed for order 1', minute: 1),
      _log('2', 'Payment failed for order 2', minute: 2, severity: Severity.fatal),
      _log('3', 'App opened', severity: Severity.info),
    ]);
    expect(groups.first.pattern, 'Payment failed for order <num>');
    expect(groups.first.count, 2);
    expect(groups.first.topSeverity, Severity.fatal);
    expect(groups.first.lastSeen, DateTime.utc(2026, 11, 26, 10, 2));
  });

  test('groupIssues: errors only, users counted, regressions first', () {
    final logs = [
      _log('1', 'Payment failed for order 1', minute: 5, user: 'u1'),
      _log('2', 'Payment failed for order 2', minute: 6, user: 'u2'),
      _log('3', 'Sync crashed', minute: 1),
      _log('4', 'App opened', severity: Severity.info),
    ];
    final syncId = logs[2].fingerprint;
    final payId = logs[0].fingerprint;
    final issues = groupIssues(logs, {
      // Resolved before the newest payment error, so it regressed.
      payId: IssueState(id: payId, status: IssueStatus.resolved, resolvedAt: DateTime.utc(2026, 11, 26, 10, 5, 30)),
      syncId: IssueState(id: syncId, status: IssueStatus.resolved, resolvedAt: DateTime.utc(2026, 11, 26, 10, 30)),
    });
    expect(issues, hasLength(2));
    expect(issues.first.fingerprint, payId);
    expect(issues.first.regressed, isTrue);
    expect(issues.first.users, {'u1', 'u2'});
    expect(issues.last.regressed, isFalse);
  });

  test('pattern filter matches logs of that pattern', () {
    final f = AttrFilter('pattern', FilterOp.equals, 'Payment failed for order <num>');
    expect(LogQuery(filters: [f]).matches(_log('1', 'Payment failed for order 77')), isTrue);
    expect(LogQuery(filters: [f]).matches(_log('2', 'Sync crashed')), isFalse);
  });

  test('CSV export quotes commas, quotes and newlines', () {
    final csv = formatLogsCsv([_log('1', 'Failed, "badly"\nretry')]);
    final lines = csv.split('\r\n');
    expect(lines.first, 'timestamp,severity,service,message,userId,sessionId,traceId,attributes');
    expect(lines[1], startsWith('2026-11-26T10:00:00.000Z,error,keyo_ios,"Failed, ""badly""\nretry",'));
  });

  test('groupByField groups by attribute values, nested paths, not-set last', () {
    LogEntry withAttrs(String id, Map<String, dynamic> a, {Severity sev = Severity.info}) => LogEntry(
      id: id,
      timestamp: DateTime.utc(2026, 11, 26),
      severity: sev,
      message: 'm',
      service: 'keyo_ios',
      attributes: a,
      tokens: const {},
    );
    final logs = [
      withAttrs('1', {
        'user.email': 'a@x.com',
        'device': {'model': 'iPhone 17'},
      }),
      withAttrs('2', {
        'user.email': 'a@x.com',
        'device': {'model': 'iPhone 16'},
      }, sev: Severity.error),
      withAttrs('3', {'user.email': 'b@x.com'}),
      withAttrs('4', {}),
    ];
    final byEmail = groupByField(logs, 'user.email');
    expect(byEmail.map((g) => g.value), ['a@x.com', 'b@x.com', null]);
    expect(byEmail.first.count, 2);
    expect(byEmail.first.errors, 1);
    final byModel = groupByField(logs, 'device.model');
    expect(byModel.where((g) => g.value != null).map((g) => g.value).toSet(), {'iPhone 17', 'iPhone 16'});
    expect(byModel.last.value, isNull);
    expect(byModel.last.count, 2);
    expect(groupByField(logs, 'service.name').single.value, 'keyo_ios');
  });
}
