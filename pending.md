# Pending: features that need the Firebase Blaze plan

LogSight runs on the free **Spark** plan, which can't deploy Cloud Functions
(Google requires a billing account for any server code). Everything below needs
server code, so it's on hold until LogSight has users and revenue.

Last updated: 2026-11-26.

## Before starting any of this

1. Upgrade `apptrack-logs-bs9n0` to Blaze:
   https://console.firebase.google.com/project/apptrack-logs-bs9n0/usage/details
2. Set a budget alert in Google Cloud Billing (e.g. $5/month) so cost surprises email you.
3. Deploy in this order: `firebase deploy --only firestore`, then `--only functions`, then the web app.

Blaze keeps Spark's free allowance (2M function runs, 50k reads/day, 20k writes/day),
so at low volume it's expected to cost $0–2/month.

Alternative if a Google billing account isn't wanted: run the same jobs on a
Cloudflare Worker with a Cron Trigger (Workers Paid, $5/month, because the free
plan's 10 ms CPU limit is too low), using Firestore's REST API and a service
account key as a Worker secret. Needs the function code ported.

---

## 1. Exact Issues, Overview and Endpoints totals (built, not deployed)

**Today:** the browser counts a sample: Issues use up to 2,000 errors,
Overview's top issues 1,000, Endpoints 3,000 requests. Busy projects get
counts that are too low and older issues drop off.

**Ready in the repo:**
- `functions/aggregate.js`: pure logic (fingerprints, endpoints, merging), a port of the Dart code.
- `functions/aggregator.js`: the runtime. Reads logs by `receivedAt` and keeps
  `issueStats/{fp}`, `statsHourly/*`, `statsDaily/*`. Totals and position are saved
  in one transaction (no double counting); the first runs backfill history.
- `functions/index.js`: `aggregateLogs`, scheduled every minute.
- Tests: `cd functions && npm test` (unit) and `npm run test:emulator` (Firestore emulator).
- `test/fixtures/fingerprints.json` + `test/fingerprint_fixture_test.dart`:
  keep the Dart and JS fingerprints identical. Run both if `lib/core/patterns.dart` changes.

**Already deployed (harmless on their own):** read-only rules for `issueStats`,
`statsHourly`, `statsDaily`; index exemptions for their map fields; a
collection-group index on `logs.receivedAt`.

**Still to do once on Blaze:**
- Restore the app side. It was written and then removed so the app keeps working
  on Spark. It's in this session's history (AgentShare session "Server-side
  aggregation for exact Issues/Overview/Endpoints"):
  - `lib/data/stats.dart`: `StatsRepository`, `IssueSummary`, `EndpointTotals`,
    histogram percentiles, `BucketPlan` (daily docs for whole days, hourly for edges).
  - Issues and Overview read `issueStats` + range counts; Endpoints uses totals for ranges ≥ 3 h.
  - Help text and README updates.
- Note: logs written before `receivedAt` was required aren't backfilled; deleting
  logs doesn't lower totals.

## 2. Alerts (built, never ran)

The Alerts page exists and rules can be saved, but `checkAlerts`
(`functions/index.js`, every 5 minutes) was never deployed, so **alerts never fire**.
The page already says it needs Blaze. Deploying the functions turns it on; nothing else to build.

## 3. New and regressed issue alerts

Message Slack or a webhook within about a minute when an issue is seen for the first
time, or a resolved issue comes back.
- Build on `aggregateLogs`: it already sees an issue's first error and errors after `resolvedAt`.
- Add a toggle and webhook to the Alerts page; record events in `alertEvents`.

## 4. Notifications

- Email (e.g. via a transactional email API) and mobile push for alerts.
- Daily/weekly digest: new issues, error rate, top endpoints.

## 5. Ingest protection

A leaked ingest key lets anyone write logs. Rules can check one log but can't count.
- Per-key rate limits, auto-disable a key on abuse, reject unknown services.
- Optionally Firebase App Check on the ingest path.

## 6. Retention

- Per-project "delete logs older than N days" as a nightly job (today an admin
  does it by hand). Firestore TTL policies (no server needed) are an option for a
  fixed project-wide period.
- Pruning old `statsHourly` / `statsDaily` is already in `aggregator.js`.

## 7. Readable stack traces

Decode obfuscated release stack traces (Flutter `--split-debug-info`, iOS dSYM,
Android R8 mapping). Needs symbol upload from CI and server-side processing.

## 8. Integrations

Create Jira / Linear / GitHub issues from LogSight issues; Slack app with
interactive buttons (resolve / ignore). Secrets must live on a server.

## 9. Product analytics at scale

Funnels, retention and trends can start in the browser on a sample (no Blaze
needed), but exact results over months of data need server-side totals
(extend `aggregateLogs` to events) or a BigQuery export.

## 10. Ads: attribution and campaigns

Meta / Google Ads / TikTok / Apple Search Ads, AppsFlyer-style attribution.
All of it needs a server: storing ad-account OAuth tokens, importing spend,
sending conversions back (Meta Conversions API, Google Ads conversion upload),
tracking-link redirects and install matching.

Suggested order: tracking links + install attribution → send conversions back
→ import spend and show ROAS → pause campaigns / change budgets. Leave campaign
creation for last.

Apply early for Meta Marketing API (business verification + app review for
`ads_management`) and a Google Ads API developer token (Basic/Standard access);
approvals take weeks.

---

## Suggested order once on Blaze

1. Deploy functions (turns on Alerts and the aggregator); restore the app side of item 1.
2. New / regressed issue alerts (3).
3. Ingest protection (5) and retention (6).
4. Funnels and retention analytics (9).
5. Ads (10).
