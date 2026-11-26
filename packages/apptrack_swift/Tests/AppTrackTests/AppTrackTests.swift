import Foundation
import XCTest
@testable import AppTrack

private let key = String(repeating: "k", count: 40)

final class AppTrackTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("apptrack-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func makeLogger(
        queueFile: URL? = nil, retentionDays: Int? = 90, batchSize: Int = 50, maxQueue: Int = 5000,
        defaults: [String: Any] = [:]
    ) -> AppTrackLogger {
        AppTrackLogger(
            firebaseProjectId: "fb-proj", projectId: "p1", ingestKey: key, service: "ios_app",
            defaultAttributes: defaults, batchSize: batchSize, flushInterval: 3600, maxQueue: maxQueue,
            queueFileURL: queueFile, retentionDays: retentionDays, session: MockURLProtocol.session())
    }

    // MARK: Commit body

    func testCommitBodyShape() async throws {
        let logger = makeLogger(defaults: ["app.version": "1.2.0"])
        logger.userId = "u1"
        logger.sessionId = "s1"
        logger.info("User signed in", attributes: ["count": 3, "ratio": 0.5, "ok": true, "none": NSNull(),
                                                   "tags": ["a", "b"], "when": Date(timeIntervalSince1970: 0)],
                    traceId: "t1")
        await logger.flush()

        let bodies = MockURLProtocol.bodies
        XCTAssertEqual(bodies.count, 1)
        let writes = bodies[0].writes
        XCTAssertEqual(writes.count, 2)

        // Service registration first.
        let svc = writes[0]
        XCTAssertEqual(svc.docName, "projects/fb-proj/databases/(default)/documents/projects/p1/services/ios_app")
        XCTAssertEqual(str(svc.fields["key"]), key)
        XCTAssertEqual((svc["updateMask"] as? [String: Any])?["fieldPaths"] as? [String], ["key"])
        XCTAssertNil(svc["currentDocument"])

        let w = writes[1]
        let prefix = "projects/fb-proj/databases/(default)/documents/projects/p1/logs/"
        XCTAssertTrue(w.docName.hasPrefix(prefix))
        let id = String(w.docName.dropFirst(prefix.count))
        XCTAssertEqual(id.count, 20)
        XCTAssertTrue(id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
        XCTAssertEqual((w["currentDocument"] as? [String: Any])?["exists"] as? Bool, false)
        let transforms = w["updateTransforms"] as? [[String: Any]]
        XCTAssertEqual(transforms?.count, 1)
        XCTAssertEqual(transforms?[0]["fieldPath"] as? String, "receivedAt")
        XCTAssertEqual(transforms?[0]["setToServerValue"] as? String, "REQUEST_TIME")

        let f = w.fields
        XCTAssertEqual(Set(f.keys), ["ts", "expireAt", "severity", "message", "service", "key", "tokens",
                                     "attributes", "userId", "sessionId", "traceId"])
        XCTAssertEqual(str(f["severity"]), "info")
        XCTAssertEqual(str(f["message"]), "User signed in")
        XCTAssertEqual(str(f["service"]), "ios_app")
        XCTAssertEqual(str(f["key"]), key)
        XCTAssertEqual(str(f["userId"]), "u1")
        XCTAssertEqual(str(f["sessionId"]), "s1")
        XCTAssertEqual(str(f["traceId"]), "t1")
        XCTAssertEqual(arrayStrings(f["tokens"]), ["user", "signed", "in"])
        let tsText = try XCTUnwrap((f["ts"] as? [String: Any])?["timestampValue"] as? String)
        XCTAssertTrue(tsText.hasSuffix("Z"))
        let ts = try XCTUnwrap(parseTimestamp(tsText))
        XCTAssertLessThan(abs(ts.timeIntervalSinceNow), 10)

        let attrs = mapFields(f["attributes"])
        XCTAssertEqual(str(attrs["app.version"]), "1.2.0")
        XCTAssertEqual((attrs["count"] as? [String: Any])?["integerValue"] as? String, "3")
        XCTAssertEqual((attrs["ratio"] as? [String: Any])?["doubleValue"] as? Double, 0.5)
        XCTAssertEqual((attrs["ok"] as? [String: Any])?["booleanValue"] as? Bool, true)
        XCTAssertTrue((attrs["none"] as? [String: Any])?["nullValue"] is NSNull)
        XCTAssertEqual(arrayStrings(attrs["tags"]), ["a", "b"])
        XCTAssertEqual((attrs["when"] as? [String: Any])?["timestampValue"] as? String, "1970-01-01T00:00:00.000Z")

        // Service registered once per logger.
        logger.warn("again")
        await logger.flush()
        let second = MockURLProtocol.bodies[1].writes
        XCTAssertEqual(second.count, 1)
        XCTAssertTrue(second[0].docName.contains("/logs/"))
        XCTAssertEqual(logger.pending, 0)
        XCTAssertEqual(logger.dropped, 0)
    }

    func testValueEncoding() {
        XCTAssertEqual(LogValue(Int(7)), .int(7))
        XCTAssertEqual(LogValue(true), .bool(true))
        XCTAssertEqual(LogValue(Double(2)), .double(2))
        XCTAssertEqual(LogValue(NSNumber(value: true)), .bool(true))
        XCTAssertEqual(LogValue(NSNumber(value: 5)), .int(5))
        XCTAssertEqual(LogValue(NSNumber(value: 1.5)), .double(1.5))
        let opt: String? = nil
        XCTAssertEqual(LogValue(opt as Any), .null)
        XCTAssertEqual(LogValue(Optional("x") as Any), .string("x"))
        XCTAssertEqual(LogValue(URL(string: "https://a.b")!), .string("https://a.b"))
        XCTAssertEqual(LogValue.double(.nan).firestore["stringValue"] as? String, "NaN")
        XCTAssertEqual(LogValue.double(-.infinity).firestore["stringValue"] as? String, "-Infinity")
        XCTAssertEqual(LogValue.int(42).firestore["integerValue"] as? String, "42")
    }

    // MARK: Tokens

    func testTokensMatchDart() {
        XCTAssertEqual(tokenize("User signed in: order #42 failed (HTTP 500)"),
                       ["user", "signed", "in", "order", "42", "failed", "http", "500"])
        XCTAssertEqual(tokenize("a b cc DD_ee x-y-zz Ünïcode"), ["cc", "dd_ee", "zz", "code"])
        XCTAssertEqual(tokenize("Foo foo FOO bar"), ["foo", "bar"])
        let t40 = String(repeating: "a", count: 40)
        let t41 = String(repeating: "b", count: 41)
        XCTAssertEqual(tokenize("\(t40) \(t41) ok"), [t40, "ok"])
        let many = (0..<100).map { "w\($0)" }.joined(separator: " ")
        let out = tokenize(many)
        XCTAssertEqual(out.count, 64)
        XCTAssertEqual(out.first, "w0")
        XCTAssertEqual(out.last, "w63")
        XCTAssertEqual(tokenize(many, maxTokens: 63).count, 63)
        XCTAssertEqual(tokenize(""), [])
    }

    // MARK: request()

    func testRequestAttributesAndLevel() async throws {
        let logger = makeLogger(retentionDays: nil)
        logger.request(method: " get ", route: "/api/orders/:id", statusCode: 503, duration: 0.0123456,
                       attributes: ["http.method": "OVERRIDE", "region": "eu"])
        logger.request(method: "POST", route: "/api/cart", statusCode: 404, duration: 0.25)
        logger.request(method: "GET", route: "/api/ok", statusCode: 200)
        logger.request(method: "GET", route: "/api/down", error: URLError(.timedOut))
        logger.request(method: "GET", route: "   ", statusCode: 200) // ignored
        await logger.flush()

        let logs = docWrites(MockURLProtocol.bodies).map { $0.fields }
        XCTAssertEqual(logs.count, 4)

        XCTAssertEqual(str(logs[0]["severity"]), "error")
        XCTAssertEqual(str(logs[0]["message"]), "GET /api/orders/:id 503 (12 ms)")
        let a0 = mapFields(logs[0]["attributes"])
        XCTAssertEqual(str(a0["http.method"]), "GET")
        XCTAssertEqual(str(a0["http.route"]), "/api/orders/:id")
        XCTAssertEqual((a0["http.status_code"] as? [String: Any])?["integerValue"] as? String, "503")
        XCTAssertEqual((a0["duration_ms"] as? [String: Any])?["doubleValue"] as? Double, 12.3)
        XCTAssertEqual(str(a0["region"]), "eu")
        let tokens = arrayStrings(logs[0]["tokens"])
        XCTAssertEqual(tokens.first, "http_request")
        XCTAssertEqual(tokens, ["http_request", "get", "api", "orders", "id", "503", "12", "ms"])
        XCTAssertNil(logs[0]["expireAt"])

        XCTAssertEqual(str(logs[1]["severity"]), "warn")
        XCTAssertEqual(str(logs[1]["message"]), "POST /api/cart 404 (250 ms)")
        XCTAssertEqual((mapFields(logs[1]["attributes"])["duration_ms"] as? [String: Any])?["doubleValue"] as? Double, 250)
        XCTAssertNil(logs[1]["error"])

        XCTAssertEqual(str(logs[2]["severity"]), "info")
        XCTAssertEqual(str(logs[2]["message"]), "GET /api/ok 200")
        XCTAssertNil(mapFields(logs[2]["attributes"])["duration_ms"])

        XCTAssertEqual(str(logs[3]["severity"]), "error")
        XCTAssertEqual(str(logs[3]["message"]), "GET /api/down failed")
        XCTAssertNil(mapFields(logs[3]["attributes"])["http.status_code"])
        XCTAssertEqual(str(mapFields(logs[3]["error"])["type"]), "URLError")
    }

    func testRequestFieldsSurviveAttributeCap() async {
        let logger = makeLogger()
        var attrs: [String: Any] = [:]
        for i in 0..<100 { attrs["a\(i)"] = i }
        logger.request(method: "GET", route: "/x", statusCode: 200, duration: 0.1, attributes: attrs)
        await logger.flush()
        let a = mapFields(docWrites(MockURLProtocol.bodies)[0].fields["attributes"])
        XCTAssertEqual(a.count, 64)
        for k in ["http.method", "http.route", "http.status_code", "duration_ms"] { XCTAssertNotNil(a[k], k) }
    }

    // MARK: Errors

    enum PaymentError: Error { case declined(code: Int) }

    func testErrorMapAndLimits() async throws {
        let logger = makeLogger()
        logger.error("Purchase failed", error: PaymentError.declined(code: 7),
                     reason: String(repeating: "r", count: 5000))
        logger.fatal("Boom", stackTrace: "  " + String(repeating: "s", count: 20000) + "\n")
        logger.error("😀" + String(repeating: "m", count: 20000))
        logger.log(.info, "not an error", error: PaymentError.declined(code: 1), reason: "x")
        await logger.flush()
        let logs = docWrites(MockURLProtocol.bodies).map { $0.fields }
        XCTAssertEqual(logs.count, 4)

        let e0 = mapFields(logs[0]["error"])
        XCTAssertEqual(str(e0["type"]), "PaymentError")
        XCTAssertEqual(str(e0["message"]), "declined(code: 7)")
        XCTAssertEqual(str(e0["reason"])?.count, 4000)
        let stack = try XCTUnwrap(str(e0["stack"]))
        XCTAssertFalse(stack.isEmpty)
        XCTAssertLessThanOrEqual(stack.utf16.count, 16000)
        XCTAssertTrue(Set(e0.keys).isSubset(of: ["type", "message", "reason", "stack"]))

        let e1 = mapFields(logs[1]["error"])
        XCTAssertEqual(Set(e1.keys), ["stack"])
        XCTAssertEqual(str(e1["stack"])?.utf16.count, 16000)
        XCTAssertEqual(str(logs[1]["severity"]), "fatal")

        XCTAssertEqual(str(logs[2]["message"])?.utf16.count, 10000)
        XCTAssertTrue(str(logs[2]["message"])!.hasPrefix("😀"))

        XCTAssertNil(logs[3]["error"])
        XCTAssertEqual(str(logs[3]["severity"]), "info")
    }

    func testCutKeepsSurrogatePairs() {
        XCTAssertEqual(cut("a😀b", 2), "a")
        XCTAssertEqual(cut("a😀b", 3), "a😀")
    }

    func testRecordErrorRateLimited() async {
        let logger = makeLogger()
        for _ in 0..<10 { logger.recordError(PaymentError.declined(code: 1)) }
        await logger.flush()
        let logs = docWrites(MockURLProtocol.bodies).map { $0.fields }
        XCTAssertEqual(logs.count, AppTrackLogger.crashRepeatLimit)
        let a = mapFields(logs[0]["attributes"])
        XCTAssertEqual((a["error.handled"] as? [String: Any])?["booleanValue"] as? Bool, true)
        XCTAssertEqual(str(a["error.mechanism"]), "recordError")
        XCTAssertEqual(str(logs[0]["severity"]), "error")
    }

    // MARK: expireAt

    func testExpireAtPresentAndAbsent() async throws {
        let ts = Date(timeIntervalSince1970: 1_800_000_000.123)
        let logger = makeLogger(retentionDays: 30)
        logger.log(.info, "with", timestamp: ts)
        await logger.flush()
        let f = docWrites(MockURLProtocol.bodies)[0].fields
        let exp = try XCTUnwrap((f["expireAt"] as? [String: Any])?["timestampValue"] as? String)
        let tsText = try XCTUnwrap((f["ts"] as? [String: Any])?["timestampValue"] as? String)
        XCTAssertEqual(tsText, "2027-01-15T08:00:00.123Z")
        XCTAssertEqual(exp, "2027-02-14T08:00:01.123Z") // ts + 30 d (+1 s margin)
        let ms = { (d: Date) in Int64((d.timeIntervalSince1970 * 1000).rounded(.down)) }
        for days in [1, 400] {
            let e = AppTrackLogger.expireAt(ts, days: days)
            XCTAssertGreaterThanOrEqual(ms(e) - ms(ts), Int64(days) * 86_400_000 - (days == 400 ? 1000 : 0))
            XCTAssertLessThanOrEqual(ms(e) - ms(ts), 400 * 86_400_000)
            XCTAssertGreaterThan(ms(e) - ms(ts), 86_400_000)
        }

        MockURLProtocol.reset()
        let noRetention = makeLogger(retentionDays: nil)
        noRetention.info("without")
        noRetention.capture("evt")
        await noRetention.flush()
        XCTAssertNil(docWrites(MockURLProtocol.bodies)[0].fields["expireAt"])
        // Events never carry expireAt.
        MockURLProtocol.reset()
        let withEvents = makeLogger()
        withEvents.capture("evt")
        await withEvents.flush()
        XCTAssertNil(docWrites(MockURLProtocol.bodies, collection: "events")[0].fields["expireAt"])

        // Clamped to the server's 1…400 day range.
        XCTAssertEqual(makeLogger(retentionDays: 1000).retentionDays, 400)
        XCTAssertEqual(makeLogger(retentionDays: 0).retentionDays, 1)
    }

    // MARK: Retry / reject

    func testBackoffKeepsLogsAndRejectDrops() async {
        MockURLProtocol.reset(status: 503)
        let logger = makeLogger()
        logger.info("one")
        await logger.flush()
        XCTAssertEqual(MockURLProtocol.bodies.count, 1)
        XCTAssertEqual(logger.pending, 1)
        XCTAssertEqual(logger.dropped, 0)
        // Backing off: no new request.
        await logger.flush()
        XCTAssertEqual(MockURLProtocol.bodies.count, 1)

        // Network errors also back off and keep the log.
        MockURLProtocol.reset(status: -1)
        let offline = makeLogger()
        offline.info("offline")
        await offline.flush()
        XCTAssertEqual(offline.pending, 1)
        XCTAssertEqual(offline.dropped, 0)

        MockURLProtocol.reset(status: 400)
        let rejected = makeLogger()
        rejected.info("a")
        rejected.info("b")
        await rejected.flush()
        XCTAssertEqual(rejected.pending, 0)
        XCTAssertEqual(rejected.dropped, 2)

        MockURLProtocol.reset(status: 403)
        let disabled = makeLogger()
        disabled.info("a")
        await disabled.flush()
        XCTAssertEqual(disabled.dropped, 1)
    }

    func testCloseRetriesDespiteBackoff() async {
        MockURLProtocol.reset(status: 503)
        let logger = makeLogger()
        logger.info("one")
        await logger.flush()
        MockURLProtocol.handler = { _ in 200 }
        await logger.close()
        XCTAssertEqual(logger.pending, 0)
        XCTAssertEqual(MockURLProtocol.bodies.count, 2)
        logger.info("after close") // ignored
        XCTAssertEqual(logger.pending, 0)
    }

    func testConcurrentFlushesShareOneSend() async {
        let gate = DispatchSemaphore(value: 0)
        MockURLProtocol.handler = { _ in gate.wait(); return 200 }
        let logger = makeLogger()
        logger.info("x")
        async let a: Void = logger.flush()
        async let b: Void = logger.flush()
        try? await Task.sleep(nanoseconds: 200_000_000)
        gate.signal()
        _ = await (a, b)
        XCTAssertEqual(MockURLProtocol.bodies.count, 1)
    }

    func testLoggingFromManyThreads() async {
        let logger = makeLogger(batchSize: 25)
        DispatchQueue.concurrentPerform(iterations: 200) { i in logger.info("msg \(i)") }
        await logger.close()
        XCTAssertEqual(docWrites(MockURLProtocol.bodies).count, 200)
        XCTAssertEqual(logger.pending, 0)
    }

    // MARK: Queue file

    func testQueueFileSurvivesRestartAndEmptiesAfterSend() async throws {
        let file = tempDir.appendingPathComponent("q/apptrack_queue.jsonl")
        MockURLProtocol.reset(status: 503)
        let ts = Date(timeIntervalSinceReferenceDate: 812_345_678.123456789)
        var firstTs: String?
        do {
            let first = makeLogger(queueFile: file)
            first.log(.info, "one", attributes: ["n": 1, "d": 2.0, "when": ts], timestamp: ts)
            first.warn("two")
            first.capture("signup", properties: ["plan": "pro"])
            await first.flush() // fails (503), stays queued
            firstTs = (docWrites(MockURLProtocol.bodies)[0].fields["ts"] as? [String: Any])?["timestampValue"] as? String
            XCTAssertEqual(first.pending, 3 + 1) // 3 queued + eventDef meta
        }
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 3)

        // The store keeps dates exactly.
        let store = QueueStore(url: file)
        let loaded = store.load().items
        XCTAssertEqual(loaded.map { $0.seq }, [1, 2, 3])
        XCTAssertEqual(loaded[0].fields["ts"], .date(ts))
        XCTAssertEqual(loaded[0].fields["attributes"], .map(["n": .int(1), "d": .double(2), "when": .date(ts)]))
        XCTAssertEqual(loaded[2].kind, .event)
        store.close()

        MockURLProtocol.reset(status: 200)
        let second = makeLogger(queueFile: file)
        XCTAssertEqual(second.restored, 3)
        await second.flush()
        let logs = docWrites(MockURLProtocol.bodies)
        XCTAssertEqual(logs.map { str($0.fields["message"]) }, ["one", "two"])
        XCTAssertEqual((logs[0].fields["ts"] as? [String: Any])?["timestampValue"] as? String, firstTs)
        let events = docWrites(MockURLProtocol.bodies, collection: "events")
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events[0].fields["_kind"])
        XCTAssertEqual(second.pending, 0)
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int
        XCTAssertEqual(size, 0)

        // New logs continue the numbering and go out normally.
        second.info("three")
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).hasPrefix("{"))
        await second.flush()
        XCTAssertEqual(second.pending, 0)
        let third = makeLogger(queueFile: file)
        XCTAssertEqual(third.restored, 0)
    }

    func testCutShortLineSkipped() throws {
        let file = tempDir.appendingPathComponent("queue.jsonl")
        let text = """
        {"n":1,"q":{"message":"a","severity":"info","ts":{"$dt":1000.5}}}
        {"n":2,"q":{"message":"b","severity":"info","ts":{"$dt":1001}}}
        {"upto":1}
        {"n":3,"q":{"message":"c","sev
        """
        try text.write(to: file, atomically: true, encoding: .utf8)
        MockURLProtocol.reset(status: 503)
        let logger = makeLogger(queueFile: file)
        XCTAssertEqual(logger.restored, 1)
        let items = QueueStore(url: file).load().items
        XCTAssertEqual(items.map { $0.seq }, [2])
        XCTAssertEqual(items[0].fields["message"], .string("b"))
        XCTAssertEqual(items[0].fields["ts"], .date(Date(timeIntervalSinceReferenceDate: 1001)))
    }

    func testRestoreKeepsNewestOverMaxQueue() throws {
        let file = tempDir.appendingPathComponent("queue.jsonl")
        let lines = (1...10).map { #"{"n":\#($0),"q":{"message":"m\#($0)"}}"# }.joined(separator: "\n")
        try lines.write(to: file, atomically: true, encoding: .utf8)
        MockURLProtocol.reset(status: 503)
        let logger = makeLogger(queueFile: file, maxQueue: 4)
        XCTAssertEqual(logger.restored, 4)
        XCTAssertEqual(logger.dropped, 6)
        XCTAssertEqual(QueueStore(url: file).load().items.map { $0.seq }, [7, 8, 9, 10])
    }

    func testQueueCompactsPastLimit() {
        let file = tempDir.appendingPathComponent("queue.jsonl")
        let store = QueueStore(url: file, compactBytes: 500)
        var items: [QueueItem] = []
        for i in 1...20 {
            let item = QueueItem(seq: i, kind: .log, fields: ["message": .string(String(repeating: "x", count: 50))])
            items.append(item)
            store.added(item)
        }
        items.removeFirst(15)
        store.removed(upTo: 15, remaining: items)
        store.close()
        let text = try! String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 5)
        XCTAssertEqual(QueueStore(url: file).load().items.map { $0.seq }, [16, 17, 18, 19, 20])
    }

    func testInFlightDropRemovesBySequence() async throws {
        let file = tempDir.appendingPathComponent("queue.jsonl")
        let started = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let first = Atomic(true)
        MockURLProtocol.handler = { _ in
            if first.swap(false) {
                started.signal()
                gate.wait()
            }
            return 200
        }
        let logger = makeLogger(queueFile: file, batchSize: 2, maxQueue: 3)
        logger.info("a")
        logger.info("b") // reaches batchSize: sends [a, b]
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        // While [a, b] is in flight the queue overflows and drops a and b.
        logger.info("c")
        logger.info("d")
        logger.info("e")
        XCTAssertEqual(logger.dropped, 2)
        gate.signal()
        await logger.flush()
        await logger.flush()
        let sent = docWrites(MockURLProtocol.bodies).compactMap { str($0.fields["message"]) }
        XCTAssertEqual(sent.sorted(), ["a", "b", "c", "d", "e"])
        XCTAssertEqual(logger.pending, 0)
        XCTAssertEqual(logger.dropped, 2)
        XCTAssertEqual(QueueStore(url: file).load().items.count, 0)
    }

    // MARK: Crashes

    func testUncaughtExceptionWritesToQueueFile() throws {
        let file = tempDir.appendingPathComponent("queue.jsonl")
        MockURLProtocol.reset(status: 503)
        do {
            let logger = makeLogger(queueFile: file)
            let exception = NSException(name: NSExceptionName("NSRangeException"),
                                        reason: "index 5 beyond bounds [0 .. 2]\nmore detail", userInfo: nil)
            logger.recordUncaughtException(exception)
            // Written synchronously, before returning.
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
            XCTAssertEqual(lines.count, 1)
            XCTAssertEqual(MockURLProtocol.bodies.count, 0) // no send attempted
        }
        let items = QueueStore(url: file).load().items
        XCTAssertEqual(items.count, 1)
        let f = items[0].fields
        XCTAssertEqual(f["severity"], .string("fatal"))
        XCTAssertEqual(f["message"], .string("index 5 beyond bounds [0 .. 2]"))
        guard case .map(let attrs)? = f["attributes"], case .map(let err)? = f["error"] else {
            return XCTFail("missing attributes/error")
        }
        XCTAssertEqual(attrs["error.handled"], .bool(false))
        XCTAssertEqual(attrs["error.mechanism"], .string("NSUncaughtExceptionHandler"))
        XCTAssertEqual(err["type"], .string("NSRangeException"))
        XCTAssertEqual(err["message"], .string("index 5 beyond bounds [0 .. 2]\nmore detail"))
        XCTAssertNotNil(err["stack"])
    }

    func testCrashHandlerChainsPreviousHandler() throws {
        let file = tempDir.appendingPathComponent("queue.jsonl")
        MockURLProtocol.reset(status: 503)
        let original = NSGetUncaughtExceptionHandler()
        defer { NSSetUncaughtExceptionHandler(original) }
        previousHandlerCalls = 0
        NSSetUncaughtExceptionHandler { _ in previousHandlerCalls += 1 }
        let logger = makeLogger(queueFile: file)
        logger.installCrashHandler()
        CrashHandler.handle(NSException(name: .genericException, reason: "kaboom", userInfo: nil))
        XCTAssertEqual(previousHandlerCalls, 1)
        func lines() -> Int { ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").count }
        XCTAssertEqual(lines(), 1)
        // The installed process handler routes to the logger too.
        NSGetUncaughtExceptionHandler()?(NSException(name: .genericException, reason: "again", userInfo: nil))
        XCTAssertEqual(lines(), 2)
        XCTAssertEqual(previousHandlerCalls, 2)
        CrashHandler.unregister(logger)
    }

    // MARK: Events

    func testEventsIdentifyAndMetaCommit() async throws {
        let logger = makeLogger()
        let anon = logger.distinctId
        XCTAssertTrue(anon.hasPrefix("anon_"))
        logger.screen("Home")
        logger.identify("user-1", properties: ["email": "a@b.c"])
        logger.setPersonProperties(["plan": "pro"])
        await logger.flush()
        XCTAssertEqual(logger.distinctId, "user-1")
        XCTAssertEqual(logger.userId, "user-1")

        let bodies = MockURLProtocol.bodies
        XCTAssertEqual(bodies.count, 2) // logs/events, then profile updates
        let events = docWrites([bodies[0]], collection: "events").map { $0.fields }
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(str(events[0]["event"]), "$screen")
        XCTAssertEqual(str(events[0]["distinctId"]), anon)
        XCTAssertEqual(str(mapFields(events[0]["properties"])["$screen_name"]), "Home")
        XCTAssertEqual(str(events[1]["event"]), "$identify")
        XCTAssertEqual(str(events[1]["distinctId"]), "user-1")
        XCTAssertEqual(str(mapFields(events[1]["properties"])["$anon_distinct_id"]), anon)
        XCTAssertEqual(Set(events[1].keys), ["event", "distinctId", "ts", "key", "service", "properties"])

        let meta = bodies[1].writes
        XCTAssertTrue(meta.allSatisfy { $0["currentDocument"] == nil })
        let persons = meta.filter { $0.docName.contains("/persons/") }
        let identify = try XCTUnwrap(persons.first { $0.docName.hasSuffix("/persons/user-1") && mapFields($0.fields["properties"])["email"] != nil })
        XCTAssertEqual((identify["updateMask"] as? [String: Any])?["fieldPaths"] as? [String], ["key", "properties.`email`"])
        let transforms = identify["updateTransforms"] as? [[String: Any]] ?? []
        XCTAssertEqual(transforms.map { $0["fieldPath"] as? String }, ["lastSeen", "firstSeen", "aliases"])
        let aliases = ((transforms[2]["appendMissingElements"] as? [String: Any])?["values"] as? [Any])?.compactMap(str)
        XCTAssertEqual(aliases, [anon])
        XCTAssertNotNil((transforms[1]["minimum"] as? [String: Any])?["integerValue"] as? String)
        XCTAssertTrue(persons.contains { mapFields($0.fields["properties"])["plan"] != nil })
        let defs = meta.filter { $0.docName.contains("/eventDefs/") }
        XCTAssertEqual(Set(defs.map { $0.docName.components(separatedBy: "/").last! }), ["$screen", "$identify"])
        XCTAssertEqual(logger.pending, 0)

        logger.reset()
        XCTAssertNil(logger.userId)
        XCTAssertTrue(logger.distinctId.hasPrefix("anon_"))
        XCTAssertNotEqual(logger.distinctId, anon)
    }

    func testEventPropertiesCapped() async {
        let logger = makeLogger()
        var props: [String: Any] = [:]
        for i in 0..<200 { props["p\(i)"] = i }
        logger.capture("big", properties: props)
        logger.capture("   ") // ignored
        await logger.flush()
        let e = docWrites(MockURLProtocol.bodies, collection: "events")
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(mapFields(e[0].fields["properties"]).count, 128)
    }

    func testMinLevel() async {
        let logger = AppTrackLogger(
            firebaseProjectId: "fb", projectId: "p", ingestKey: key, service: "svc", minLevel: .warn,
            flushInterval: 3600, session: MockURLProtocol.session())
        logger.debug("no")
        logger.info("no")
        logger.warn("yes")
        await logger.flush()
        XCTAssertEqual(docWrites(MockURLProtocol.bodies).count, 1)
    }
}

private var previousHandlerCalls = 0

