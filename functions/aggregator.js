const { Timestamp, FieldValue, FieldPath } = require('firebase-admin/firestore');
const { computeDeltas, mergeIssue, mergeStats } = require('./aggregate');

// Log aggregator runtime (Firestore reads/writes). The pure logic is in
// aggregate.js; index.js runs this every minute.
//
// Keeps running totals so the app doesn't have to count thousands of logs:
// issueStats (one doc per error issue), statsHourly and statsDaily (error
// counts per issue and request stats per endpoint). See aggregate.js.
//
// Runs every minute and reads logs that reached the server since the last
// run, in `receivedAt` order. Totals and the position reached are saved in one
// transaction, so a crash or an overlapping run can't count a log twice. On
// the first run it works through every existing log (a backfill), a few
// thousand per minute.

const CURSOR = '_system/logAggregator';
const LAG_MS = 30_000; // let in-flight writes land before reading past them
const PAGE = 400; // logs per transaction
const MAX_TOUCHED = 450; // docs written per transaction (limit is 500)
const RUN_BUDGET_MS = 45_000;
const HOURLY_KEEP_DAYS = 10;
const DAILY_KEEP_DAYS = 400;

function logFromDoc(d) {
  const data = d.data();
  const pid = d.ref.parent.parent?.id;
  if (!pid || d.ref.parent.parent.parent.id !== 'projects') return null;
  return {
    pid,
    id: d.id,
    data: { ...data, ts: data.ts?.toDate?.() ?? null },
  };
}

function toFirestore(value) {
  if (value instanceof Timestamp) return value;
  if (value instanceof Date) return Timestamp.fromDate(value);
  if (Array.isArray(value)) return value.map(toFirestore);
  if (value && typeof value === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(value)) out[k] = toFirestore(v);
    return out;
  }
  return value;
}

/** Processes one page of logs. Returns how many logs it consumed (0 = caught up). */
async function aggregatePage(db, upTo) {
  const cursorRef = db.doc(CURSOR);
  const cursor = (await cursorRef.get()).data() || {};

  let q = db
    .collectionGroup('logs')
    .where('receivedAt', '<=', upTo)
    .orderBy('receivedAt')
    .orderBy(FieldPath.documentId())
    .limit(PAGE);
  if (cursor.receivedAt && cursor.path) q = q.startAfter(cursor.receivedAt, cursor.path);
  const snap = await q.get();
  if (snap.empty) return 0;

  // Take fewer logs if they would touch too many docs for one transaction.
  let docs = snap.docs;
  let deltas;
  for (;;) {
    deltas = computeDeltas(docs.map(logFromDoc).filter(Boolean));
    if (deltas.issues.size + deltas.stats.size <= MAX_TOUCHED || docs.length === 1) break;
    docs = docs.slice(0, Math.ceil(docs.length / 2));
  }
  const last = docs[docs.length - 1];

  await db.runTransaction(async (tx) => {
    const issueRefs = [...deltas.issues.values()].map((d) => db.doc(`projects/${d.pid}/issueStats/${d.fp}`));
    const statsRefs = [...deltas.stats.values()].map((d) => db.doc(`projects/${d.pid}/${d.coll}/${d.id}`));
    const [cur, ...existing] = await tx.getAll(cursorRef, ...issueRefs, ...statsRefs);

    // Another run moved on since we read the cursor: drop this page.
    const now = cur.data() || {};
    if ((now.path || null) !== (cursor.path || null)) throw new Error('cursor-moved');

    const issueSnaps = existing.slice(0, issueRefs.length);
    const statsSnaps = existing.slice(issueRefs.length);
    [...deltas.issues.values()].forEach((delta, i) => {
      const doc = mergeIssue(issueSnaps[i].exists ? issueSnaps[i].data() : null, delta);
      tx.set(issueRefs[i], toFirestore({ ...doc, updatedAt: new Date() }));
    });
    [...deltas.stats.values()].forEach((delta, i) => {
      const doc = mergeStats(statsSnaps[i].exists ? statsSnaps[i].data() : null, delta);
      tx.set(statsRefs[i], toFirestore(doc));
    });
    tx.set(cursorRef, {
      receivedAt: last.get('receivedAt'),
      path: last.ref.path,
      processed: FieldValue.increment(docs.length),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  });
  return docs.length;
}

/** Deletes hourly totals older than 10 days and daily totals older than 400. */
async function pruneStats(db) {
  const projects = await db.collection('projects').select().get();
  for (const p of projects.docs) {
    for (const [coll, days] of [['statsHourly', HOURLY_KEEP_DAYS], ['statsDaily', DAILY_KEEP_DAYS]]) {
      const old = await p.ref
        .collection(coll)
        .where('t', '<', Timestamp.fromMillis(Date.now() - days * 86_400_000))
        .limit(400)
        .get();
      if (old.empty) continue;
      const batch = db.batch();
      old.docs.forEach((d) => batch.delete(d.ref));
      await batch.commit();
    }
  }
}


/** Aggregates until caught up or [budgetMs] has passed. Returns logs processed. */
async function runAggregation(db, { budgetMs = RUN_BUDGET_MS, lagMs = LAG_MS, now = Date.now() } = {}) {
  const started = Date.now();
  const upTo = Timestamp.fromMillis(now - lagMs);
  let total = 0;
  while (Date.now() - started < budgetMs) {
    const n = await aggregatePage(db, upTo);
    total += n;
    if (n === 0) break;
  }
  return total;
}

module.exports = { runAggregation, aggregatePage, pruneStats, CURSOR };
