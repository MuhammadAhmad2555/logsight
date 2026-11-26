import Foundation
@testable import AppTrack

/// Records every commit and answers with the status `handler` returns
/// (-1 = network error). The handler runs off the URLSession thread and
/// may block (to hold a request in flight).
final class MockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _handler: (([String: Any]) -> Int) = { _ in 200 }
    private static var _bodies: [[String: Any]] = []

    static var handler: ([String: Any]) -> Int {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); _handler = newValue; lock.unlock() }
    }

    /// Request bodies received so far, oldest first.
    static var bodies: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return _bodies
    }

    static func reset(status: Int = 200) {
        lock.lock()
        _bodies = []
        _handler = { _ in status }
        lock.unlock()
    }

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            stream.close()
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let url = request.url!
        DispatchQueue.global().async {
            MockURLProtocol.lock.lock()
            MockURLProtocol._bodies.append(body)
            let h = MockURLProtocol._handler
            MockURLProtocol.lock.unlock()
            let status = h(body)
            // 4091 = 409 ABORTED (contention).
            let aborted = status == 4091
            let code = aborted ? 409 : status
            if status < 0 {
                self.client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let resp = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            let reply: String
            switch status {
            case 4091: reply = #"{"error":{"code":409,"message":"Too much contention on these documents.","status":"ABORTED"}}"#
            case 409: reply = #"{"error":{"code":409,"message":"Document already exists","status":"ALREADY_EXISTS"}}"#
            case 403: reply = #"{"error":{"code":403,"message":"Missing or insufficient permissions.","status":"PERMISSION_DENIED"}}"#
            default: reply = "{}"
            }
            self.client?.urlProtocol(self, didLoad: Data(reply.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

// MARK: - Body helpers

extension Dictionary where Key == String, Value == Any {
    var writes: [[String: Any]] { self["writes"] as? [[String: Any]] ?? [] }
}

extension Dictionary where Key == String, Value == Any {
    /// `update.name` of a write.
    var docName: String { (self["update"] as? [String: Any])?["name"] as? String ?? "" }
    /// `update.fields` of a write.
    var fields: [String: Any] { (self["update"] as? [String: Any])?["fields"] as? [String: Any] ?? [:] }
}

func str(_ v: Any?) -> String? { (v as? [String: Any])?["stringValue"] as? String }
func mapFields(_ v: Any?) -> [String: Any] {
    ((v as? [String: Any])?["mapValue"] as? [String: Any])?["fields"] as? [String: Any] ?? [:]
}
func arrayStrings(_ v: Any?) -> [String] {
    let values = ((v as? [String: Any])?["arrayValue"] as? [String: Any])?["values"] as? [Any] ?? []
    return values.compactMap { str($0) }
}

/// Log/event writes (not the service registration) across all bodies.
func docWrites(_ bodies: [[String: Any]], collection: String = "logs") -> [[String: Any]] {
    bodies.flatMap { $0.writes }.filter { $0.docName.contains("/\(collection)/") }
}

func parseTimestamp(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s)
}

/// A tiny stand-in for Firestore's commit: atomic, rejects a commit with
/// 409 if any `currentDocument.exists=false` write names a stored doc, 403
/// if any log's message is "bad". `loseResponses` makes it store the
/// commit but fail the response (network error), like a lost reply.
final class FakeFirestore {
    private let lock = NSLock()
    private(set) var stored: [String] = []
    var loseResponses = false

    func install() {
        MockURLProtocol.handler = { [self] body in self.handle(body) }
    }

    func handle(_ body: [String: Any]) -> Int {
        lock.lock(); defer { lock.unlock() }
        let creates = body.writes.filter { $0["currentDocument"] != nil }
        if creates.contains(where: { stored.contains($0.docName) }) { return 409 }
        if creates.contains(where: { str($0.fields["message"]) == "bad" }) { return 403 }
        stored += creates.map { $0.docName }
        return loseResponses ? -1 : 200
    }

    var storedIds: [String] {
        lock.lock(); defer { lock.unlock() }
        return stored.map { $0.components(separatedBy: "/").last! }
    }
}
