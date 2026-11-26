# apptrack-kotlin

Send logs, request metrics, crashes and product events from Android apps and
JVM servers to LogSight. Pure Kotlin/JVM (Java 8 bytecode), no Android or
third-party runtime dependencies besides the Kotlin standard library: HTTP via
`java.net.HttpURLConnection`, a small built-in JSON encoder.

Same wire format and behaviour as the Dart package (`packages/apptrack_logger`):
apps write straight to Firestore's REST `documents:commit` endpoint with an
ingest key, and the project's security rules validate every write.

## Install

Pick one:

- **Gradle composite build** (in your app's `settings.gradle.kts`):
  ```kotlin
  includeBuild("../apptrack/packages/apptrack_kotlin")
  ```
  then `implementation("com.logsight:apptrack-kotlin:0.1.0")`.
- **Copy the module**: copy `src/main/kotlin/com/logsight/apptrack/` into your
  project (5 files).
- **JitPack**: once this repo is public, JitPack can build it from a git tag
  (`com.github.<owner>.<repo>:apptrack-kotlin:<tag>`); it needs a `jitpack.yml`
  pointing at this subdirectory. Not set up yet.

Tests: `gradle test` (JUnit 5).

## Setup

```kotlin
val appTrack = AppTrackLogger(
    firebaseProjectId = "your-firebase-project",
    projectId = "your-logsight-project-id",
    ingestKey = "your-ingest-key",
    service = "myapp_android",                 // shown as service_name
    defaultAttributes = mapOf("app.version" to BuildConfig.VERSION_NAME),
    queueFile = File(context.filesDir, "apptrack_queue.jsonl"), // Android
)
appTrack.installCrashHandler()
```

Create one logger per process (e.g. in `Application.onCreate`) and keep it.
Options: `minLevel`, `batchSize` (50), `flushIntervalMs` (5000), `maxQueue`
(5000), `retentionDays` (90), `printToConsole`, `distinctId`, `transport`
(your own `HttpTransport`, e.g. OkHttp), `baseUrl` (Firestore emulator).

On Android the app needs `<uses-permission android:name="android.permission.INTERNET"/>`.
On a server call `appTrack.close()` on shutdown (e.g. in a shutdown hook):
the sender thread is a daemon and does not keep the JVM alive.

## Logs

```kotlin
appTrack.info("Checkout opened", mapOf("cart_items" to 3))
appTrack.warn("Slow response", mapOf("ms" to 2300), traceId = traceId)
appTrack.userId = "user-42"      // attached to every log
appTrack.sessionId = "sess-1"
```

Levels: `trace`, `debug`, `info`, `warn`, `error`, `fatal`. Up to 64
attributes per log (default attributes first); values can be strings,
numbers, booleans, null, `java.util.Date`, lists and maps. Messages are cut to
10,000 characters. Every log gets search `tokens` (same tokenizer as the
dashboard).

## Errors and crashes

```kotlin
try { ... } catch (e: Exception) {
    appTrack.error("Purchase failed", e, reason = "Store returned no receipt")
}
```

The throwable becomes the log's `error` map: `type` (class simple name),
`message` (`toString()`), `stack`, plus your `reason` (cut to 200 / 4000 /
16000 / 4000 characters).

`installCrashHandler()` sets `Thread.setDefaultUncaughtExceptionHandler`: an
uncaught exception is recorded as a `fatal` log (`error.handled=false`,
`error.mechanism=UncaughtExceptionHandler`, `thread.name`), written to the
queue file synchronously, sent with a best-effort wait of at most 2 s, then
the previous handler runs (on Android: the system crash dialog). If it
couldn't be sent, it goes out on the next launch.

`recordError(throwable, fatal = false)` records errors that your own
catch-all handlers catch (e.g. a coroutine `CoroutineExceptionHandler`). The
same error is recorded at most 5 times a minute.

## Requests

```kotlin
val start = System.nanoTime()
val res = client.newCall(req).execute()
appTrack.request("GET", "/api/orders/:id", statusCode = res.code,
    durationMs = (System.nanoTime() - start) / 1e6)
```

Use the route pattern, not the full URL. 5xx (or an `error` without a status)
is logged as error, 4xx as warn, else info. Adds `http.method`, `http.route`,
`http.status_code` and `duration_ms` attributes for the Endpoints page.

## Events

```kotlin
appTrack.capture("purchase_completed", mapOf("plan" to "pro", "amount" to 9.99))
appTrack.screen("Home")
appTrack.identify("user-42", mapOf("email" to "a@b.c"))   // links the anonymous ID
appTrack.setPersonProperties(mapOf("plan" to "pro"))
appTrack.reset()                                            // on sign-out
```

Events start with a random `anon_…` `distinctId`; persist `appTrack.distinctId`
and pass it back as `distinctId` on the next launch to keep one person.
Up to 128 properties per event.

## Sending, flush and the queue file

Logs and events are queued in memory and sent in batches on one background
thread every `flushIntervalMs`, or as soon as `batchSize` are waiting.

- `flush()` returns a `Future<Unit>` that completes when the send attempt is
  over; `flushBlocking(timeoutMs)` waits for it. Concurrent flushes share one
  send.
- Network errors and 5xx keep the items and retry with backoff (2, 4, 8 … up
  to 300 s). 400/403 (bad data, disabled key) drop the bad items, counted
  in `dropped`. `pending` is what's still waiting.
- `close()` flushes (ignoring backoff), waits up to 10 s and stops the thread.

### No duplicates on retry

Each log and event gets its Firestore document ID when it is created (20
random letters/digits), kept in the queue file too, and every send of it
uses that ID with `currentDocument.exists=false`. If a response was lost and
the batch is sent again, Firestore answers 409 ALREADY_EXISTS instead of
storing a second copy:

- one item: counted as delivered and in `duplicates`;
- several items (a commit is all-or-nothing): each is resent alone, so new
  items are saved and the old ones counted in `duplicates`. 400/403 for a
  batch is handled the same way, so only the bad items are dropped. A
  network error or 5xx during this stops and retries the rest later.

Pass your own `id` to store something at most once, e.g. a purchase:

```kotlin
appTrack.capture("purchase_completed", mapOf("amount" to 9.99), id = "txn_${purchase.orderId}")
appTrack.error("Payment failed", e, id = "payment_failed_$orderId")
```

`id` works on `capture` and every log method: 1–200 characters, no `/`, not
`.` or `..`, not `__…__`. An invalid ID is replaced by a random one (no
exception). IDs are per collection (logs and events separately).

### Flush when the app goes to the background

The library has no Android dependency, so hook it up in the app. With
`androidx.lifecycle:lifecycle-process`:

```kotlin
ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
    override fun onStop(owner: LifecycleOwner) { appTrack.flush() }
})
```

Without it, count started activities in `Application.ActivityLifecycleCallbacks`
and call `appTrack.flush()` in `onActivityStopped` when the count reaches 0.
`flush()` does not block (don't call `flushBlocking` on the main thread);
with a `queueFile` nothing is lost if the process is killed before it ends.

### Queue file

With `queueFile`, every queued item is also appended to a JSON-lines journal
(the Dart SDK's format: `{"n":seq,"q":item}` and `{"upto":seq}`). Items left
unsent when the process dies are restored on the next start (`restored`) and
sent right away; the file is emptied once everything is sent and compacted
past 1 MB. A line cut short by a crash is skipped. Use one file per logger.

## Retention (`expireAt`)

Each log gets `expireAt` = log time + `retentionDays` (default 90, clamped to
1–400). Firestore's TTL policy on `expireAt` deletes logs after that once TTL
is turned on for the project. `retentionDays = null` sends no expiry. Events
are not affected.
