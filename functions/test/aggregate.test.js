const test = require('node:test');
const assert = require('node:assert');
const path = require('node:path');
const fs = require('node:fs');
const {
  patternOf,
  issueFingerprint,
  parseSeverity,
  endpointOf,
  latencyBucket,
  computeDeltas,
  mergeIssue,
  mergeStats,
  MAX_USERS,
} = require('../aggregate');

// Generated from the Dart code (lib/core/patterns.dart); test/fingerprint_fixture_test.dart
// checks the same file, so server and app always agree on fingerprints.
const fixtures = JSON.parse(fs.readFileSync(path.join(__dirname, '../../test/fixtures/fingerprints.json'), 'utf8'));

test('patterns and fingerprints match the Dart implementation', () => {
  for (const f of fixtures) {
    assert.equal(patternOf(f.message), f.pattern, f.message);
    assert.equal(issueFingerprint(f.service, f.message, f.type), f.fingerprint, f.message);
  }
});

test('severity parsing matches Severity.parse', () => {
  assert.equal(parseSeverity('ERROR'), 'error');
  assert.equal(parseSeverity('warning'), 'warn');
  assert.equal(parseSeverity('critical'), 'fatal');
  assert.equal(parseSeverity(undefined), 'info');
});

const t0 = new Date('2026-11-26T10:15:00Z');
const log = (id, data) => ({ pid: 'p1', id, data: { service: 'api', ts: t0, tokens: [], attributes: {}, ...data } });

test('request logs become endpoint facts', () => {
  const d = {
    service: 'api',
    tokens: ['http_request', 'get'],
    attributes: { 'http.method': 'get', http: { route: '/orders/:id' }, 'http.status_code': '503', duration_ms: 120 },
  };
  const ep = endpointOf(d, 'info');
  assert.equal(ep.method, 'GET');
  assert.equal(ep.route, '/orders/:id');
  assert.equal(ep.routeKey, 'http.route');
  assert.equal(ep.e5, 1);
  assert.equal(ep.duration, 120);
  // Not a request log without the token, or without a route.
  assert.equal(endpointOf({ ...d, tokens: [] }, 'info'), null);
  assert.equal(endpointOf({ ...d, attributes: {} }, 'info'), null);
  // No status: error severity counts as a server error.
  assert.equal(endpointOf({ ...d, attributes: { route: '/x' } }, 'error').e5, 1);
  assert.equal(endpointOf({ ...d, attributes: { route: '/x', status: 404 } }, 'error').e4, 1);
});

test('latency buckets', () => {
  assert.equal(latencyBucket(0), 0);
  assert.equal(latencyBucket(1), 0);
  assert.equal(latencyBucket(1.5), 1);
  assert.equal(latencyBucket(120), 7);
  assert.equal(latencyBucket(999999), 18);
});

test('computeDeltas groups errors into issues and hour/day buckets', () => {
  const later = new Date('2026-11-26T11:05:00Z');
  const { issues, stats } = computeDeltas([
    log('a', { severity: 'error', message: 'Payment failed for order 1', userId: 'u1' }),
    log('b', { severity: 'fatal', message: 'Payment failed for order 2', userId: 'u2', ts: later }),
    log('c', { severity: 'info', message: 'hello' }), // ignored
    log('d', { severity: 'error', message: 'Other thing' }),
  ]);
  assert.equal(issues.size, 2);
  const pay = [...issues.values()].find((i) => i.pattern === 'Payment failed for order <num>');
  assert.equal(pay.count, 2);
  assert.deepEqual([...pay.users], ['u1', 'u2']);
  assert.equal(pay.latest.logId, 'b');
  assert.equal(pay.lastSeen.getTime(), later.getTime());
  // Two hours + one day.
  assert.deepEqual([...stats.keys()].sort(), ['p1/statsDaily/20261126', 'p1/statsHourly/2026112610', 'p1/statsHourly/2026112611']);
  assert.equal(stats.get('p1/statsDaily/20261126').issues[pay.fp], 2);
});

test('mergeIssue adds counts, keeps the earliest/latest and caps users', () => {
  const fp = issueFingerprint('api', 'x', null);
  const delta = {
    pid: 'p1', fp, service: 'api', pattern: 'x', errorType: 'E', count: 3,
    firstSeen: new Date('2026-11-26T10:00:00Z'), lastSeen: new Date('2026-11-26T12:00:00Z'),
    latest: { logId: 'new' }, users: new Set(['u1', 'u2']),
  };
  const prev = {
    count: 5, firstSeen: new Date('2026-11-20T00:00:00Z'), lastSeen: new Date('2026-11-26T13:00:00Z'),
    latest: { logId: 'old' }, errorType: 'Old', users: ['u1'],
  };
  const m = mergeIssue(prev, delta);
  assert.equal(m.count, 8);
  assert.equal(m.firstSeen.toISOString(), '2026-11-20T00:00:00.000Z');
  assert.equal(m.lastSeen.toISOString(), '2026-11-26T13:00:00.000Z'); // late batch doesn't move it back
  assert.equal(m.latest.logId, 'old');
  assert.deepEqual(m.users.sort(), ['u1', 'u2']);

  const many = mergeIssue({ users: Array.from({ length: MAX_USERS }, (_, i) => `x${i}`) }, delta);
  assert.equal(many.users.length, MAX_USERS);
  assert.equal(many.usersCapped, true);
});

test('mergeStats adds issue and endpoint totals', () => {
  const d = {
    service: 'api', severity: 'info', tokens: ['http_request'],
    attributes: { method: 'GET', route: '/a', status: 200, duration_ms: 40 },
  };
  const first = computeDeltas([log('a', d), log('b', { ...d, attributes: { ...d.attributes, status: 500, duration_ms: 400 } })]);
  const hour = first.stats.get('p1/statsHourly/2026112610');
  const stored = mergeStats(null, hour);
  const again = mergeStats(stored, hour);
  const [ep] = Object.values(again.endpoints);
  assert.equal(ep.c, 4);
  assert.equal(ep.e5, 2);
  assert.equal(ep.dn, 4);
  assert.equal(ep.ds, 880);
  assert.equal(ep.h.reduce((a, b) => a + b, 0), 4);
});
