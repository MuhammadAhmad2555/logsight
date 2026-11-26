# AppTrack (Swift)

Send logs, API requests, errors and product events from iOS 14+ / macOS 11+ apps to LogSight.
Foundation and URLSession only, with no dependencies. It speaks the same wire protocol as the Dart SDK (`packages/apptrack_logger`).

## Install (Swift Package Manager)

Local checkout, in Xcode: *File › Add Package Dependencies… › Add Local…* and pick `packages/apptrack_swift`. In `Package.swift`:

```swift
.package(path: "../apptrack/packages/apptrack_swift")
// target: .product(name: "AppTrack", package: "AppTrack")
```

From git: SwiftPM only reads a `Package.swift` at the **repository root**, so a package in a subdirectory can't be added by git URL. Either publish `packages/apptrack_swift` as its own repository (or a mirror/subtree split) and add that URL, or use a local path as shown above.

## Setup

```swift
import AppTrack

let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

let appTrack = AppTrackLogger(
    firebaseProjectId: "your-firebase-project",
    projectId: "your-project-id",
    ingestKey: "your-ingest-key",
    service: "my_ios_app",                       // [A-Za-z0-9._-], ≤ 100 chars
    defaultAttributes: ["app.version": "1.4.0", "env": "prod"],
    queueFileURL: support.appendingPathComponent("apptrack_queue.jsonl"),
    distinctId: UserDefaults.standard.string(forKey: "apptrack.distinctId")
)
UserDefaults.standard.set(appTrack.distinctId, forKey: "apptrack.distinctId")
appTrack.installCrashHandler()
```

Other options and their defaults: `minLevel: .trace`, `batchSize: 50`, `flushInterval: 5` (seconds), `maxQueue: 5000`, `retentionDays: 90`, `printToConsole: false`, `flushOnBackground: true`.
Every method is thread-safe and never throws. Logs go out in batches on a timer, or as soon as `batchSize` are queued. You can also call `await appTrack.flush()`, for example when the app moves to the background. `await appTrack.close()` flushes and stops the logger.

## Logs

```swift
appTrack.info("User signed in", attributes: ["plan": "pro", "seats": 3])
appTrack.warn("Slow response", attributes: ["ms": 2300], traceId: traceId)
appTrack.userId = "u_123"        // attached to every following log
appTrack.sessionId = "s_456"
```

Levels: `trace`, `debug`, `info`, `warn`, `error`, `fatal`. Each log allows at most 64 attributes and messages are cut at 10,000 characters. Attribute values can be strings, numbers, bools, `Date`, arrays, dictionaries or nil. Any other value is sent as its `String(describing:)`.

## Errors and crashes

```swift
do { try purchase() } catch {
    appTrack.error("Purchase failed", error: error, reason: "Store returned no receipt")
    // or: appTrack.recordError(error)   // adds error.handled = true
}
```

`error` and `fatal` logs carry an `error` map with these fields:

| Field | Content | Limit |
|---|---|---|
| `type` | Swift type name | 200 |
| `message` | `String(describing: error)` | 4000 |
| `reason` | the `reason` you pass | 4000 |
| `stack` | `Thread.callStackSymbols` unless you pass `stackTrace` | 16000 |

`installCrashHandler()` sets `NSSetUncaughtExceptionHandler`, and any handler that was installed before still runs. It records an uncaught Objective-C `NSException` as a `fatal` log with `error.handled = false` and `error.mechanism = "NSUncaughtExceptionHandler"`. The process is about to die, so the log is written **synchronously to the queue file** and sent on the next launch. That means it needs `queueFileURL`.

**Limitation:** pure-Swift traps (`fatalError`, force-unwrapping nil, array out of bounds, integer overflow) are **not captured**. They end the process with a signal (SIGTRAP or SIGILL), not an exception. Handling a signal safely only allows async-signal-safe code: no allocation, no locks, no Foundation, no JSON. Writing a proper log record from a signal handler can therefore deadlock or corrupt the app, so this SDK doesn't install signal handlers. To capture those crashes, use MetricKit (`MXCrashDiagnostic`) or a dedicated crash reporter.

## API requests

```swift
let start = Date()
let (_, response) = try await URLSession.shared.data(for: request)
appTrack.request(method: "GET", route: "/api/orders/:id",
                 statusCode: (response as? HTTPURLResponse)?.statusCode,
                 duration: Date().timeIntervalSince(start))
```

Pass the route pattern, not the full URL. The log message has the form `GET /api/orders/:id 200 (123 ms)`. The log gets `http.method`, `http.route`, `http.status_code` and `duration_ms` (rounded to 0.1). The severity depends on the outcome:

- 5xx, or an `error:` with no status, is logged as `error`.
- 4xx is logged as `warn`.
- Anything else is logged as `info`.

## Background flush

With `flushOnBackground: true` (the default), the logger flushes when the app leaves the foreground:

- **iOS, iPadOS, tvOS and Mac Catalyst** use `UIApplication.didEnterBackgroundNotification`. The flush runs inside `beginBackgroundTask`/`endBackgroundTask`, so the system lets the send finish.
- **macOS (AppKit)** uses `NSApplication.willResignActiveNotification`. There is no background task, because macOS apps keep running.

## Events

```swift
appTrack.capture("purchase_completed", properties: ["plan": "pro", "amount": 9.99])  // ≤ 128 properties
appTrack.capture("purchase_completed", properties: ["plan": "pro"], id: transaction.id) // stored once per id
appTrack.screen("Checkout")                                // $screen with $screen_name
appTrack.identify("u_123", properties: ["email": "a@b.c"]) // $identify; links the anon ID
appTrack.setPersonProperties(["plan": "pro"])
appTrack.reset()                                           // on sign-out: new anon_ ID
```

## Queue file

With `queueFileURL` set, the SDK also keeps queued logs and events in a JSON-lines journal on disk. Unsent items survive the app being killed, crashing or going offline. They are restored and sent on the next launch, and `restored` tells you how many came back. A line cut short by a crash is skipped. The file is emptied once everything is sent and compacted when it grows past 1 MB. If more than `maxQueue` items are waiting, the newest are kept.

Failed sends (network errors, 5xx, 409 `ABORTED`) are retried with exponential backoff (2, 4, 8, … up to 300 s).

## No duplicates

Each log and event gets its Firestore document ID when it is queued. The ID is kept in the queue file, so it survives restarts, and every retry reuses it. Writes are made with `currentDocument.exists = false`, so if a reply was lost and the batch is sent again, Firestore answers `409 ALREADY_EXISTS` instead of storing a second copy. How the SDK handles each reply:

- **200:** every item in the batch was delivered.
- **409 with `error.status == "ALREADY_EXISTS"`:** for a single item, it counts as delivered and is added to `duplicates`. For a batch, the SDK resends each item in its own commit, because a commit is all-or-nothing, so new items still get stored and the old ones count as `duplicates`.
- **400 or 403 (bad data or a disabled key):** for a batch, the SDK also resends one at a time, so only the bad items are dropped and counted in `dropped`.
- **409 `ABORTED` (contention), network errors and 5xx:** retried later with backoff and never counted as delivered.

A network error or 5xx during the one-at-a-time resend stops it. The items not yet sent stay queued and are retried with backoff.

Custom IDs: pass `id:` to `capture`, `log`, `trace`…`fatal`. A custom ID makes a log or event idempotent: sending the same `id` twice stores it once, for example a purchase's transaction ID. A valid ID has these properties:

- 1–200 characters.
- No `/`.
- Not `.` or `..`.
- Not of the form `__…__`.

An invalid ID is silently replaced by a random 20-character one.

## Retention (`expireAt`)

Every log gets `expireAt = ts + retentionDays` (default 90, clamped to the server's allowed 1–400 days, nudged 1 s inward so rounding never crosses a limit), and the server uses it to delete old logs. Pass `retentionDays: nil` to omit the field. Events don't carry `expireAt`.
