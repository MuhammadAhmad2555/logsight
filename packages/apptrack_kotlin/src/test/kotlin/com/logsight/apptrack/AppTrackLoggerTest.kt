package com.logsight.apptrack

import com.sun.net.httpserver.HttpServer
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File
import java.net.InetSocketAddress
import java.util.Date
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

@Suppress("UNCHECKED_CAST")
class AppTrackLoggerTest {
    @TempDir
    lateinit var tmp: File

    private val key = "k".repeat(40)

    /** Records request bodies; answers with [status] (by call index); can hold requests at [gate]. */
    class FakeTransport(var status: (Int) -> Int = { 200 }) : HttpTransport {
        val bodies = CopyOnWriteArrayList<String>()
        val urls = CopyOnWriteArrayList<String>()
        val calls = AtomicInteger()

        @Volatile
        var gate: CountDownLatch? = null
        val entered = CountDownLatch(1)

        override fun post(url: String, jsonBody: String): HttpResponse {
            val n = calls.getAndIncrement()
            urls.add(url)
            bodies.add(jsonBody)
            entered.countDown()
            gate?.await(10, TimeUnit.SECONDS)
            return HttpResponse(status(n), "{}")
        }
    }

    private fun logger(
        t: HttpTransport,
        retentionDays: Int? = 90,
        queueFile: File? = null,
        batchSize: Int = 50,
        maxQueue: Int = 5000,
        defaultAttributes: Map<String, Any?> = emptyMap(),
    ) = AppTrackLogger(
        firebaseProjectId = "fb-proj",
        projectId = "p1",
        ingestKey = key,
        service = "svc_android",
        defaultAttributes = defaultAttributes,
        batchSize = batchSize,
        flushIntervalMs = 3_600_000,
        maxQueue = maxQueue,
        queueFile = queueFile,
        retentionDays = retentionDays,
        transport = t,
    )

    private fun writes(body: String) = (Json.decode(body) as Map<String, Any?>)["writes"] as List<Map<String, Any?>>
    private fun name(w: Map<String, Any?>) = (w["update"] as Map<String, Any?>)["name"] as String
    private fun fields(w: Map<String, Any?>) = (w["update"] as Map<String, Any?>)["fields"] as Map<String, Map<String, Any?>>

    /** Every document write (logs and events) in all requests, in order. */
    private fun docWrites(t: FakeTransport) =
        t.bodies.flatMap { writes(it) }.filter { it["currentDocument"] != null }

    private fun str(f: Map<String, Map<String, Any?>>, k: String) = f[k]?.get("stringValue") as String?
    private fun attrs(f: Map<String, Map<String, Any?>>) =
        (f["attributes"]!!["mapValue"] as Map<String, Any?>)["fields"] as Map<String, Map<String, Any?>>
    private fun tokens(f: Map<String, Map<String, Any?>>) =
        ((f["tokens"]!!["arrayValue"] as Map<String, Any?>)["values"] as List<Map<String, Any?>>).map { it["stringValue"] }
    private fun errorMap(f: Map<String, Map<String, Any?>>) =
        ((f["error"]!!["mapValue"] as Map<String, Any?>)["fields"] as Map<String, Map<String, Any?>>)
            .mapValues { it.value["stringValue"] as String }

    private val logFields = setOf(
        "ts", "severity", "message", "service", "key", "receivedAt", "attributes", "tokens",
        "traceId", "sessionId", "userId", "error", "expireAt",
    )
    private val eventFields = setOf("event", "distinctId", "ts", "receivedAt", "key", "sessionId", "service", "properties")

    @Test
    fun commitBodyShape() {
        val t = FakeTransport()
        val l = logger(t, defaultAttributes = mapOf("app.version" to "1.2.3"))
        l.userId = "user-1"
        l.sessionId = "sess-1"
        l.info(
            "Hello World",
            mapOf(
                "int" to 1, "long" to 5_000_000_000L, "dbl" to 2.5, "bool" to true, "nul" to null,
                "date" to Date(0), "nan" to Double.NaN, "inf" to Double.NEGATIVE_INFINITY,
                "list" to listOf(1, "a"), "map" to mapOf("x" to 1.0f), "esc" to "q\"uote\n\u0001é",
            ),
            traceId = "trace-1",
        )
        assertTrue(l.flushBlocking(5000))
        assertEquals(1, t.bodies.size)
        assertTrue(t.urls[0] == "https://firestore.googleapis.com/v1/projects/fb-proj/databases/(default)/documents:commit")
        val ws = writes(t.bodies[0])
        assertEquals(2, ws.size)

        // One-time service registration.
        val svc = ws[0]
        assertEquals("projects/fb-proj/databases/(default)/documents/projects/p1/services/svc_android", name(svc))
        assertEquals(mapOf("key" to mapOf("stringValue" to key)), fields(svc))
        assertEquals(mapOf("fieldPaths" to listOf("key")), svc["updateMask"])
        assertEquals(listOf(mapOf("fieldPath" to "lastSeen", "setToServerValue" to "REQUEST_TIME")), svc["updateTransforms"])
        assertNull(svc["currentDocument"])

        val w = ws[1]
        assertTrue(
            Regex("""projects/fb-proj/databases/\(default\)/documents/projects/p1/logs/[A-Za-z0-9]{20}""").matches(name(w)),
            name(w),
        )
        assertEquals(mapOf("exists" to false), w["currentDocument"])
        assertEquals(listOf(mapOf("fieldPath" to "receivedAt", "setToServerValue" to "REQUEST_TIME")), w["updateTransforms"])
        assertNull(w["updateMask"])
        val f = fields(w)
        assertTrue(logFields.containsAll(f.keys), f.keys.toString())
        assertTrue(f.keys.containsAll(listOf("ts", "severity", "message", "service", "key")))
        assertTrue(Regex("""\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z""").matches(f["ts"]!!["timestampValue"] as String))
        assertEquals("info", str(f, "severity"))
        assertEquals("Hello World", str(f, "message"))
        assertEquals("svc_android", str(f, "service"))
        assertEquals(key, str(f, "key"))
        assertEquals("user-1", str(f, "userId"))
        assertEquals("sess-1", str(f, "sessionId"))
        assertEquals("trace-1", str(f, "traceId"))
        assertEquals(listOf("hello", "world"), tokens(f))
        assertNull(f["error"])
        val a = attrs(f)
        assertEquals(mapOf("stringValue" to "1.2.3"), a["app.version"])
        assertEquals(mapOf("integerValue" to "1"), a["int"])
        assertEquals(mapOf("integerValue" to "5000000000"), a["long"])
        assertEquals(mapOf("doubleValue" to 2.5), a["dbl"])
        assertEquals(mapOf("booleanValue" to true), a["bool"])
        assertTrue(a.containsKey("nul") && a["nul"]!!.containsKey("nullValue") && a["nul"]!!["nullValue"] == null)
        assertEquals(mapOf("timestampValue" to "1970-01-01T00:00:00.000Z"), a["date"])
        assertEquals(mapOf("stringValue" to "NaN"), a["nan"])
        assertEquals(mapOf("stringValue" to "-Infinity"), a["inf"])
        assertEquals(
            mapOf("arrayValue" to mapOf("values" to listOf(mapOf("integerValue" to "1"), mapOf("stringValue" to "a")))),
            a["list"],
        )
        assertEquals(mapOf("mapValue" to mapOf("fields" to mapOf("x" to mapOf("doubleValue" to 1.0)))), a["map"])
        assertEquals(mapOf("stringValue" to "q\"uote\n\u0001é"), a["esc"])

        // Service registration happens only once.
        l.warn("second")
        assertTrue(l.flushBlocking(5000))
        val ws2 = writes(t.bodies[1])
        assertEquals(1, ws2.size)
        assertTrue(name(ws2[0]).contains("/logs/"))
        assertEquals(0, l.pending)
        l.close()
    }

    @Test
    fun tokensMatchDart() {
        // Expected values produced by the Dart SDK's tokenize().
        assertEquals(
            listOf("payment", "failed", "for", "order", "42", "user_id", "abc"),
            tokenize("Payment FAILED for order #42 (user_id=abc)"),
        )
        assertEquals(listOf("get", "api", "orders", "id", "500", "12", "ms"), tokenize("GET /api/orders/:id 500 (12 ms)"))
        assertEquals(listOf("cc", "dd", "x1", "stra", "cole"), tokenize("a b cc cc DD dd x1 Ünïcödé straße ÉCOLE"))
        assertEquals(listOf("ok", "y".repeat(40)), tokenize("x".repeat(41) + " ok " + "y".repeat(40)))
        assertEquals(
            listOf("null", "check", "operator", "used", "on", "value"),
            tokenize("Null check operator used on a null value"),
        )
        assertEquals(64, tokenize((0 until 100).joinToString(" ") { "w$it" }).size)
        assertEquals("2026-11-26T10:05:07.123Z", Iso.format(Iso.parse("2026-11-26T10:05:07.123Z")))
        assertEquals(1_795_687_507_123L, Iso.parse("2026-11-26T10:05:07.123456Z"))
    }

    @Test
    fun requestLogs() {
        val t = FakeTransport()
        val l = logger(t)
        l.request("get", "/api/orders/:id", statusCode = 500, durationMs = 12.345, attributes = mapOf("http.method" to "X", "region" to "eu"))
        l.request("POST", "/login", statusCode = 404, durationMs = 3.0)
        l.request("GET", "/ok", statusCode = 200)
        l.request("GET", "/boom", error = java.io.IOException("reset"))
        l.request("GET", "  ")
        assertTrue(l.flushBlocking(5000))
        val ws = docWrites(t).map { fields(it) }
        assertEquals(4, ws.size)
        val f = ws[0]
        assertEquals("error", str(f, "severity"))
        assertEquals("GET /api/orders/:id 500 (12 ms)", str(f, "message"))
        val a = attrs(f)
        assertEquals(listOf("http.method", "http.route", "http.status_code", "duration_ms", "region"), a.keys.toList())
        assertEquals(mapOf("stringValue" to "GET"), a["http.method"])
        assertEquals(mapOf("stringValue" to "/api/orders/:id"), a["http.route"])
        assertEquals(mapOf("integerValue" to "500"), a["http.status_code"])
        assertEquals(mapOf("doubleValue" to 12.3), a["duration_ms"])
        assertEquals(listOf("http_request", "get", "api", "orders", "id", "500", "12", "ms"), tokens(f))
        assertEquals("warn", str(ws[1], "severity"))
        assertEquals("POST /login 404 (3 ms)", str(ws[1], "message"))
        assertEquals("info", str(ws[2], "severity"))
        assertEquals("GET /ok 200", str(ws[2], "message"))
        assertNull(attrs(ws[2])["duration_ms"])
        assertEquals("error", str(ws[3], "severity"))
        assertEquals("GET /boom failed", str(ws[3], "message"))
        assertEquals("IOException", errorMap(ws[3])["type"])
        l.close()
    }

    @Test
    fun errorMapAndLimits() {
        val t = FakeTransport()
        val l = logger(t)
        l.error("Purchase failed", IllegalStateException("boom"), reason = "Store returned no receipt")
        l.fatal("Big", RuntimeException("m".repeat(5000)), reason = "r".repeat(5000))
        l.log(LogLevel.WARN, "warn with throwable", throwable = RuntimeException("ignored"))
        l.error("reason only", reason = "  just because  ")
        l.error("nothing")
        l.info("x".repeat(12_000), (0 until 70).associate { "a$it" to it })
        assertTrue(l.flushBlocking(5000))
        val ws = docWrites(t).map { fields(it) }
        val e = errorMap(ws[0])
        assertEquals(setOf("type", "message", "stack"), e.keys - "reason")
        assertEquals("IllegalStateException", e["type"])
        assertEquals("java.lang.IllegalStateException: boom", e["message"])
        assertEquals("Store returned no receipt", e["reason"])
        assertTrue(e["stack"]!!.startsWith("java.lang.IllegalStateException: boom"))
        assertTrue(e["stack"]!!.contains("errorMapAndLimits"))
        val e2 = errorMap(ws[1])
        assertEquals("fatal", str(ws[1], "severity"))
        assertEquals(4000, e2["message"]!!.length)
        assertEquals(4000, e2["reason"]!!.length)
        assertNull(ws[2]["error"])
        assertEquals(mapOf("reason" to "just because"), errorMap(ws[3]))
        assertNull(ws[4]["error"])
        assertEquals(10_000, str(ws[5], "message")!!.length)
        assertEquals(64, attrs(ws[5]).size)
        assertEquals(16_000, errorDetails(stack = "s".repeat(20_000))!!["stack"]!!.length)
        assertNull(errorDetails())
        l.close()
    }

    @Test
    fun expireAt() {
        val ts = 1_700_000_000_000L
        fun expiry(days: Int?): Map<String, Any?>? {
            val t = FakeTransport()
            val l = logger(t, retentionDays = days)
            l.log(LogLevel.INFO, "m", timestampMs = ts)
            l.flushBlocking(5000)
            l.close()
            val f = fields(docWrites(t)[0])
            assertEquals(Iso.format(ts), f["ts"]!!["timestampValue"])
            return f["expireAt"]
        }
        val day = 86_400_000L
        assertEquals(mapOf("timestampValue" to Iso.format(ts + 90 * day)), expiry(90))
        assertNull(expiry(null))
        assertEquals(mapOf("timestampValue" to Iso.format(ts + 400 * day)), expiry(1000))
        assertEquals(mapOf("timestampValue" to Iso.format(ts + 1 * day)), expiry(0))
        // Events never get expireAt.
        val t = FakeTransport()
        val l = logger(t)
        l.capture("evt")
        l.flushBlocking(5000)
        l.close()
        assertNull(fields(docWrites(t)[0])["expireAt"])
    }

    @Test
    fun serverErrorKeepsLogsAndBadRequestDrops() {
        var code = 503
        val t = FakeTransport { code }
        val l = logger(t)
        l.info("a")
        l.info("b")
        assertTrue(l.flushBlocking(5000))
        assertEquals(2, l.pending)
        assertEquals(0, l.dropped)
        // In backoff: no request.
        l.flushBlocking(5000)
        assertEquals(1, t.calls.get())
        code = 200
        assertTrue(l.close()) // close() skips the backoff
        assertEquals(2, t.calls.get())
        assertEquals(0, l.pending)
        // Service registration is retried after a failed send.
        assertTrue(writes(t.bodies[1]).any { name(it).endsWith("/services/svc_android") })

        val t2 = FakeTransport { 400 }
        val l2 = logger(t2)
        l2.info("bad")
        l2.capture("bad_event")
        assertTrue(l2.flushBlocking(5000))
        assertEquals(2, l2.dropped)
        assertEquals(0, l2.pending)
        l2.close()

        // IO failures retry too.
        val l3 = logger(HttpTransport { _, _ -> throw java.io.IOException("offline") })
        l3.info("x")
        l3.flushBlocking(5000)
        assertEquals(1, l3.pending)
        assertEquals(0, l3.dropped)
    }

    @Test
    fun queueFileSurvivesRestartAndEmptiesAfterSend() {
        val file = File(tmp, "q/apptrack_queue.jsonl")
        val t1 = FakeTransport { 503 }
        val l1 = logger(t1, queueFile = file)
        l1.info("first", mapOf("when" to Date(1_234_567L), "d" to 1.0, "n" to 3, "nan" to Double.NaN))
        l1.error("second", RuntimeException("x"))
        l1.capture("clicked", mapOf("k" to "v"))
        l1.flushBlocking(5000)
        assertEquals(4, l1.pending) // 3 items + 1 event-definition write (memory only)
        assertTrue(file.length() > 0)
        val sent1 = docWrites(t1).map { fields(it) }
        // Simulate the process being killed: l1 is abandoned without close().

        val t2 = FakeTransport()
        val l2 = logger(t2, queueFile = file)
        assertEquals(3, l2.restored)
        assertTrue(l2.flushBlocking(5000))
        assertEquals(0, l2.pending)
        assertEquals(0L, file.length())
        val sent2 = docWrites(t2)
        assertTrue(name(sent2[2]).contains("/events/"))
        // Restored items are sent exactly as they would have been, timestamps included.
        assertEquals(sent1, sent2.map { fields(it) })
        assertEquals(mapOf("timestampValue" to "1970-01-01T00:20:34.567Z"), attrs(fields(sent2[0]))["when"])
        assertEquals(mapOf("doubleValue" to 1.0), attrs(fields(sent2[0]))["d"])
        assertEquals(mapOf("integerValue" to "3"), attrs(fields(sent2[0]))["n"])
        l2.close()

        // A third start finds nothing.
        val l3 = logger(FakeTransport(), queueFile = file)
        assertEquals(0, l3.restored)
        l3.close()
    }

    @Test
    fun restoreKeepsNewestAndSkipsCutShortLine() {
        val file = File(tmp, "queue.jsonl")
        val item = { n: Int ->
            """{"n":$n,"q":{"ts":{"${'$'}dt":"2026-11-26T10:00:00.000Z"},"severity":"info","message":"m$n","service":"svc_android","key":"$key","tokens":["m$n"]}}"""
        }
        file.writeText(
            listOf(item(1), item(2), """{"upto":1}""", item(3), item(4), item(5)).joinToString("\n") + "\n" +
                """{"n":6,"q":{"ts":{"${'$'}dt":"2026-11""",
        )
        val t = FakeTransport { 503 }
        val l = logger(t, queueFile = file, maxQueue = 3)
        assertEquals(3, l.restored)
        assertEquals(1, l.dropped) // m2 didn't fit
        // The file was rewritten to just the pending items (plus the drop of m2).
        assertEquals(5, file.readLines().filter { it.isNotBlank() }.size)
        l.flushBlocking(5000)
        assertEquals(listOf("m3", "m4", "m5"), docWrites(t).map { str(fields(it), "message") })
        assertEquals(
            mapOf("timestampValue" to "2026-11-26T10:00:00.000Z"),
            fields(docWrites(t)[0])["ts"],
        )
        // New items continue the sequence after the restored ones; m3 no longer fits.
        l.info("m6")
        val lastTwo = file.readLines().takeLast(2)
        assertTrue(lastTwo[0].startsWith("{\"n\":6,"), lastTwo[0])
        assertEquals("{\"upto\":3}", lastTwo[1])
        assertEquals(2, l.dropped)
        // Another restart restores m4..m6 (m2, m3 stay dropped).
        val again = logger(FakeTransport { 503 }, queueFile = file)
        assertEquals(3, again.restored)
        assertEquals(0, again.dropped)
    }

    @Test
    fun inFlightDropRaceRemovesBySequence() {
        val file = File(tmp, "race.jsonl")
        val t = FakeTransport()
        t.gate = CountDownLatch(1)
        val l = logger(t, queueFile = file, batchSize = 3, maxQueue = 5)
        l.info("m1")
        l.info("m2")
        l.info("m3") // reaches batchSize: sends m1..m3 and blocks
        assertTrue(t.entered.await(5, TimeUnit.SECONDS))
        for (i in 4..7) l.info("m$i") // queue overflows: m1, m2 dropped while in flight
        assertEquals(2, l.dropped)
        assertEquals(5, l.pending)
        t.gate!!.countDown()
        t.gate = null
        assertTrue(l.flushBlocking(5000))
        // m4..m7 must not be removed along with the in-flight batch.
        assertEquals(listOf("m1", "m2", "m3", "m4", "m5", "m6", "m7"), docWrites(t).map { str(fields(it), "message") })
        assertEquals(0, l.pending)
        assertEquals(0L, file.length())
        l.close()
    }

    @Test
    fun crashHandlerRecordsToQueueFile() {
        val original = Thread.getDefaultUncaughtExceptionHandler()
        val file = File(tmp, "crash.jsonl")
        val previousCalls = CopyOnWriteArrayList<Throwable>()
        try {
            Thread.setDefaultUncaughtExceptionHandler { _, e -> previousCalls.add(e) }
            val t = FakeTransport { 503 }
            val l = logger(t, queueFile = file)
            l.installCrashHandler()
            l.installCrashHandler() // idempotent
            val crash = IllegalArgumentException("kaboom\nsecond line")
            val start = System.nanoTime()
            Thread.getDefaultUncaughtExceptionHandler()!!.uncaughtException(Thread(null, null, "worker-7"), crash)
            assertTrue(System.nanoTime() - start < 3_000_000_000L)
            assertEquals(listOf<Throwable>(crash), previousCalls.toList()) // chained exactly once

            // Written to the queue file before the (failed) send.
            val lines = file.readLines().filter { it.isNotBlank() }.map { QueueCodec.decode(it) }
            val q = lines.single { it["q"] != null }["q"] as Map<String, Any?>
            assertEquals("fatal", q["severity"])
            assertEquals("java.lang.IllegalArgumentException: kaboom", q["message"])
            val a = q["attributes"] as Map<String, Any?>
            assertEquals(false, a["error.handled"])
            assertEquals("UncaughtExceptionHandler", a["error.mechanism"])
            assertEquals("worker-7", a["thread.name"])
            val err = q["error"] as Map<String, Any?>
            assertEquals("IllegalArgumentException", err["type"])
            assertTrue(q["ts"] is Timestamp)
            assertEquals(1, t.calls.get()) // best-effort send was attempted

            // A fresh start sends it.
            val t2 = FakeTransport()
            val l2 = logger(t2, queueFile = file)
            assertEquals(1, l2.restored)
            assertTrue(l2.flushBlocking(5000))
            assertEquals("fatal", str(fields(docWrites(t2)[0]), "severity"))
            assertEquals(0L, file.length())

            // recordError + repeat limit.
            val t3 = FakeTransport()
            val l3 = logger(t3)
            repeat(8) { l3.recordError(RuntimeException("same")) }
            l3.flushBlocking(5000)
            val logs = docWrites(t3).map { fields(it) }
            assertEquals(AppTrackLogger.CRASH_REPEAT_LIMIT, logs.size)
            assertEquals("error", str(logs[0], "severity"))
            assertEquals(mapOf("stringValue" to "recordError"), attrs(logs[0])["error.mechanism"])
        } finally {
            Thread.setDefaultUncaughtExceptionHandler(original)
        }
    }

    @Test
    fun eventsPersonsAndDefinitions() {
        val t = FakeTransport()
        val l = logger(t)
        val anon = l.distinctId
        assertTrue(anon.startsWith("anon_") && anon.length == 25)
        l.sessionId = "s1"
        l.capture("purchase", mapOf("plan" to "pro", "amount" to 9.99))
        l.screen("Home")
        l.identify("user-42", mapOf("email" to "a@b.c"))
        l.capture("purchase", mapOf("plan" to "pro", "coupon" to "X"))
        l.capture("x", (0 until 200).associate { "p$it" to it })
        assertEquals("user-42", l.distinctId)
        assertEquals("user-42", l.userId)
        assertTrue(l.flushBlocking(5000))

        val events = docWrites(t)
        assertEquals(5, events.size)
        for (w in events) {
            assertTrue(name(w).matches(Regex(""".*/documents/projects/p1/events/[A-Za-z0-9]{20}""")))
            assertTrue(eventFields.containsAll(fields(w).keys), fields(w).keys.toString())
        }
        val e0 = fields(events[0])
        assertEquals("purchase", str(e0, "event"))
        assertEquals(anon, str(e0, "distinctId"))
        assertEquals("s1", str(e0, "sessionId"))
        assertEquals("svc_android", str(e0, "service"))
        val screen = fields(events[1])
        assertEquals("\$screen", str(screen, "event"))
        assertEquals(
            mapOf("stringValue" to "Home"),
            ((screen["properties"]!!["mapValue"] as Map<String, Any?>)["fields"] as Map<String, Any?>)["\$screen_name"],
        )
        val ident = fields(events[2])
        assertEquals("\$identify", str(ident, "event"))
        assertEquals("user-42", str(ident, "distinctId"))
        assertEquals(
            mapOf("stringValue" to anon),
            ((ident["properties"]!!["mapValue"] as Map<String, Any?>)["fields"] as Map<String, Any?>)["\$anon_distinct_id"],
        )
        assertEquals(128, ((fields(events[4])["properties"]!!["mapValue"] as Map<String, Any?>)["fields"] as Map<*, *>).size)

        // Meta writes come in their own commit, after the events.
        val metaBody = t.bodies.last()
        val meta = writes(metaBody)
        assertTrue(meta.none { it["currentDocument"] != null })
        val person = meta.first { name(it).endsWith("/persons/user-42") && fields(it).containsKey("properties") }
        assertEquals(listOf("key", "properties.`email`"), (person["updateMask"] as Map<String, Any?>)["fieldPaths"])
        val tr = person["updateTransforms"] as List<Map<String, Any?>>
        assertEquals("lastSeen", tr[0]["fieldPath"])
        assertEquals("firstSeen", tr[1]["fieldPath"])
        assertTrue(((tr[1]["minimum"] as Map<String, Any?>)["integerValue"] as String).toLong() > 0)
        assertEquals(
            mapOf("values" to listOf(mapOf("stringValue" to anon))),
            tr[2]["appendMissingElements"],
        )
        val defs = meta.filter { name(it).contains("/eventDefs/") }
        assertEquals(
            listOf("purchase", "\$screen", "\$identify", "purchase", "x"),
            defs.map { name(it).substringAfterLast('/') },
        )
        val purchase2 = defs[3]["updateTransforms"] as List<Map<String, Any?>>
        assertEquals(mapOf("values" to listOf(mapOf("stringValue" to "coupon"))), purchase2[1]["appendMissingElements"])
        // lastSeen for everyone who sent events.
        assertTrue(meta.any { name(it).endsWith("/persons/$anon") })

        l.reset()
        assertTrue(l.distinctId.startsWith("anon_") && l.distinctId != anon)
        assertNull(l.userId)
        l.close()
    }

    @Test
    fun concurrentLoggingDeliversEverything() {
        val t = FakeTransport()
        val l = logger(t)
        val threads = (0 until 8).map { n -> Thread { repeat(500) { l.info("t$n m$it") } } }
        threads.forEach { it.start() }
        threads.forEach { it.join() }
        assertTrue(l.close(10_000))
        assertEquals(4000, docWrites(t).size)
        assertEquals(4000, docWrites(t).map { str(fields(it), "message") }.toSet().size)
        assertEquals(0, l.pending)
        assertEquals(0, l.dropped)
        // Closed: further calls are ignored and never throw.
        l.info("after close")
        l.capture("after")
        assertEquals(0, l.pending)
    }

    @Test
    fun jsonRoundTrip() {
        val v = mapOf(
            "s" to "a\"b\\c\n\t\u0000é😀", "i" to 42L, "neg" to -7L, "d" to 0.1, "big" to 1.0E300, "t" to true,
            "n" to null, "l" to listOf(1L, listOf<Any?>(), mapOf<String, Any?>()),
        )
        assertEquals(v, Json.decode(Json.encode(v)))
        assertEquals("\"NaN\"", Json.encode(Double.NaN))
        assertEquals(mapOf("a" to "\u00e9"), Json.decode("""{"a":"\u00e9"}"""))
    }

    @Test
    fun realHttpWithUrlConnection() {
        val server = try {
            HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        } catch (e: Exception) {
            assumeTrue(false, "local port binding not available: $e")
            return
        }
        val bodies = CopyOnWriteArrayList<String>()
        val status = AtomicInteger(200)
        server.createContext("/") { ex ->
            bodies.add(ex.requestBody.readBytes().toString(Charsets.UTF_8))
            assertEquals("POST", ex.requestMethod)
            assertTrue(ex.requestHeaders.getFirst("Content-Type").startsWith("application/json"))
            val out = "{\"writeResults\":[]}".toByteArray()
            ex.sendResponseHeaders(status.get(), out.size.toLong())
            ex.responseBody.use { it.write(out) }
        }
        server.start()
        try {
            val l = AppTrackLogger(
                firebaseProjectId = "fb", projectId = "p", ingestKey = key, service = "svc",
                flushIntervalMs = 3_600_000, baseUrl = "http://127.0.0.1:${server.address.port}",
            )
            l.info("über real http")
            assertTrue(l.flushBlocking(5000))
            assertEquals(0, l.pending)
            assertEquals(1, bodies.size)
            val f = fields(docWrites(FakeTransport().also { it.bodies.addAll(bodies) })[0])
            assertEquals("über real http", str(f, "message"))
            status.set(403)
            l.info("rejected")
            assertTrue(l.flushBlocking(5000))
            assertEquals(1, l.dropped)
            l.close()
        } finally {
            server.stop(0)
        }
    }

    @Test
    fun loggingNeverThrows() {
        val l = logger(HttpTransport { _, _ -> throw OutOfMemoryError("not really") })
        val weird = object {
            override fun toString(): String = throw IllegalStateException("bad toString")
        }
        l.info("x", mapOf("w" to weird))
        l.capture("y", mapOf("w" to weird))
        assertNotNull(l.flush())
        assertFalse(l.distinctId.isEmpty())
    }

    // ============================================================ DEDUPLICATION

    /** A tiny Firestore: `currentDocument.exists=false` writes to an existing doc fail the whole commit with 409. */
    inner class FakeStore : HttpTransport {
        val docs = LinkedHashMap<String, Map<String, Map<String, Any?>>>()
        val bodies = CopyOnWriteArrayList<String>()

        /** Return a response to override the store (e.g. reject bad data). */
        @Volatile
        var hook: ((List<Map<String, Any?>>) -> HttpResponse?)? = null

        @Volatile
        var loseNextResponse = false

        override fun post(url: String, jsonBody: String): HttpResponse {
            bodies.add(jsonBody)
            val ws = writes(jsonBody)
            hook?.invoke(ws)?.let { return it }
            val docWs = ws.filter { it["currentDocument"] != null }
            synchronized(docs) {
                if (docWs.any { name(it) in docs }) {
                    return HttpResponse(409, """{"error":{"code":409,"status":"ALREADY_EXISTS"}}""")
                }
                docWs.forEach { docs[name(it)] = fields(it) }
            }
            if (loseNextResponse) {
                loseNextResponse = false
                throw java.io.IOException("connection reset after commit")
            }
            return HttpResponse(200, "{}")
        }

        fun messages() = synchronized(docs) { docs.values.map { str(it, "message") ?: str(it, "event") } }
        fun docNames(body: String) = writes(body).filter { it["currentDocument"] != null }.map { name(it) }
    }

    @Test
    fun retryAfterLostResponseReusesIdsAndCountsDuplicate() {
        val store = FakeStore()
        store.loseNextResponse = true
        val l = logger(store)
        l.info("once")
        l.flushBlocking(5000) // saved, but the response is lost
        assertEquals(1, l.pending)
        assertTrue(l.close()) // retry (close skips the backoff)
        assertEquals(store.docNames(store.bodies[0]), store.docNames(store.bodies[1]))
        assertEquals(listOf("once"), store.messages())
        assertEquals(1, l.duplicates)
        assertEquals(0, l.dropped)
        assertEquals(0, l.pending)
    }

    @Test
    fun retryAfterServerErrorReusesIds() {
        var code = 503
        val t = FakeTransport { code }
        val l = logger(t)
        l.info("a")
        l.capture("b")
        l.flushBlocking(5000)
        code = 200
        assertTrue(l.close())
        val first = writes(t.bodies[0]).filter { it["currentDocument"] != null }.map { name(it) }
        val second = writes(t.bodies[1]).filter { it["currentDocument"] != null }.map { name(it) }
        assertEquals(2, first.size)
        assertEquals(first, second)
    }

    @Test
    fun restartFromQueueFileReusesIds() {
        val file = File(tmp, "ids.jsonl")
        val t1 = FakeTransport { 503 }
        val l1 = logger(t1, queueFile = file)
        l1.info("a")
        l1.capture("b", id = "txn-9")
        l1.flushBlocking(5000)
        val names1 = docWrites(t1).map { name(it) }
        val t2 = FakeTransport()
        val l2 = logger(t2, queueFile = file)
        assertEquals(2, l2.restored)
        assertTrue(l2.flushBlocking(5000))
        assertEquals(names1, docWrites(t2).map { name(it) })
        assertTrue(names1[1].endsWith("/events/txn-9"))
        // The ID is not sent as a field.
        assertNull(fields(docWrites(t2)[0])["_id"])
        l2.close()
    }

    @Test
    fun conflictOnSingleItemCountsAsDelivered() {
        val t = FakeTransport { 409 }
        val l = logger(t)
        l.info("x")
        assertTrue(l.flushBlocking(5000))
        assertEquals(0, l.pending)
        assertEquals(1, l.duplicates)
        assertEquals(0, l.dropped)
        assertEquals(1, docWrites(t).size) // no split for one item
        l.close()
    }

    @Test
    fun conflictInMixedBatchSplitsAndKeepsNewItems() {
        val store = FakeStore()
        val l = logger(store)
        l.capture("purchase", mapOf("amount" to 9.99), id = "txn-1")
        assertTrue(l.flushBlocking(5000))
        // Same transaction captured again, together with new items.
        l.info("before")
        l.capture("purchase", mapOf("amount" to 9.99), id = "txn-1")
        l.info("after")
        assertTrue(l.flushBlocking(5000))
        assertEquals(1, l.duplicates)
        assertEquals(0, l.dropped)
        assertEquals(0, l.pending)
        assertEquals(listOf("purchase", "before", "after"), store.messages())
        assertEquals(1, store.docs.keys.count { it.endsWith("/events/txn-1") })
        l.close()
    }

    @Test
    fun ioErrorDuringSplitKeepsUnresolvedItems() {
        val store = FakeStore()
        val l = logger(store)
        l.info("old", id = "log-1")
        assertTrue(l.flushBlocking(5000))
        l.info("new-1")
        l.info("old", id = "log-1")
        l.info("new-2")
        var singles = 0
        store.hook = { ws ->
            val docs = ws.filter { it["currentDocument"] != null }
            // Second single send (the duplicate) hits a server error.
            if (docs.size == 1 && ++singles == 2) HttpResponse(503, "") else null
        }
        l.flushBlocking(5000)
        assertEquals(listOf("old", "new-1"), store.messages())
        assertEquals(2, l.pending) // the duplicate and new-2 wait for the retry
        store.hook = null
        assertTrue(l.close())
        assertEquals(listOf("old", "new-1", "new-2"), store.messages())
        assertEquals(1, l.duplicates)
        assertEquals(0, l.pending)
    }

    @Test
    fun rejectedMixedBatchDropsOnlyBadItems() {
        val store = FakeStore()
        store.hook = { ws ->
            if (ws.any { it["currentDocument"] != null && str(fields(it), "message") == "bad" }) {
                HttpResponse(403, """{"error":{"code":403,"status":"PERMISSION_DENIED"}}""")
            } else {
                null
            }
        }
        val l = logger(store)
        l.info("good-1")
        l.info("bad")
        l.info("good-2")
        assertTrue(l.flushBlocking(5000))
        assertEquals(1, l.dropped)
        assertEquals(0, l.duplicates)
        assertEquals(0, l.pending)
        assertEquals(listOf("good-1", "good-2"), store.messages())
        // The service registration rides with a later full batch that succeeds.
        l.info("good-3")
        assertTrue(l.flushBlocking(5000))
        assertTrue(writes(store.bodies.last()).any { name(it).endsWith("/services/svc_android") })
        l.close()
    }

    @Test
    fun customIdsAreValidatedAndUsedAsDocNames() {
        val t = FakeTransport()
        val l = logger(t)
        l.info("valid", id = "order-42")
        l.capture("purchase", id = "txn-1")
        l.error("err", RuntimeException("x"), id = "err-1")
        for (bad in listOf("a/b", ".", "..", "__x__", "", "x".repeat(201))) l.info("bad", id = bad)
        l.capture("purchase2", id = "__reserved__")
        assertTrue(l.flushBlocking(5000))
        val names = docWrites(t).map { name(it) }
        assertTrue(names[0].endsWith("/projects/p1/logs/order-42"), names[0])
        assertTrue(names[1].endsWith("/projects/p1/events/txn-1"), names[1])
        assertTrue(names[2].endsWith("/projects/p1/logs/err-1"), names[2])
        val random = Regex(""".*/(logs|events)/[A-Za-z0-9]{20}""")
        for (n in names.drop(3)) assertTrue(random.matches(n), n)
        assertEquals(10, names.size)
        assertEquals(10, names.toSet().size)
        l.close()
    }
}
