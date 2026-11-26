package com.logsight.apptrack

import java.io.File
import java.security.SecureRandom
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.FutureTask
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ThreadFactory
import java.util.concurrent.TimeUnit
import kotlin.math.floor
import kotlin.math.min

enum class LogLevel {
    TRACE, DEBUG, INFO, WARN, ERROR, FATAL;

    /** Name sent as `severity` (lowercase). */
    val wireName: String get() = name.lowercase()
}

/**
 * Queues logs and product events and sends them to LogSight (AppTrack) in
 * batches, straight to Firestore's REST `documents:commit` endpoint with an
 * ingest key. Kotlin port of the Dart `apptrack_logger` package; same wire
 * format.
 *
 * Thread-safe: call it from any thread. Logging never throws and never
 * blocks on the network (sending happens on one background daemon thread).
 * Call [close] before the process exits (servers: in a shutdown hook).
 *
 * @param firebaseProjectId the Firebase project that hosts LogSight.
 * @param projectId the LogSight project ID.
 * @param ingestKey the project's ingest key.
 * @param service shown as `service_name` in LogSight, e.g. `myapp_android`.
 * @param defaultAttributes added to every log, e.g. app version or environment.
 * @param minLevel logs below this level are ignored.
 * @param batchSize logs/events per request (1–500).
 * @param flushIntervalMs how often queued items are sent.
 * @param maxQueue the oldest items are dropped (counted in [dropped]) beyond this.
 * @param queueFile if set, unsent logs and events are also kept in this file
 *   so they survive the process being killed, crashing or going offline, and
 *   are sent on the next launch. One file per logger, e.g.
 *   `File(context.filesDir, "apptrack_queue.jsonl")`.
 * @param retentionDays sent as `expireAt` = log time + this many days
 *   (clamped to 1–400) for Firestore's TTL policy; null sends no expiry.
 *   Events are not affected.
 * @param printToConsole also print each log (and rejected batches) to stdout.
 * @param distinctId starting ID for events; a random `anon_…` ID if null.
 *   Persist [distinctId] and pass it back on next launch to keep one person.
 * @param transport how requests are sent (default: HttpURLConnection).
 * @param baseUrl Firestore REST host; change it for the Firestore emulator.
 */
class AppTrackLogger @JvmOverloads constructor(
    val firebaseProjectId: String,
    val projectId: String,
    val ingestKey: String,
    val service: String,
    defaultAttributes: Map<String, Any?> = emptyMap(),
    val minLevel: LogLevel = LogLevel.TRACE,
    val batchSize: Int = 50,
    val flushIntervalMs: Long = 5_000,
    val maxQueue: Int = 5_000,
    val queueFile: File? = null,
    retentionDays: Int? = 90,
    val printToConsole: Boolean = false,
    distinctId: String? = null,
    private val transport: HttpTransport = UrlConnectionTransport(),
    val baseUrl: String = "https://firestore.googleapis.com",
) {
    init {
        require(batchSize in 1..500) { "batchSize must be 1–500" }
        require(maxQueue > 0) { "maxQueue must be > 0" }
        require(flushIntervalMs > 0) { "flushIntervalMs must be > 0" }
    }

    @Suppress("UNCHECKED_CAST")
    val defaultAttributes: Map<String, Any?> = normalize(defaultAttributes) as Map<String, Any?>

    /** [retentionDays] clamped to what the server accepts (1–400), or null. */
    val retentionDays: Int? = retentionDays?.coerceIn(1, 400)

    /** Attached to every log while set. Cut to 128 characters (server limit). */
    @Volatile
    var userId: String? = null

    /** Attached to every log and event while set. Cut to 128 characters. */
    @Volatile
    var sessionId: String? = null

    private val lock = Any()
    private val random = SecureRandom()

    /** Who events belong to (PostHog's distinct_id); [identify] switches it to the user's ID. */
    val distinctId: String get() = synchronized(lock) { _distinctId }
    private var _distinctId: String = distinctId?.takeIf { it.isNotBlank() } ?: anonId()

    /** Logs and events waiting to be sent, oldest first, each with its sequence number in `_n`. */
    private val queue = ArrayList<MutableMap<String, Any?>>()

    /** Person / event-definition writes, sent in their own commit so a problem there never drops logs. */
    private val meta = ArrayList<Map<String, Any?>>()
    private val knownEvents = HashMap<String, MutableSet<String>>()
    private var seq = 0L
    private var inFlight: Future<Unit>? = null
    private var failures = 0
    private var retryAfter = 0L
    private var closed = false
    private var serviceRegistered = false
    private val recentCrashes = LinkedHashMap<String, LongArray>()
    private val store: QueueStore? = queueFile?.let { QueueStore(it) }

    @Volatile
    private var worker: Thread? = null
    private val executor: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor(
        ThreadFactory { r ->
            Thread(r, "apptrack-sender").also {
                it.isDaemon = true
                worker = it
            }
        },
    )
    private var timer: ScheduledFuture<*>? = null

    /** Logs and events dropped because the queue was full or the server rejected them (400/403). */
    @Volatile
    var dropped: Int = 0
        private set

    /**
     * Logs and events the server already had (HTTP 409 ALREADY_EXISTS): a
     * retry after a lost response, or a custom `id` sent twice. They count
     * as delivered.
     */
    @Volatile
    var duplicates: Int = 0
        private set

    /** Logs and events restored from [queueFile] at startup (left unsent by an earlier run). */
    @Volatile
    var restored: Int = 0
        private set

    /** Items queued but not yet delivered (waiting for a batch or a retry). */
    val pending: Int get() = synchronized(lock) { queue.size + meta.size }

    private val endpoint: String
        get() = "${baseUrl.trimEnd('/')}/v1/projects/$firebaseProjectId/databases/(default)/documents:commit"
    private val root: String
        get() = "projects/$firebaseProjectId/databases/(default)/documents/projects/$projectId"

    // ==================================================================== LOGS

    @JvmOverloads
    fun trace(message: String, attributes: Map<String, Any?>? = null, traceId: String? = null, id: String? = null) =
        log(LogLevel.TRACE, message, attributes, traceId, id = id)

    @JvmOverloads
    fun debug(message: String, attributes: Map<String, Any?>? = null, traceId: String? = null, id: String? = null) =
        log(LogLevel.DEBUG, message, attributes, traceId, id = id)

    @JvmOverloads
    fun info(message: String, attributes: Map<String, Any?>? = null, traceId: String? = null, id: String? = null) =
        log(LogLevel.INFO, message, attributes, traceId, id = id)

    @JvmOverloads
    fun warn(message: String, attributes: Map<String, Any?>? = null, traceId: String? = null, id: String? = null) =
        log(LogLevel.WARN, message, attributes, traceId, id = id)

    /**
     * Logs an error. [throwable] is recorded as `error.type` (class simple
     * name), `error.message` (toString()) and `error.stack`; [reason] is your
     * own explanation, e.g. "Receipt rejected by backend".
     */
    @JvmOverloads
    fun error(
        message: String,
        throwable: Throwable? = null,
        attributes: Map<String, Any?>? = null,
        traceId: String? = null,
        reason: String? = null,
        id: String? = null,
    ) = log(LogLevel.ERROR, message, attributes, traceId, throwable, reason, id = id)

    /** Like [error], for crashes and unrecoverable failures. */
    @JvmOverloads
    fun fatal(
        message: String,
        throwable: Throwable? = null,
        attributes: Map<String, Any?>? = null,
        traceId: String? = null,
        reason: String? = null,
        id: String? = null,
    ) = log(LogLevel.FATAL, message, attributes, traceId, throwable, reason, id = id)

    /**
     * Queues one log. Never throws and never blocks on the network. Error
     * details are kept only on error/fatal.
     *
     * [id] optionally sets the log's document ID, so logging the same ID
     * twice stores it once (1–200 chars, no `/`, not `.`/`..`/`__…__`;
     * invalid IDs are replaced by a random one).
     */
    @JvmOverloads
    fun log(
        level: LogLevel,
        message: String,
        attributes: Map<String, Any?>? = null,
        traceId: String? = null,
        throwable: Throwable? = null,
        reason: String? = null,
        timestampMs: Long? = null,
        id: String? = null,
    ) = logInternal(level, message, attributes, traceId, throwable, reason, timestampMs, emptyList(), id)

    /**
     * Logs one API request for the Endpoints page (calls, error rate and
     * latency per route). Use the route pattern, not the full URL:
     * `request("GET", "/api/orders/:id", statusCode = 200, durationMs = 41.7)`.
     *
     * 5xx (or an [error] without a status) is logged as error, 4xx as warn,
     * anything else as info.
     */
    @JvmOverloads
    fun request(
        method: String,
        route: String,
        statusCode: Int? = null,
        durationMs: Double? = null,
        attributes: Map<String, Any?>? = null,
        traceId: String? = null,
        error: Throwable? = null,
    ) {
        try {
            val m = method.trim().uppercase()
            val r = route.trim()
            if (r.isEmpty()) return
            val level = when {
                statusCode == null -> if (error != null) LogLevel.ERROR else LogLevel.INFO
                statusCode >= 500 -> LogLevel.ERROR
                statusCode >= 400 -> LogLevel.WARN
                else -> LogLevel.INFO
            }
            val parts = mutableListOf(m, r)
            if (statusCode != null) parts.add(statusCode.toString())
            if (durationMs != null) parts.add("(${roundHalfAway(durationMs)} ms)")
            if (statusCode == null && error != null) parts.add("failed")
            val http = LinkedHashMap<String, Any?>()
            http["http.method"] = m
            http["http.route"] = r
            if (statusCode != null) http["http.status_code"] = statusCode.toLong()
            if (durationMs != null) http["duration_ms"] = roundHalfAway(durationMs * 10) / 10.0
            // Request fields first (so the 64-attribute cap never drops them)
            // and last (so they win over same-named custom attributes).
            val attrs = LinkedHashMap<String, Any?>(http)
            if (attributes != null) attrs.putAll(attributes)
            attrs.putAll(http)
            logInternal(level, parts.joinToString(" "), attrs, traceId, error, null, null, listOf(REQUEST_TOKEN))
        } catch (_: Exception) {
        }
    }

    private fun logInternal(
        level: LogLevel,
        message: String,
        attributes: Map<String, Any?>?,
        traceId: String?,
        throwable: Throwable?,
        reason: String?,
        timestampMs: Long?,
        extraTokens: List<String>,
        id: String? = null,
    ) {
        try {
            if (level < minLevel || synchronized(lock) { closed }) return
            val details = if (level >= LogLevel.ERROR) errorDetails(throwable, reason) else null
            if (printToConsole) println("[${level.name}] $service: $message")
            val attrs = LinkedHashMap<String, Any?>(defaultAttributes)
            if (attributes != null) for ((k, v) in attributes) attrs[k] = normalize(v)
            if (attrs.size > 64) {
                val keep = attrs.keys.take(64).toSet()
                attrs.keys.retainAll(keep)
            }
            val text = if (message.length > 10_000) message.substring(0, 10_000) else message
            val ts = Timestamp(timestampMs ?: System.currentTimeMillis())
            val tokens = if (extraTokens.isEmpty()) {
                tokenize(text)
            } else {
                LinkedHashSet<String>(extraTokens).apply { addAll(tokenize(text, 64 - extraTokens.size)) }.toList()
            }
            val item = LinkedHashMap<String, Any?>()
            item["_id"] = docIdFor(id)
            item["ts"] = ts
            item["severity"] = level.wireName
            item["message"] = text
            item["service"] = service
            item["key"] = ingestKey
            item["tokens"] = tokens
            if (attrs.isNotEmpty()) item["attributes"] = attrs
            userId?.let { item["userId"] = cut(it, 128) }
            sessionId?.let { item["sessionId"] = cut(it, 128) }
            if (traceId != null) item["traceId"] = cut(traceId, 128)
            if (details != null) item["error"] = details
            retentionDays?.let { item["expireAt"] = ts.plusDays(it) }
            enqueue(item)
        } catch (_: Exception) {
            // Logging must never throw.
        }
    }

    // ================================================================ ACTIVITY

    /**
     * Records a product event (PostHog's `capture`), e.g.
     * `capture("purchase_completed", mapOf("plan" to "pro", "amount" to 9.99))`.
     * At most 128 properties per event.
     *
     * [id] optionally sets the event's document ID, so capturing the same ID
     * twice (e.g. a purchase transaction ID) stores it once. 1–200 chars, no
     * `/`, not `.`/`..`/`__…__`; invalid IDs are replaced by a random one.
     */
    @JvmOverloads
    fun capture(event: String, properties: Map<String, Any?>? = null, timestampMs: Long? = null, id: String? = null) {
        try {
            val name = event.trim()
            if (name.isEmpty()) return
            val props = LinkedHashMap<String, Any?>()
            if (properties != null) {
                for ((k, v) in properties) {
                    if (props.size >= 128) break
                    props[k] = normalize(v)
                }
            }
            synchronized(lock) {
                if (closed) return
                val item = LinkedHashMap<String, Any?>()
                item["_kind"] = "event"
                item["_id"] = docIdFor(id)
                item["event"] = cut(name, 200)
                item["distinctId"] = _distinctId
                item["ts"] = Timestamp(timestampMs ?: System.currentTimeMillis())
                item["key"] = ingestKey
                item["service"] = service
                sessionId?.let { item["sessionId"] = cut(it, 128) }
                if (props.isNotEmpty()) item["properties"] = props
                enqueue(item)
                registerEvent(name, props.keys)
            }
        } catch (_: Exception) {
        }
    }

    /** A screen view, like PostHog's `$screen` event. */
    @JvmOverloads
    fun screen(screenName: String, properties: Map<String, Any?>? = null) {
        val props = LinkedHashMap<String, Any?>()
        props["\$screen_name"] = screenName
        if (properties != null) props.putAll(properties)
        capture("\$screen", props)
    }

    /**
     * Links the current (usually anonymous) ID to [userId] and makes [userId]
     * the ID for all following events and logs. Optional [properties] are set
     * on the person (e.g. email, name, plan).
     */
    @JvmOverloads
    fun identify(userId: String, properties: Map<String, Any?>? = null) {
        try {
            val id = userId.trim()
            if (id.isEmpty()) return
            synchronized(lock) {
                if (closed) return
                val previous = _distinctId
                _distinctId = id
                this.userId = id
                person(id, properties ?: emptyMap(), if (previous != id) listOf(previous) else emptyList())
                capture("\$identify", if (previous != id) mapOf("\$anon_distinct_id" to previous) else null)
            }
        } catch (_: Exception) {
        }
    }

    /** Sets properties on the current person (merged with existing ones). */
    fun setPersonProperties(properties: Map<String, Any?>) {
        try {
            if (properties.isEmpty()) return
            synchronized(lock) {
                if (closed) return
                person(_distinctId, properties, emptyList())
            }
        } catch (_: Exception) {
        }
    }

    /** Call on sign-out: starts a new anonymous person and clears [userId]. */
    fun reset() {
        synchronized(lock) {
            _distinctId = anonId()
            userId = null
        }
    }

    private fun anonId() = "anon_${newId()}"

    /** Caller holds [lock]. */
    private fun person(id: String, properties: Map<String, Any?>, aliases: List<String>) {
        if (!docIdOk(id)) return
        val p = LinkedHashMap<String, Any?>()
        for ((k, v) in properties) {
            if (p.size >= 200) break
            p[k] = normalize(v)
        }
        val fields = LinkedHashMap<String, Any?>()
        fields["key"] = mapOf("stringValue" to ingestKey)
        if (p.isNotEmpty()) fields["properties"] = toFirestoreValue(p)
        val transforms = mutableListOf<Map<String, Any?>>(
            mapOf("fieldPath" to "lastSeen", "setToServerValue" to "REQUEST_TIME"),
            mapOf("fieldPath" to "firstSeen", "minimum" to mapOf("integerValue" to System.currentTimeMillis().toString())),
        )
        if (aliases.isNotEmpty()) {
            transforms.add(
                mapOf(
                    "fieldPath" to "aliases",
                    "appendMissingElements" to mapOf("values" to aliases.map { mapOf("stringValue" to it) }),
                ),
            )
        }
        meta.add(
            mapOf(
                "update" to mapOf("name" to "$root/persons/$id", "fields" to fields),
                "updateMask" to mapOf("fieldPaths" to listOf("key") + p.keys.map { "properties.${quote(it)}" }),
                "updateTransforms" to transforms,
            ),
        )
    }

    /** Caller holds [lock]. */
    private fun registerEvent(name: String, propertyKeys: Collection<String>) {
        if (!docIdOk(name)) return
        val known = knownEvents[name]
        val fresh = propertyKeys.filter { known == null || it !in known }
        if (known != null && fresh.isEmpty()) return
        knownEvents.getOrPut(name) { HashSet() }.addAll(fresh)
        val transforms = mutableListOf<Map<String, Any?>>(
            mapOf("fieldPath" to "lastSeen", "setToServerValue" to "REQUEST_TIME"),
        )
        if (fresh.isNotEmpty()) {
            transforms.add(
                mapOf(
                    "fieldPath" to "properties",
                    "appendMissingElements" to mapOf("values" to fresh.take(300).map { mapOf("stringValue" to it) }),
                ),
            )
        }
        meta.add(
            mapOf(
                "update" to mapOf("name" to "$root/eventDefs/$name", "fields" to mapOf("key" to mapOf("stringValue" to ingestKey))),
                "updateMask" to mapOf("fieldPaths" to listOf("key")),
                "updateTransforms" to transforms,
            ),
        )
    }

    // ================================================================== QUEUE

    private fun enqueue(item: MutableMap<String, Any?>) {
        val flushNow: Boolean
        synchronized(lock) {
            if (closed) return
            if (item["_id"] !is String) item["_id"] = newId()
            item["_n"] = ++seq
            queue.add(item)
            store?.added(item)
            if (queue.size > maxQueue) {
                val extra = queue.size - maxQueue
                val last = queue[extra - 1]["_n"] as Long
                queue.subList(0, extra).clear()
                dropped += extra
                store?.removedUpTo(last, queue)
            }
            flushNow = queue.size >= batchSize
        }
        if (flushNow) flush()
    }

    /** Removes everything up to sequence number [upTo] (sent or rejected). Caller holds [lock]. */
    private fun removeUpTo(upTo: Long) {
        queue.removeAll { (it["_n"] as Long) <= upTo }
        store?.removedUpTo(upTo, queue)
    }

    private fun restoreQueue() {
        val items = store?.load() ?: return
        if (items.isEmpty()) return
        synchronized(lock) {
            // Keep the newest if more were saved than the queue holds.
            val keep = if (items.size > maxQueue) items.subList(items.size - maxQueue, items.size) else items
            dropped += items.size - keep.size
            // Items saved by older versions have no ID yet.
            for (item in keep) if (item["_id"] !is String) item["_id"] = newId()
            queue.addAll(keep)
            if (keep.size < items.size) store?.removedUpTo(items[items.size - keep.size - 1]["_n"] as Long, queue)
            seq = keep.last()["_n"] as Long
            restored = keep.size
        }
        // Send them soon, not after the first flush interval.
        executor.execute { flush() }
    }

    // ================================================================ SENDING

    /**
     * Sends everything queued, in the background. Returns a [Future] that
     * completes when this send attempt is over (delivered, rejected, or
     * failed and scheduled for retry): `flush().get()` to wait. Safe to call
     * often; concurrent calls share one send. Does nothing during a retry
     * backoff. Never throws.
     */
    fun flush(): Future<Unit> {
        try {
            synchronized(lock) {
                inFlight?.let { if (!it.isDone) return it }
                if ((queue.isEmpty() && meta.isEmpty()) || System.currentTimeMillis() < retryAfter) return Done
                if (executor.isShutdown) return Done
                val task = FutureTask(
                    Callable {
                        try {
                            drain()
                        } finally {
                            synchronized(lock) { inFlight = null }
                        }
                    },
                )
                inFlight = task
                executor.execute(task)
                return task
            }
        } catch (_: Exception) {
            synchronized(lock) { inFlight = null }
            return Done
        }
    }

    /**
     * [flush] and wait up to [timeoutMs]. Returns true if the send attempt
     * finished in time (check [pending] / [dropped] for the outcome). Returns
     * false immediately when called on the logger's own sender thread.
     */
    @JvmOverloads
    fun flushBlocking(timeoutMs: Long = 30_000): Boolean {
        if (Thread.currentThread() === worker) return false
        return try {
            flush().get(timeoutMs, TimeUnit.MILLISECONDS)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun drain() {
        while (true) {
            val batch = synchronized(lock) {
                if (queue.isEmpty()) null else ArrayList(queue.subList(0, min(batchSize, queue.size)))
            } ?: break
            val status = send(batch, includeService = true)
            if (status == SendResult.RETRY) {
                synchronized(lock) { backoff() }
                return
            }
            if (status != SendResult.OK && batch.size > 1) {
                // A commit is all-or-nothing: one item that already exists
                // (409) or has bad data (400/403) fails the whole batch.
                // Resend one at a time so only that item is affected.
                for (item in batch) {
                    val single = send(listOf(item), includeService = false)
                    if (single == SendResult.RETRY) {
                        synchronized(lock) { backoff() }
                        return
                    }
                    resolved(listOf(item), single)
                }
            } else {
                resolved(batch, status)
            }
        }
        while (true) {
            val batch = synchronized(lock) {
                if (meta.isEmpty()) null else ArrayList(meta.subList(0, min(400, meta.size)))
            } ?: break
            val status = commit(batch, "profile updates")
            if (status == SendResult.RETRY) {
                synchronized(lock) { backoff() }
                return
            }
            synchronized(lock) { meta.subList(0, batch.size).clear() }
        }
    }

    /** Records the outcome of [items] (sent in order) and removes them by sequence number. */
    private fun resolved(items: List<Map<String, Any?>>, status: SendResult) {
        synchronized(lock) {
            // By sequence number: while this batch was in flight, newer
            // items may have been added and older ones dropped (queue full).
            removeUpTo(items.last()["_n"] as Long)
            when (status) {
                SendResult.REJECTED -> dropped += items.size
                SendResult.CONFLICT -> duplicates += items.size
                else -> {}
            }
            failures = 0
            if (status != SendResult.REJECTED) {
                // Keep "last seen" current for everyone who just sent events.
                items.filter { it["_kind"] == "event" }.map { it["distinctId"] as String }.toSet()
                    .forEach { person(it, emptyMap(), emptyList()) }
            }
        }
    }

    private fun backoff() {
        failures++
        val seconds = min(300L, 1L shl min(failures, 20))
        retryAfter = System.currentTimeMillis() + seconds * 1000
    }

    private fun commit(writes: List<Map<String, Any?>>, what: String): SendResult {
        return try {
            val res = transport.post(endpoint, Json.encode(mapOf("writes" to writes)))
            when (res.statusCode) {
                200 -> SendResult.OK
                // ALREADY_EXISTS: a document in the commit was saved before
                // (a retry after a lost response, or a repeated custom ID).
                // 409 ABORTED (contention) is retried.
                409 -> if (res.body.contains("ABORTED")) SendResult.RETRY else SendResult.CONFLICT
                400, 403 -> {
                    if (printToConsole) println("AppTrack rejected ${writes.size} $what: ${res.body}")
                    SendResult.REJECTED
                }
                else -> SendResult.RETRY
            }
        } catch (_: Exception) {
            SendResult.RETRY
        }
    }

    private fun send(batch: List<Map<String, Any?>>, includeService: Boolean): SendResult {
        val registerService = includeService && !serviceRegistered && serviceIdOk(service)
        val writes = ArrayList<Map<String, Any?>>()
        if (registerService) {
            // Once per logger: list this service in the project's services so
            // the dashboard can show it in the service switcher.
            writes.add(
                mapOf(
                    "update" to mapOf(
                        "name" to "$root/services/$service",
                        "fields" to mapOf("key" to mapOf("stringValue" to ingestKey)),
                    ),
                    "updateMask" to mapOf("fieldPaths" to listOf("key")),
                    "updateTransforms" to listOf(mapOf("fieldPath" to "lastSeen", "setToServerValue" to "REQUEST_TIME")),
                ),
            )
        }
        for (item in batch) {
            val collection = if (item["_kind"] == "event") "events" else "logs"
            val fields = LinkedHashMap<String, Any?>()
            for ((k, v) in item) if (k != "_kind" && k != "_n" && k != "_id") fields[k] = toFirestoreValue(v)
            writes.add(
                mapOf(
                    "update" to mapOf("name" to "$root/$collection/${item["_id"]}", "fields" to fields),
                    "currentDocument" to mapOf("exists" to false),
                    "updateTransforms" to listOf(mapOf("fieldPath" to "receivedAt", "setToServerValue" to "REQUEST_TIME")),
                ),
            )
        }
        val result = commit(writes, "logs/events")
        if (result == SendResult.OK && registerService) serviceRegistered = true
        return result
    }

    /** [custom] if it's a valid document ID, else a random one. */
    private fun docIdFor(custom: String?): String = if (custom != null && docIdOk(custom)) custom else newId()

    private fun newId(): String {
        val chars = ID_CHARS
        val b = CharArray(20)
        for (i in b.indices) b[i] = chars[random.nextInt(chars.length)]
        return String(b)
    }

    /**
     * Flushes (waiting up to [timeoutMs]) and stops the background thread.
     * The logger ignores calls afterwards. Returns true if the final send
     * finished in time; then `pending == 0 && dropped == 0` means everything
     * was accepted.
     */
    @JvmOverloads
    fun close(timeoutMs: Long = 10_000): Boolean {
        timer?.cancel(false)
        synchronized(lock) {
            if (closed) return true
            retryAfter = 0
        }
        val ok = flushBlocking(timeoutMs)
        synchronized(lock) {
            closed = true
            store?.close()
        }
        executor.shutdown()
        return ok
    }

    // ================================================================= CRASHES

    /**
     * Records uncaught exceptions: sets [Thread.setDefaultUncaughtExceptionHandler]
     * to a handler that logs the throwable as a `fatal` log (with
     * `error.handled=false`, `error.mechanism="UncaughtExceptionHandler"` and
     * `thread.name`), which is written to [queueFile] synchronously, makes a
     * best-effort send (at most 2 s), then calls the previous handler (on
     * Android that one shows the crash dialog and kills the process). Call
     * once at startup, after creating the logger.
     */
    fun installCrashHandler() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        if (previous is CrashHandler && previous.logger === this) return
        Thread.setDefaultUncaughtExceptionHandler(CrashHandler(this, previous))
    }

    /**
     * Records a throwable nothing else handled (e.g. from a coroutine
     * exception handler) as an `error` (or `fatal`) log with
     * `error.handled=false` and `error.mechanism="recordError"`, and starts
     * sending it. Repeats of the same error beyond [CRASH_REPEAT_LIMIT] per
     * minute are skipped.
     */
    @JvmOverloads
    fun recordError(throwable: Throwable, fatal: Boolean = false, attributes: Map<String, Any?>? = null) {
        if (recordUncaught(throwable, "recordError", fatal, attributes)) flush()
    }

    /** Returns true if the error was queued. Never throws. */
    internal fun recordUncaught(t: Throwable, mechanism: String, fatal: Boolean, attributes: Map<String, Any?>?): Boolean {
        try {
            val text = t.toString().trim()
            val firstLine = text.lineSequence().first().trim()
            val message = firstLine.ifEmpty { t.javaClass.simpleName.ifEmpty { t.javaClass.name } }
            val key = "${t.javaClass.name}|$message"
            synchronized(lock) {
                if (closed) return false
                val now = System.currentTimeMillis()
                val seen = recentCrashes[key]
                val count = if (seen != null && now - seen[0] < 60_000) seen[1] + 1 else 1L
                recentCrashes[key] = longArrayOf(if (count == 1L) now else seen!![0], count)
                if (recentCrashes.size > 200) recentCrashes.remove(recentCrashes.keys.first())
                if (count > CRASH_REPEAT_LIMIT) return false
            }
            val attrs = LinkedHashMap<String, Any?>()
            attrs["error.handled"] = false
            attrs["error.mechanism"] = mechanism
            if (attributes != null) attrs.putAll(attributes)
            logInternal(
                if (fatal) LogLevel.FATAL else LogLevel.ERROR,
                cut(message, 500),
                attrs,
                null,
                t,
                null,
                null,
                emptyList(),
            )
            return true
        } catch (_: Throwable) {
            return false
        }
    }

    private class CrashHandler(
        val logger: AppTrackLogger,
        val previous: Thread.UncaughtExceptionHandler?,
    ) : Thread.UncaughtExceptionHandler {
        override fun uncaughtException(t: Thread, e: Throwable) {
            try {
                if (logger.recordUncaught(e, "UncaughtExceptionHandler", true, mapOf("thread.name" to t.name))) {
                    logger.flushBlocking(CRASH_FLUSH_TIMEOUT_MS)
                }
            } catch (_: Throwable) {
            }
            if (previous != null) {
                previous.uncaughtException(t, e)
            } else {
                // What the JVM does when no handler is set.
                System.err.print("Exception in thread \"${t.name}\" ")
                e.printStackTrace()
            }
        }
    }

    companion object {
        /** Token added to request logs so the dashboard can find them quickly. */
        const val REQUEST_TOKEN = "http_request"

        /** Uncaught errors recorded per error (type + first line) per minute. */
        const val CRASH_REPEAT_LIMIT = 5

        /** How long the crash handler waits for the crash log to be sent. */
        const val CRASH_FLUSH_TIMEOUT_MS = 2_000L

        private const val ID_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

        private fun cut(s: String, max: Int) = if (s.length > max) s.substring(0, max) else s

        private fun roundHalfAway(x: Double): Long = if (x >= 0) floor(x + 0.5).toLong() else -floor(-x + 0.5).toLong()

        private fun docIdOk(s: String) =
            s.isNotEmpty() && s.length <= 200 && !s.contains('/') && s != "." && s != ".." &&
                !(s.startsWith("__") && s.endsWith("__") && s.length >= 4)

        private fun quote(key: String) = "`" + key.replace("\\", "\\\\").replace("`", "\\`") + "`"

        /** Service names that are safe as a Firestore document ID. */
        private fun serviceIdOk(s: String) =
            s.isNotEmpty() && s.length <= 100 && Regex("^[A-Za-z0-9._-]+$").matches(s) && s != "." && s != ".."
    }

    private enum class SendResult { OK, RETRY, REJECTED, CONFLICT }

    private object Done : Future<Unit> {
        override fun cancel(mayInterruptIfRunning: Boolean) = false
        override fun isCancelled() = false
        override fun isDone() = true
        override fun get() = Unit
        override fun get(timeout: Long, unit: TimeUnit) = Unit
    }

    // Runs last, after every property above is initialized.
    init {
        restoreQueue()
        timer = executor.scheduleWithFixedDelay({ flush() }, flushIntervalMs, flushIntervalMs, TimeUnit.MILLISECONDS)
    }
}
