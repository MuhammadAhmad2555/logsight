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
