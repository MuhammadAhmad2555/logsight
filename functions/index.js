// LogSight Cloud Functions (need the Firebase Blaze plan):
//  - checkAlerts: see below.
//  - aggregateLogs: keeps issue and endpoint totals (aggregator.js).
//
// Alerts checker. Runs every 5 minutes, evaluates every enabled
// alert rule (projects/{pid}/alerts/{id}), and when a rule starts or stops
// firing it records an event (projects/{pid}/alertEvents) and calls the
// rule's webhook.
const { onSchedule } = require('firebase-functions/v2/scheduler');
const logger = require('firebase-functions/logger');
const { initializeApp } = require('firebase-admin/app');
const { getFirestore, Timestamp, FieldValue } = require('firebase-admin/firestore');
const { isFiring, countSpec, webhookBody, safeWebhookUrl } = require('./alerts');
const { runAggregation, pruneStats } = require('./aggregator');

initializeApp();

async function countLogs(db, pid, spec, now) {
  let q = db
    .collection('projects').doc(pid).collection('logs')
    .where('ts', '>=', Timestamp.fromMillis(now.getTime() - spec.windowMinutes * 60_000));
  if (spec.service) q = q.where('service', '==', spec.service);
  if (spec.severities) q = q.where('severity', 'in', spec.severities);
  const agg = await q.orderBy('ts', 'desc').count().get();
  return agg.data().count;
}

async function callWebhook(url, body) {
  if (!safeWebhookUrl(url)) return 'blocked';
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(10_000),
      redirect: 'error',
    });
    return String(res.status);
  } catch (e) {
    logger.warn('Webhook failed', { error: String(e) });
    return 'error';
  }
}

exports.checkAlerts = onSchedule(
  { schedule: 'every 5 minutes', timeoutSeconds: 240, memory: '256MiB', retryCount: 0 },
  async () => {
    const db = getFirestore();
    const now = new Date();
    const rules = await db.collectionGroup('alerts').get();
    const projectNames = new Map();

    for (const doc of rules.docs) {
      const rule = { id: doc.id, ...doc.data() };
      if (!rule.enabled) continue;
      const projectRef = doc.ref.parent.parent;
      if (!projectRef) continue;
      const pid = projectRef.id;
      try {
        const value = await countLogs(db, pid, countSpec(rule), now);
        const firing = isFiring(rule, value);
        const update = { lastCheckedAt: FieldValue.serverTimestamp(), lastValue: value, firing };

        if (firing !== Boolean(rule.firing)) {
          const state = firing ? 'firing' : 'resolved';
          if (firing) update.lastTriggeredAt = FieldValue.serverTimestamp();
          if (!projectNames.has(pid)) {
            const p = await projectRef.get();
            projectNames.set(pid, p.get('name') || pid);
          }
          let webhookStatus = null;
          if (rule.webhookUrl) {
            webhookStatus = await callWebhook(
              rule.webhookUrl,
              webhookBody(rule.webhookUrl, { rule, state, value, projectName: projectNames.get(pid), projectId: pid, at: now }),
            );
          }
          await projectRef.collection('alertEvents').add({
            alertId: rule.id,
            alertName: rule.name,
            state,
            value,
            webhookStatus,
            at: FieldValue.serverTimestamp(),
          });
          logger.info('Alert state changed', { pid, alert: rule.id, state, value, webhookStatus });
        }
        await doc.ref.update(update);
      } catch (e) {
        logger.error('Alert check failed', { pid, alert: rule.id, error: String(e) });
      }
    }
  },
);

// Log aggregator: keeps issueStats, statsHourly and statsDaily up to date
// (see aggregator.js). Every minute; the first runs backfill existing logs.
exports.aggregateLogs = onSchedule(
  { schedule: 'every 1 minutes', timeoutSeconds: 60, memory: '512MiB', retryCount: 0, maxInstances: 1 },
  async () => {
    const db = getFirestore();
    const started = Date.now();
    let total = 0;
    try {
      total = await runAggregation(db);
    } catch (e) {
      if (String(e.message) !== 'cursor-moved') logger.error('Aggregation failed', { error: String(e) });
    }
    if (total) logger.info('Aggregated logs', { total, ms: Date.now() - started });
    if (new Date().getUTCMinutes() === 7) {
      try {
        await pruneStats(db);
      } catch (e) {
        logger.warn('Pruning stats failed', { error: String(e) });
      }
    }
  },
);
