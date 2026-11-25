# Keyo → LogSight: new project + text-file logging

Paste this into the Claude session that works on Keyo
(`/Users/muhammad.ahmad/StudioProjects/Keyo`).

## 1. Switch to the new LogSight project

Verified: a live test log with these values returned HTTP 200.

In `dart_defines.json` (gitignored), replace the old values:

```
APPTRACK_PROJECT_ID=<YOUR_LOGSIGHT_PROJECT_ID>
APPTRACK_INGEST_KEY=<YOUR_INGEST_KEY>
```

`firebaseProjectId` stays `apptrack-logs-bs9n0` and `service` stays `keyo_ios`.
AppTrack was renamed LogSight, but the SDK package and class names
(`apptrack_logger`, `AppTrackLogger`) are unchanged.

## 2. ~~Text-file logging~~ (cancelled)

The user does not want Keyo to write a text log file. That was meant for
the LogSight app itself. Don't add `logFilePath`, path_provider or the
file-sharing Info.plist keys to Keyo.
