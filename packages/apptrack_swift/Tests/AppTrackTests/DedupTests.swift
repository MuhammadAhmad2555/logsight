import Foundation
import XCTest
#if canImport(AppKit) && !canImport(UIKit)
import AppKit
#endif
@testable import AppTrack

private let key = String(repeating: "k", count: 40)

final class DedupTests: XCTestCase {
    var tempDir: URL!
    var fake: FakeFirestore!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        fake = FakeFirestore()
        fake.install()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("apptrack-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func makeLogger(queueFile: URL? = nil, flushOnBackground: Bool = false) -> AppTrackLogger {
        AppTrackLogger(
            firebaseProjectId: "fb", projectId: "p1", ingestKey: key, service: "ios_app",
            flushInterval: 3600, queueFileURL: queueFile, flushOnBackground: flushOnBackground,
            session: MockURLProtocol.session())
    }

    /// Doc names of log/event writes in body `i`.
    func names(_ i: Int) -> [String] {
        MockURLProtocol.bodies[i].writes.filter { $0["currentDocument"] != nil }.map { $0.docName }
    }

    func testRetryAfterLostResponseReusesIds() async {
        fake.loseResponses = true
        let logger = makeLogger()
        logger.info("a")
        logger.capture("signup")
        await logger.flush()
        XCTAssertEqual(logger.pending, 3) // 2 items + eventDef meta
        XCTAssertEqual(fake.stored.count, 2) // stored, but the reply was lost

        fake.loseResponses = false
        logger.resetBackoff()
        await logger.flush()
        XCTAssertEqual(names(1), names(0)) // same document IDs on the retry
        XCTAssertTrue(names(0).allSatisfy { $0.components(separatedBy: "/").last!.count == 20 })
        // 409 for the batch, then each alone: both already stored.
        XCTAssertEqual(logger.duplicates, 2)
        XCTAssertEqual(logger.dropped, 0)
        XCTAssertEqual(logger.pending, 0)
        XCTAssertEqual(fake.stored.count, 2)
    }

    func testRestartFromQueueFileReusesIds() async throws {
        let file = tempDir.appendingPathComponent("queue.jsonl")
        fake.loseResponses = true
        var firstNames: [String] = []
        do {
            let first = makeLogger(queueFile: file)
            first.info("a")
            first.capture("purchase", id: "txn_42")
            await first.flush()
            firstNames = names(0)
        }
        XCTAssertEqual(fake.stored.count, 2)
        XCTAssertTrue(firstNames[1].hasSuffix("/events/txn_42"))

        fake.loseResponses = false
        let second = makeLogger(queueFile: file)
        XCTAssertEqual(second.restored, 2)
        await second.flush()
        let resent = MockURLProtocol.bodies.dropFirst().flatMap { $0.writes }
            .filter { $0["currentDocument"] != nil }.map { $0.docName }
        XCTAssertEqual(Set(resent), Set(firstNames))
        XCTAssertEqual(second.duplicates, 2)
        XCTAssertEqual(second.pending, 0)
        XCTAssertEqual(fake.stored.count, 2)
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int
        XCTAssertEqual(size, 0)
    }

    func testSingle409CountsAsDelivered() async {
        let logger = makeLogger()
        logger.capture("purchase", id: "txn_1")
        await logger.flush()
        logger.capture("purchase", id: "txn_1")
        await logger.flush()
        XCTAssertEqual(fake.storedIds, ["txn_1"])
        XCTAssertEqual(logger.duplicates, 1)
        XCTAssertEqual(logger.dropped, 0)
        XCTAssertEqual(logger.pending, 0)
    }

    func testMixed409SplitsBatch() async {
        let logger = makeLogger()
        logger.capture("purchase", id: "txn_1")
        await logger.flush()
        let before = MockURLProtocol.bodies.count
        logger.capture("purchase", id: "txn_1")
        logger.info("new", id: "log_new")
        await logger.flush()
        let bodies = MockURLProtocol.bodies.count - before
        XCTAssertGreaterThanOrEqual(bodies, 3) // batch (409), then each alone
        XCTAssertEqual(names(before).count, 2)
        XCTAssertEqual(names(before + 1).count, 1)
        XCTAssertEqual(names(before + 2).count, 1)
        XCTAssertEqual(fake.storedIds.sorted(), ["log_new", "txn_1"])
        XCTAssertEqual(logger.duplicates, 1)
        XCTAssertEqual(logger.dropped, 0)
        XCTAssertEqual(logger.pending, 0)
    }

    func testMixed403DropsOnlyBadItem() async {
        let logger = makeLogger()
        logger.info("ok1")
        logger.info("bad")
        logger.info("ok2")
        await logger.flush()
        XCTAssertEqual(MockURLProtocol.bodies.count, 4) // batch (403), then each alone
        XCTAssertEqual(fake.stored.count, 2)
        XCTAssertEqual(logger.dropped, 1)
        XCTAssertEqual(logger.duplicates, 0)
        XCTAssertEqual(logger.pending, 0)
        // The service write rode along until the first 200, then stopped.
        let serviceWrites = MockURLProtocol.bodies.map {
            $0.writes.filter { $0.docName.contains("/services/") }.count
        }
        XCTAssertEqual(Array(serviceWrites.prefix(4)), [1, 1, 0, 0])
    }

    func testNetworkErrorDuringSplitKeepsRest() async {
        let logger = makeLogger()
        logger.capture("purchase", id: "txn_1")
        await logger.flush()
        let before = MockURLProtocol.bodies.count
        // Next: batch 409, first alone 409, second alone fails.
        let calls = Atomic(0)
        MockURLProtocol.handler = { [fake] body in
            let n = calls.swap(0) // requests are sent one after another
            _ = calls.swap(n + 1)
            return n >= 2 ? -1 : fake!.handle(body)
        }
        logger.capture("purchase", id: "txn_1")
        logger.info("later")
        await logger.flush()
        XCTAssertEqual(MockURLProtocol.bodies.count - before, 3)
        XCTAssertEqual(logger.duplicates, 1)
        XCTAssertEqual(logger.pending, 1)
        let laterName = names(before + 2)[0]

        fake.install()
        logger.resetBackoff()
        await logger.flush()
        XCTAssertEqual(logger.pending, 0)
        XCTAssertEqual(names(MockURLProtocol.bodies.count - 1), [laterName])
        XCTAssertEqual(fake.stored.count, 2)
        XCTAssertEqual(logger.dropped, 0)
    }

    func test409AbortedIsRetriedNotDelivered() async {
        MockURLProtocol.reset(status: 4091)
        let logger = makeLogger()
        logger.info("a")
        logger.info("b")
        await logger.flush()
        XCTAssertEqual(MockURLProtocol.bodies.count, 1) // no split: backs off
        XCTAssertEqual(logger.pending, 2)
        XCTAssertEqual(logger.duplicates, 0)
        XCTAssertEqual(logger.dropped, 0)
        let firstNames = names(0)

        // Single item: also retried, never counted as delivered.
        let single = makeLogger()
        single.info("solo")
        await single.flush()
        XCTAssertEqual(single.pending, 1)
        XCTAssertEqual(single.duplicates, 0)

        fake.install()
        logger.resetBackoff()
        await logger.flush()
        XCTAssertEqual(logger.pending, 0)
        XCTAssertEqual(logger.duplicates, 0)
        XCTAssertEqual(names(MockURLProtocol.bodies.count - 1), firstNames)
        XCTAssertEqual(fake.stored.count, 2)
    }

    func testCustomIds() async {
        let logger = makeLogger()
        let long = String(repeating: "x", count: 201)
        let invalid = ["a/b", ".", "..", "__x__", "", long]
        for id in invalid { logger.info("m", id: id) }
        logger.info("m", id: "__x")
        logger.info("m", id: String(repeating: "y", count: 200))
        logger.error("e", id: "err-1")
        logger.capture("evt", id: "evt_1")
        await logger.flush()
        let ids = names(0).map { $0.components(separatedBy: "/").last! }
        XCTAssertEqual(ids.count, invalid.count + 4)
        for id in ids.prefix(invalid.count) {
            XCTAssertEqual(id.count, 20)
            XCTAssertTrue(id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
        }
        XCTAssertEqual(Array(ids.suffix(4)), ["__x", String(repeating: "y", count: 200), "err-1", "evt_1"])
        XCTAssertTrue(names(0).last!.hasSuffix("/events/evt_1"))
        XCTAssertTrue(names(0)[invalid.count + 2].contains("/logs/err-1"))
    }

    #if canImport(AppKit) && !canImport(UIKit)
    func testFlushesWhenAppResignsActive() async throws {
        let logger = makeLogger(flushOnBackground: true)
        let quiet = makeLogger(flushOnBackground: false)
        logger.info("bg")
        quiet.info("quiet")
        NotificationCenter.default.post(name: NSApplication.willResignActiveNotification, object: nil)
        for _ in 0..<50 where logger.pending > 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(logger.pending, 0)
        XCTAssertEqual(quiet.pending, 1)
    }
    #endif
}
