// Runs the aggregator against the Firestore emulator:
//   npm run test:emulator
// Checks exact totals across pages, tied receivedAt values, late logs,
// re-runs and two runs at once.
const test = require('node:test');
const assert = require('node:assert');
const { initializeApp } = require('firebase-admin/app');
const { getFirestore, Timestamp } = require('firebase-admin/firestore');
const { runAggregation, CURSOR } = require('../../aggregator');
const { issueFingerprint } = require('../../aggregate');

assert.ok(process.env.FIRESTORE_EMULATOR_HOST, 'run with the Firestore emulator (npm run test:emulator)');
initializeApp({ projectId: 'demo-logsight' });
const db = getFirestore();

const base = Date.parse('2026-11-26T10:00:00Z');
let seq = 0;

async function seed(pid, logs) {
  for (let i = 0; i < logs.length; i += 400) {
    const batch = db.batch();
    for (const l of logs.slice(i, i + 400)) {
      batch.set(db.collection(`projects/${pid}/logs`).doc(`l${String(seq++).padStart(6, '0')}`), {
        service: 'api',
        severity: 'info',
        message: 'hello',
        tokens: [],
        attributes: {},
        key: 'k',
        ...l,
        ts: Timestamp.fromMillis(l.ts),
        receivedAt: Timestamp.fromMillis(l.receivedAt),
      });
    }
    await batch.commit();
  }
}

const err = (n, receivedAt, extra = {}) => ({
  severity: 'error',
  message: `Payment failed for order ${n}`,
  userId: `u${n % 7}`,
  ts: base + n * 1000,
  receivedAt,
  ...extra,
});
const req = (n, receivedAt, status = 200, extra = {}) => ({
  tokens: ['http_request'],
  attributes: { 'http.method': 'GET', 'http.route': '/orders/:id', 'http.status_code': status, duration_ms: 50 + (n % 10) },
  ts: base + n * 1000,
  receivedAt,
  ...extra,
});

async function issue(pid, fp) {
  return (await db.doc(`projects/${pid}/issueStats/${fp}`).get()).data();
}
async function hourly(pid, id) {
  return (await db.doc(`projects/${pid}/statsHourly/${id}`).get()).data();
}

const fpPay = issueFingerprint('api', 'Payment failed for order 1', null);
const opts = { lagMs: 0, now: base + 10 * 3600_000 };

test('backfill across pages with tied receivedAt counts every log once', async () => {
  // 450 logs share one receivedAt (one SDK batch), so the page boundary falls
  // inside the tie; plus noise that adds nothing.
  const tied = base + 60_000;
  const logs = [];
  for (let i = 0; i < 450; i++) logs.push(err(i, tied));
  for (let i = 0; i < 300; i++) logs.push(req(i, tied + 1000 + i, i % 10 === 0 ? 503 : 200));
  for (let i = 0; i < 300; i++) logs.push({ ts: base + i, receivedAt: tied + 2000 + i }); // info
  await seed('p1', logs);
  await seed('p2', [err(1, tied), err(2, tied)]);

  const n = await runAggregation(db, opts);
  assert.equal(n, 1052);

  const pay = await issue('p1', fpPay);
  assert.equal(pay.count, 450);
  assert.equal(pay.users.length, 7);
  assert.equal(pay.pattern, 'Payment failed for order <num>');
  assert.equal((await issue('p2', fpPay)).count, 2);

  // 450 errors at 10:00:00–10:07:29 → hours 10.
  const h10 = await hourly('p1', '2026112610');
  assert.equal(h10.issues[fpPay], 450);
  const [ep] = Object.values(h10.endpoints);
  assert.equal(ep.c, 300);
  assert.equal(ep.e5, 30);
  assert.equal(ep.dn, 300);
  const day = (await db.doc('projects/p1/statsDaily/20261126').get()).data();
  assert.equal(day.issues[fpPay], 450);

  assert.equal(await runAggregation(db, opts), 0, 'nothing new on a second run');
  assert.equal((await issue('p1', fpPay)).count, 450);
});

test('new and late logs are added exactly once, even with two runs at once', async () => {
  const later = base + 3600_000;
  // A late batch: device time 2 hours before it arrived.
  await seed('p1', [
    err(9001, later, { ts: base - 2 * 3600_000 }),
    err(9002, later + 1),
    ...Array.from({ length: 500 }, (_, i) => req(i, later + 10 + i)),
  ]);
  // Overlapping runs: one may stop with 'cursor-moved' (the scheduler logs
  // nothing for that); whatever is left is picked up by the next run.
  const runs = await Promise.allSettled([runAggregation(db, opts), runAggregation(db, opts)]);
  for (const r of runs) if (r.status === 'rejected') assert.equal(r.reason.message, 'cursor-moved');
  await runAggregation(db, opts);

  const pay = await issue('p1', fpPay);
  assert.equal(pay.count, 452);
  assert.equal(pay.firstSeen.toMillis(), base - 2 * 3600_000);
  assert.equal((await hourly('p1', '2026112608')).issues[fpPay], 1); // late log, in its own hour
  const h10 = await hourly('p1', '2026112610');
  assert.equal(Object.values(h10.endpoints)[0].c, 800);

  const cursor = (await db.doc(CURSOR).get()).data();
  assert.equal(cursor.processed, 1052 + 502);
});
