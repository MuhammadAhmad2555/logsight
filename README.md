# LogSight

<img src="assets/branding/logo_256.png" width="96" alt="LogSight logo">

A log platform in the style of PostHog Logs. Apps send logs; your team signs in
to search, filter and chart them. Built with Flutter, with Firebase as the backend.

**Runs on:** Android, iOS, macOS, Web and Windows (every platform the
FlutterFire plugins support). Linux isn't supported by FlutterFire, so there's
no Linux build of the dashboard. Linux *apps* can still send logs with the SDK.

## Features

| Area | What it does |
|---|---|
| Accounts | Email + password sign-up, email verification, password reset, light/dark theme |
| Projects | Create and switch projects; each project holds one product's logs |
| Team | Invite by email as **Admin** or **Viewer**, change roles, remove members, leave |
| Ingest keys | Create, disable and delete keys; ready-to-paste setup code for Flutter, Swift and curl; “Send test log” |
| Log explorer | Time ranges (15m → 90d or custom), whole-word search, level filter, `service_name =/≠` filters, attribute filters (`=`, `≠`, contains, is set…), volume chart (tap a bar to zoom in), level totals, infinite scroll, live tail |
| Log details | Full message, fields, flattened attributes, “filter by this value”, copy as JSON |
| Shareable views | Every filter is kept in the URL, e.g. `/p/<id>/logs?range=7d&service=keyo_ios&xservice=kyberq_ios&sev=error` |
| Retention | Admins can delete logs older than N days; owners can delete the project |

## Activity (product events and people)

LogSight also records **what users do**, like PostHog's Activity:

| Page | What it shows |
|---|---|
| **Activity** | Live stream of events (`$screen`, `$identify`, your own like `purchase_completed`), with time range, event, person, session, app and property filters, chosen property columns, and event details linking to the person, the session and the logs ±5 min around it |
| **People** | Everyone who sent events, searchable by ID, email, name or any property; each profile shows properties, linked IDs, an activity timeline, sessions and that person's logs and errors |
| **Data management** | Every event name and property seen, with descriptions, a verified badge and 7-day volume |

```dart
appTrack.sessionId = sessionId;                     // optional, groups events into sessions
appTrack.screen('Settings');                        // $screen
appTrack.capture('purchase_completed', properties: {'plan': 'pro', 'amount': 9.99});
appTrack.identify(user.uid, properties: {'email': user.email});   // links the anonymous ID
appTrack.setPersonProperties({'plan': 'pro'});
appTrack.reset();                                   // on sign-out
```

Logs sent after `identify()` carry the same `userId`, so a person's profile shows their logs too.
Persist `appTrack.distinctId` in the app and pass it back as `distinctId:` on the next launch.

Firestore: `projects/{pid}/events`, `persons/{distinctId}` (properties merged, `aliases`,
`firstSeen` in ms, `lastSeen`) and `eventDefs/{name}`. Profile and definition updates are sent in
their own request, so a problem there never drops events or logs.

## How it works

```
 Your apps (iOS, Android, Flutter, servers)           Flutter dashboard (this repo)
        │  HTTPS: Firestore REST commit                     │  Firebase SDK
        │  (ingest key; no login, no Firebase SDK)          │  (signed-in user)
        ▼                                                   ▼
 ┌──────────────────────────── Firebase ──────────────────────────────────┐
 │  Firestore security rules: validate every log, check the key is active,│
 │  enforce owner / admin / viewer roles                                  │
 │  Firestore: projects / ingestKeys / logs / invites                     │
 │  Firebase Auth: dashboard accounts                                     │
 └────────────────────────────────────────────────────────────────────────┘
```

Works on the free **Spark** plan, with no Cloud Functions:

- **Ingestion.** Apps write logs straight to Firestore. The rules check the
  ingest key, the field types and sizes, the severity, and that the timestamp
  falls in the last 7 days. The server sets `receivedAt`. Logs can't be edited.
- **Search.** Firestore has no full-text search, so each log stores the words
  of its message (`tokens`). The first search word runs in Firestore with
  `array-contains`; the other words and other filters run in the app.
- **Charts.** Each bar is a Firestore `count()` query, which costs one read
  per 1,000 logs counted.

### Data model

```
projects/{projectId}       name, ownerId, members{uid: role}, memberIds[], memberEmails{uid: email}
  ingestKeys/{key}         name, active, createdAt, createdBy        (the doc ID is the key)
  logs/{logId}             ts, receivedAt, severity, message, service, key,
                           tokens[], attributes{}, userId?, sessionId?, traceId?
invites/{projectId}_{email}  projectId, projectName, email, role, invitedBy…
```

## Project layout

```
lib/
  core/        theme, severity levels, tokenizer, shared widgets
  data/        models, LogQuery (filters ↔ URL), repositories
  state/       Riverpod providers
  features/    auth, projects, shell (navigation), logs, keys, members, account
packages/apptrack_logger/   Dart SDK for sending logs from any Dart/Flutter app
firestore.rules             security rules
firestore.indexes.json      composite indexes for log queries
```

## Running

```bash
flutter pub get
flutter run -d chrome      # or: macos, windows, an iOS simulator, an Android emulator
```

Firebase project: `apptrack-logs-bs9n0` (config in `lib/firebase_options.dart`).

### Deploying

```bash
firebase deploy --only firestore,auth      # rules, indexes, email sign-in
tool/build_web.sh && firebase deploy --only hosting   # or upload build/web to Cloudflare Pages
```

### Hosting on Cloudflare

**Workers (recommended, what "Connect to Git" creates today):** connect this repo, then in
the Worker's **Settings → Build**:

| Setting | Value |
|---|---|
| Build command | `bash tool/cloudflare_build.sh` |
| Deploy command | `npx wrangler deploy` |

`wrangler.jsonc` serves `build/web` with single-page-app routing, so links like
`/p/<id>/logs` work.

**Pages:** framework preset *None*, build command `bash tool/cloudflare_build.sh`,
output directory `build/web` (Pages handles app links automatically).

The build script installs Flutter 3.44.8, since Cloudflare's build image has none. Then add your
custom domain (e.g. app.arcx9.com) and add the same domain in Firebase → Authentication →
Settings → Authorized domains.

### Testing

```bash
flutter test                                   # filter, search and chart logic
(cd packages/apptrack_logger && dart test)     # SDK batching and retries
```

## Sending logs from an app

Open **Ingest keys** in the dashboard and copy the snippet for your platform.
For Flutter/Dart, use `packages/apptrack_logger`:

```dart
final appTrack = AppTrackLogger(
  firebaseProjectId: 'apptrack-logs-bs9n0',
  projectId: '<project ID>',
  ingestKey: '<key>',
  service: 'keyo_ios',
);
appTrack.error('Payment failed', attributes: {'order_id': 42});

// Optional full error details (error and fatal logs only): the exception's
// type and message, your own reason, and the stack trace.
try {
  await buy();
} catch (e, st) {
  appTrack.error('Purchase failed', error: e, stackTrace: st, reason: 'Backend rejected the receipt');
}
```

## Limits and next steps

- Search matches whole words only (`pay` doesn't match `payment`).
- Attribute filters and `≠` filters run in the app, so one view reads at most
  1,000 logs per page. The chart counts ignore these filters (an ⓘ icon says so).
- At very high volume (millions of logs a day), Firestore costs and query
  limits start to bite. The usual next step is the Blaze plan with a Cloud
  Function ingestion endpoint feeding BigQuery or ClickHouse. The dashboard's
  `LogRepository` is the only code that would need to change.
- Before publishing to the stores, add app icons and signing configs.
