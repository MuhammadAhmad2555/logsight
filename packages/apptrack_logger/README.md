# apptrack_logger

Sends logs from any Dart or Flutter app (Android, iOS, macOS, Windows, Linux,
web, server) to AppTrack. It talks to Firestore's REST API directly, so your
app doesn't need the Firebase SDK or its own Firebase project.

```dart
final appTrack = AppTrackLogger(
  firebaseProjectId: 'apptrack-logs-bs9n0',
  projectId: '<AppTrack project ID>',
  ingestKey: '<ingest key>',
  service: 'keyo_ios',
  defaultAttributes: {'app.version': '2.1.0'},
);

appTrack.info('User signed in', attributes: {'user.plan': 'pro'});
appTrack.error('Payment failed', attributes: {'order_id': 42});
await appTrack.flush(); // before the app exits
```

Logs are queued and sent in batches (every 5 seconds or 50 logs). Failed
batches are retried with backoff. Logs are dropped (oldest first) if more
than 5,000 are waiting, so logging can never use up the app's memory.

## Crashes

Send uncaught errors with their type, message and stack trace. They're logged
as `error` with `error.handled = false` and `error.mechanism` (pass
`fatal: true` to log them as `fatal`). The same error repeating is sent at
most 5 times a minute.

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (details) {
    FlutterError.presentError(details); // keep the console output
    appTrack.recordFlutterError(details);
  };
  PlatformDispatcher.instance.onError = appTrack.recordUncaughtError;

  runApp(const MyApp());
}
```

Without Flutter: `void main() => appTrack.runGuarded(() async { ... });`
logs anything uncaught as `fatal`.

## No duplicates

Every log and event gets its document ID when it's created, and every retry
or re-send after a restart reuses it. The server refuses a second copy, so a
send that timed out after the server stored it doesn't create duplicates
(`duplicates` counts the repeats that were skipped). If one item in a batch is
bad or already stored, the rest are still sent one at a time, so one bad log
never drops the others.

For events that must be counted once, pass your own ID, e.g. the store's
transaction ID. Events (or logs) with the same ID are stored once:

```dart
appTrack.capture('purchase_completed', id: purchase.transactionId, properties: {'amount': 9.99});
appTrack.log(LogLevel.info, 'Receipt validated', id: 'receipt-${purchase.transactionId}');
```

IDs must be 1–200 characters without `/`; anything else falls back to a
generated ID.

## Sending before the app is suspended

Flush when the app goes to the background so queued logs leave before the OS
suspends it:

```dart
final lifecycle = AppLifecycleListener(onHide: appTrack.flush);
```

## Keeping unsent logs on disk

Set `queueFilePath` and logs and events not sent yet are also kept in that
file, so they survive the app being killed, crashing or going offline, and
are sent on the next launch (`restored` says how many). Ignored on the web.

```dart
final dir = await getApplicationSupportDirectory(); // path_provider
final appTrack = AppTrackLogger(
  // ...
  queueFilePath: '${dir.path}/apptrack_queue.jsonl',
);
```

## API requests (Endpoints page)

Log each API call your app makes (or your server handles). The dashboard's
**Endpoints** page shows calls, error rate and p50/p95 latency per route.

```dart
final sw = Stopwatch()..start();
final res = await http.get(uri);
appTrack.request('GET', '/api/orders/:id', statusCode: res.statusCode, duration: sw.elapsed);
```

Use the route pattern (`/api/orders/:id`), not the full URL, so calls group
together. 5xx responses are logged as errors, 4xx as warnings.

## Feature flags

Create flags in the dashboard (**Feature flags**), then:

```dart
await appTrack.reloadFeatureFlags();      // at startup and e.g. on resume

if (appTrack.isFeatureEnabled('new-checkout')) {
  showNewCheckout();
}
```

- Flags not loaded yet (or unknown) return `fallback` (default `false`).
- Rollout percentages use a stable hash of `flagKey.distinctId`, so a person
  stays in or out as you raise the percentage.
- Conditions are checked against the properties passed to `identify()` and
  `setPersonProperties()`, plus any `properties:` passed to
  `isFeatureEnabled`.
- Flags are readable without signing in (like PostHog's public flag API), so
  don't put secrets in them.
