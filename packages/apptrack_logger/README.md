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
