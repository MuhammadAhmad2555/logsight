import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Log levels, lowest first.
public enum LogLevel: Int, Comparable, CaseIterable {
    case trace, debug, info, warn, error, fatal

    public var name: String {
        switch self {
        case .trace: return "trace"
        case .debug: return "debug"
        case .info: return "info"
        case .warn: return "warn"
        case .error: return "error"
        case .fatal: return "fatal"
        }
    }

    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
}

/// Queues logs and product events and sends them to LogSight in batches.
///
/// Every method may be called from any thread. Logging never throws and
/// never blocks on the network.
public final class AppTrackLogger: @unchecked Sendable {
    public let firebaseProjectId: String
    public let projectId: String
    public let ingestKey: String
    /// Shown as `service_name` in LogSight.
    public let service: String
    /// Added to every log, e.g. app version or environment.
    public let defaultAttributes: [String: LogValue]
    public let minLevel: LogLevel
    public let batchSize: Int
    public let flushInterval: TimeInterval
    public let maxQueue: Int
    /// If set, queued logs and events are also kept in this file so they
    /// survive the app being killed or crashing and are sent next launch.
    public let queueFileURL: URL?
    /// Logs get `expireAt = ts + retentionDays` (clamped to 1…400) so the
    /// server can delete them. nil omits the field.
    public let retentionDays: Int?
    public let printToConsole: Bool
    /// Flush when the app goes to the background (iOS, tvOS, Mac Catalyst:
    /// `didEnterBackground`, inside a background task) or stops being the
    /// active app (macOS: `willResignActive`).
    public let flushOnBackground: Bool

    /// Token added to request logs so the dashboard can find them quickly.
    public static let requestToken = "http_request"
    /// Uncaught errors recorded per error (type + message) per minute.
    public static let crashRepeatLimit = 5

    private let session: URLSession
    private let lock = NSRecursiveLock()
    private let store: QueueStore?
    private var timer: DispatchSourceTimer?

    // Everything below is guarded by `lock`.
    private var queue: [QueueItem] = []
    private var meta: [[String: Any]] = []
    private var knownEvents: [String: Set<String>] = [:]
    private var seq = 0
    private var inFlight: Task<Void, Never>?
    private var failures = 0
    private var retryAfter = Date.distantPast
    private var closed = false
    private var serviceRegistered = false
    private var recentCrashes: [String: (Date, Int)] = [:]
    private var _userId: String?
    private var _sessionId: String?
    private var _distinctId: String
    private var _dropped = 0
    private var _restored = 0
    private var _duplicates = 0
    private var backgroundObserver: NSObjectProtocol?

    /// - Parameters:
    ///   - firebaseProjectId: the Firebase project LogSight runs on.
    ///   - projectId: your LogSight project ID.
    ///   - ingestKey: an active ingest key of the project.
    ///   - service: this app's service name, e.g. `my_ios_app`.
    ///   - distinctId: who events belong to; pass back the stored
    ///     `distinctId` each launch so one person keeps one ID.
    ///   - session: URLSession to send with (tests pass one with a mock).
    public init(
        firebaseProjectId: String,
        projectId: String,
        ingestKey: String,
        service: String,
        defaultAttributes: [String: Any] = [:],
        minLevel: LogLevel = .trace,
        batchSize: Int = 50,
        flushInterval: TimeInterval = 5,
        maxQueue: Int = 5000,
        queueFileURL: URL? = nil,
        retentionDays: Int? = 90,
        printToConsole: Bool = false,
        flushOnBackground: Bool = true,
        distinctId: String? = nil,
        session: URLSession? = nil
    ) {
        self.firebaseProjectId = firebaseProjectId
        self.projectId = projectId
        self.ingestKey = ingestKey
        self.service = service
        self.defaultAttributes = defaultAttributes.mapValues { LogValue($0) }
        self.minLevel = minLevel
        self.batchSize = min(max(batchSize, 1), 500)
        self.flushInterval = max(flushInterval, 0.1)
        self.maxQueue = max(maxQueue, 1)
        self.queueFileURL = queueFileURL
        self.retentionDays = retentionDays.map { min(max($0, 1), 400) }
        self.printToConsole = printToConsole
        self.flushOnBackground = flushOnBackground
        self.session = session ?? URLSession(configuration: .default)
        self.store = queueFileURL.map { QueueStore(url: $0) }
        _distinctId = distinctId ?? AppTrackLogger.anonId()
        restoreQueue()
        startTimer()
        if flushOnBackground { observeBackground() }
    }

    deinit {
        timer?.cancel()
        if let o = backgroundObserver { NotificationCenter.default.removeObserver(o) }
        CrashHandler.unregister(self)
    }

    // MARK: - State

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Attached to every following log.
    public var userId: String? {
        get { locked { _userId } }
        set { locked { _userId = newValue } }
    }

    /// Attached to every following log and event.
    public var sessionId: String? {
        get { locked { _sessionId } }
        set { locked { _sessionId = newValue } }
    }

    /// Who events belong to (PostHog's distinct_id). A random `anon_…` ID
    /// until `identify`. Persist it and pass it back in next launch.
    public var distinctId: String { locked { _distinctId } }

    /// Logs dropped because the queue was full or the server rejected them.
    public var dropped: Int { locked { _dropped } }

    /// Logs and events the server already had (an earlier send was stored
    /// but its response was lost, or a custom `id` was sent again).
    public var duplicates: Int { locked { _duplicates } }

    /// Logs and events restored from `queueFileURL` at startup.
    public var restored: Int { locked { _restored } }

    /// Logs, events and profile updates not yet delivered.
    public var pending: Int { locked { queue.count + meta.count } }

    private var endpoint: URL {
        URL(string: "https://firestore.googleapis.com/v1/projects/\(firebaseProjectId)/databases/(default)/documents:commit")!
    }

    private var root: String {
        "projects/\(firebaseProjectId)/databases/(default)/documents/projects/\(projectId)"
    }

    // MARK: - Logs

    public func trace(_ message: String, attributes: [String: Any]? = nil, traceId: String? = nil, id: String? = nil) {
        log(.trace, message, attributes: attributes, traceId: traceId, id: id)
    }

    public func debug(_ message: String, attributes: [String: Any]? = nil, traceId: String? = nil, id: String? = nil) {
        log(.debug, message, attributes: attributes, traceId: traceId, id: id)
    }

    public func info(_ message: String, attributes: [String: Any]? = nil, traceId: String? = nil, id: String? = nil) {
        log(.info, message, attributes: attributes, traceId: traceId, id: id)
    }

    public func warn(_ message: String, attributes: [String: Any]? = nil, traceId: String? = nil, id: String? = nil) {
        log(.warn, message, attributes: attributes, traceId: traceId, id: id)
    }

    /// Logs an error. `error` records its Swift type and description,
    /// `stackTrace` defaults to `Thread.callStackSymbols`, `reason` is your
    /// own explanation.
    public func error(
        _ message: String, attributes: [String: Any]? = nil, traceId: String? = nil,
        error: Error? = nil, stackTrace: String? = nil, reason: String? = nil, id: String? = nil
    ) {
        log(.error, message, attributes: attributes, traceId: traceId,
            error: error, stackTrace: stackTrace ?? Self.currentStack(), reason: reason, id: id)
    }

    /// Like `error`, for crashes and unrecoverable failures.
    public func fatal(
        _ message: String, attributes: [String: Any]? = nil, traceId: String? = nil,
        error: Error? = nil, stackTrace: String? = nil, reason: String? = nil, id: String? = nil
    ) {
        log(.fatal, message, attributes: attributes, traceId: traceId,
            error: error, stackTrace: stackTrace ?? Self.currentStack(), reason: reason, id: id)
    }

    /// Queues one log. Error details are kept on error and fatal logs only.
    ///
    /// `id` is an optional document ID (1–200 characters, no `/`, not `.`,
    /// `..` or `__…__`): a log sent twice with the same `id` is stored once.
    /// An invalid one is replaced by a random ID.
    public func log(
        _ level: LogLevel, _ message: String, attributes: [String: Any]? = nil, traceId: String? = nil,
        timestamp: Date? = nil, error: Error? = nil, stackTrace: String? = nil, reason: String? = nil,
        id: String? = nil
    ) {
        let details = level >= .error
            ? errorDetails(
                type: error.map(errorTypeName), message: error.map { String(describing: $0) },
                reason: reason, stack: stackTrace)
            : nil
        enqueueLog(level, message, attributes: (attributes ?? [:]).mapValues { LogValue($0) },
                   traceId: traceId, timestamp: timestamp, details: details, id: id)
    }

    /// Logs one API request for the Endpoints page. Use the route pattern,
    /// not the full URL (`/api/orders/:id`). 5xx (or an error without a
    /// status) is an error, 4xx a warning, anything else info.
    public func request(
        method: String, route: String, statusCode: Int? = nil, duration: TimeInterval? = nil,
        attributes: [String: Any]? = nil, traceId: String? = nil, error: Error? = nil,
        stackTrace: String? = nil
    ) {
        let m = method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let r = route.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.isEmpty { return }
        let ms = duration.map { $0 * 1000 }
        let level: LogLevel
        if let s = statusCode {
            level = s >= 500 ? .error : (s >= 400 ? .warn : .info)
        } else {
            level = error != nil ? .error : .info
        }
        var parts = [m, r]
        if let s = statusCode { parts.append("\(s)") }
        if let ms = ms { parts.append("(\(Int(ms.rounded(.toNearestOrAwayFromZero))) ms)") }
        if statusCode == nil && error != nil { parts.append("failed") }

        var http: [String: LogValue] = ["http.method": .string(m), "http.route": .string(r)]
        if let s = statusCode { http["http.status_code"] = .int(Int64(s)) }
        if let ms = ms { http["duration_ms"] = .double((ms * 10).rounded(.toNearestOrAwayFromZero) / 10) }
        var attrs = (attributes ?? [:]).mapValues { LogValue($0) }
        attrs.merge(http) { _, h in h }
        let details = level >= .error
            ? errorDetails(
                type: error.map(errorTypeName), message: error.map { String(describing: $0) },
                reason: nil, stack: stackTrace ?? (error != nil ? Self.currentStack() : nil))
            : nil
        enqueueLog(level, parts.joined(separator: " "), attributes: attrs, traceId: traceId,
                   details: details, extraTokens: [Self.requestToken], priorityKeys: Array(http.keys))
    }

    /// Records an error the app caught itself (`error.handled = true`).
    /// Repeats of the same error beyond `crashRepeatLimit` per minute are skipped.
    public func recordError(_ error: Error, fatal: Bool = false, reason: String? = nil) {
        let text = String(describing: error)
        recordUncaught(
            type: errorTypeName(error), message: text, reason: reason, stack: Self.currentStack(),
            mechanism: "recordError", handled: true, fatal: fatal, flushNow: true)
    }

    private func enqueueLog(
        _ level: LogLevel, _ message: String, attributes: [String: LogValue], traceId: String?,
        timestamp: Date? = nil, details: [String: LogValue]?, extraTokens: [String] = [],
        priorityKeys: [String] = [], id: String? = nil, flushNow: Bool = true
    ) {
        locked {
            if closed || level < minLevel { return }
            if printToConsole { print("[\(level.name.uppercased())] \(service): \(message)") }
            let attrs = Self.capAttributes(defaults: defaultAttributes, custom: attributes, priority: priorityKeys)
            let text = cut(message, 10000)
            let ts = timestamp ?? Date()
            var tokens = extraTokens
            for t in tokenize(text, maxTokens: 64 - extraTokens.count) where !tokens.contains(t) {
                tokens.append(t)
            }
            var f: [String: LogValue] = [
                "ts": .date(ts),
                "severity": .string(level.name),
                "message": .string(text),
                "service": .string(service),
                "key": .string(ingestKey),
                "tokens": .array(tokens.map { .string($0) }),
            ]
            if let days = retentionDays { f["expireAt"] = .date(Self.expireAt(ts, days: days)) }
            if !attrs.isEmpty { f["attributes"] = .map(attrs) }
            if let u = _userId { f["userId"] = .string(cut(u, 128)) }
            if let s = _sessionId { f["sessionId"] = .string(cut(s, 128)) }
            if let t = traceId { f["traceId"] = .string(cut(t, 128)) }
            if let d = details { f["error"] = .map(d) }
            enqueue(.log, f, id: id, flushNow: flushNow)
        }
    }

    /// `ts + days`, nudged 1 s inward so millisecond rounding of either
    /// timestamp can never push it outside the server's 1…400 day window.
    static func expireAt(_ ts: Date, days: Int) -> Date {
        ts.addingTimeInterval(Double(days) * 86400 + (days <= 200 ? 1 : -1))
    }

    /// Defaults merged with custom attributes (custom wins), at most 64:
    /// `priority` keys first, then defaults, then the rest, by name.
    static func capAttributes(
        defaults: [String: LogValue], custom: [String: LogValue], priority: [String] = []
    ) -> [String: LogValue] {
        var all = defaults
        all.merge(custom) { _, c in c }
        if all.count <= 64 { return all }
        var order = priority.filter { all[$0] != nil }
        order += defaults.keys.sorted().filter { !order.contains($0) && custom[$0] == nil }
        order += all.keys.sorted().filter { !order.contains($0) }
        var out: [String: LogValue] = [:]
        for k in order.prefix(64) { out[k] = all[k] }
        return out
    }

    private static func currentStack() -> String {
        Thread.callStackSymbols.dropFirst(2).joined(separator: "\n")
    }

    // MARK: - Events

    /// Records a product event (PostHog's `capture`). At most 128 properties.
    ///
    /// `id` is an optional document ID, e.g. a purchase's transaction ID:
    /// the same `id` sent twice is stored once. Rules as for `log(id:)`.
    public func capture(
        _ event: String, properties: [String: Any]? = nil, timestamp: Date? = nil, id: String? = nil
    ) {
        capture(event, values: (properties ?? [:]).mapValues { LogValue($0) }, timestamp: timestamp, id: id)
    }

    private func capture(_ event: String, values: [String: LogValue], timestamp: Date?, id: String? = nil) {
        let name = event.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return }
        locked {
            if closed { return }
            var props = values
            if props.count > 128 {
                let keep = Set(props.keys.sorted().prefix(128))
                props = props.filter { keep.contains($0.key) }
            }
            var f: [String: LogValue] = [
                "event": .string(cut(name, 200)),
                "distinctId": .string(cut(_distinctId, 200)),
                "ts": .date(timestamp ?? Date()),
                "key": .string(ingestKey),
                "service": .string(service),
            ]
            if let s = _sessionId { f["sessionId"] = .string(cut(s, 128)) }
            if !props.isEmpty { f["properties"] = .map(props) }
            enqueue(.event, f, id: id)
            registerEvent(name, Array(props.keys))
        }
    }

    /// A screen view (`$screen` with `$screen_name`).
    public func screen(_ name: String, properties: [String: Any]? = nil) {
        var p = (properties ?? [:]).mapValues { LogValue($0) }
        p["$screen_name"] = .string(name)
        capture("$screen", values: p, timestamp: nil)
    }

    /// Links the current (usually anonymous) ID to `userId` and makes it the
    /// ID for following events and logs. `properties` are set on the person.
    public func identify(_ userId: String, properties: [String: Any]? = nil) {
        let id = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty { return }
        locked {
            if closed { return }
            let previous = _distinctId
            _distinctId = id
            _userId = id
            person(id, (properties ?? [:]).mapValues { LogValue($0) }, aliases: previous != id ? [previous] : [])
            var p: [String: LogValue] = [:]
            if previous != id { p["$anon_distinct_id"] = .string(previous) }
            capture("$identify", values: p, timestamp: nil)
        }
    }

    /// Sets properties on the current person (merged with existing ones).
    public func setPersonProperties(_ properties: [String: Any]) {
        if properties.isEmpty { return }
        locked {
            if closed { return }
            person(_distinctId, properties.mapValues { LogValue($0) })
        }
    }

    /// Call on sign-out: starts a new anonymous person and clears `userId`.
    public func reset() {
        locked {
            _distinctId = Self.anonId()
            _userId = nil
        }
    }

    static func docIdOk(_ s: String) -> Bool {
        !s.isEmpty && s.utf16.count <= 200 && !s.contains("/") && s != "." && s != ".."
            && !(s.count >= 4 && s.hasPrefix("__") && s.hasSuffix("__"))
    }

    static func serviceIdOk(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 100, s != ".", s != ".." else { return false }
        return s.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-").contains($0)
        }
    }

    private static func quote(_ key: String) -> String {
        "`" + key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`") + "`"
    }

    /// Must be called under `lock`.
    private func person(_ id: String, _ props: [String: LogValue], aliases: [String] = []) {
        if !Self.docIdOk(id) { return }
        var p = props
        if p.count > 200 {
            let keep = Set(p.keys.sorted().prefix(200))
            p = p.filter { keep.contains($0.key) }
        }
        let keys = p.keys.sorted()
        var fields: [String: Any] = ["key": ["stringValue": ingestKey]]
        if !p.isEmpty { fields["properties"] = LogValue.map(p).firestore }
        var transforms: [[String: Any]] = [
            ["fieldPath": "lastSeen", "setToServerValue": "REQUEST_TIME"],
            ["fieldPath": "firstSeen",
             "minimum": ["integerValue": String(Int64(Date().timeIntervalSince1970 * 1000))]],
        ]
        if !aliases.isEmpty {
            transforms.append(["fieldPath": "aliases",
                               "appendMissingElements": ["values": aliases.map { ["stringValue": $0] }]])
        }
        meta.append([
            "update": ["name": "\(root)/persons/\(id)", "fields": fields],
            "updateMask": ["fieldPaths": ["key"] + keys.map { "properties.\(Self.quote($0))" }],
            "updateTransforms": transforms,
        ])
    }

    /// Must be called under `lock`.
    private func registerEvent(_ name: String, _ propertyKeys: [String]) {
        if !Self.docIdOk(name) { return }
        let known = knownEvents[name]
        let fresh = propertyKeys.sorted().filter { known == nil || !known!.contains($0) }
        if known != nil && fresh.isEmpty { return }
        knownEvents[name, default: []].formUnion(fresh)
        var transforms: [[String: Any]] = [["fieldPath": "lastSeen", "setToServerValue": "REQUEST_TIME"]]
        if !fresh.isEmpty {
            transforms.append(["fieldPath": "properties",
                               "appendMissingElements": ["values": fresh.prefix(300).map { ["stringValue": $0] }]])
        }
        meta.append([
            "update": ["name": "\(root)/eventDefs/\(name)", "fields": ["key": ["stringValue": ingestKey]]],
            "updateMask": ["fieldPaths": ["key"]],
            "updateTransforms": transforms,
        ])
    }

    // MARK: - Queue

    /// Must be called under `lock`.
    private func enqueue(
        _ kind: QueueItem.Kind, _ fields: [String: LogValue], id: String? = nil, flushNow: Bool = true
    ) {
        seq += 1
        let docId = id.flatMap { Self.docIdOk($0) ? $0 : nil } ?? Self.randomId()
        let item = QueueItem(seq: seq, kind: kind, docId: docId, fields: fields)
        queue.append(item)
        store?.added(item)
        if queue.count > maxQueue {
            let extra = queue.count - maxQueue
            let last = queue[extra - 1].seq
            queue.removeFirst(extra)
            _dropped += extra
            store?.removed(upTo: last, remaining: queue)
        }
        if flushNow && queue.count >= batchSize { startFlush() }
    }

    /// Removes everything up to sequence number `upTo` (sent or rejected).
    /// By sequence number, not position: while a batch is in flight newer
    /// items may be added and older ones dropped (queue full).
    private func remove(upTo: Int) {
        queue.removeAll { $0.seq <= upTo }
        store?.removed(upTo: upTo, remaining: queue)
    }

    private func restoreQueue() {
        guard let store = store else { return }
        let (items, skipped) = store.load(limit: maxQueue)
        _dropped += skipped
        guard let last = items.last else { return }
        queue = items
        seq = last.seq
        _restored = items.count
        // Send them soon, not after the first flush interval.
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.startFlush() }
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
        t.setEventHandler { [weak self] in self?.startFlush() }
        t.resume()
        timer = t
    }

    // MARK: - Sending

    /// Sends everything queued. Safe to call often; concurrent calls share
    /// one send. Returns immediately while backing off after a failure.
    public func flush() async {
        await startFlush()?.value
    }

    @discardableResult
    private func startFlush() -> Task<Void, Never>? {
        locked {
            if let running = inFlight { return running }
            if (queue.isEmpty && meta.isEmpty) || Date() < retryAfter { return nil }
            let task = Task.detached(priority: .utility) { [self] in
                await self.drain()
                self.locked { self.inFlight = nil }
            }
            inFlight = task
            return task
        }
    }

    private enum SendResult { case ok, duplicate, rejected, retry }

    private func drain() async {
        while true {
            guard let batch = locked({ queue.isEmpty ? nil : Array(queue.prefix(batchSize)) }) else { break }
            let status = await sendItems(batch)
            if status == .retry {
                locked { backoff() }
                return
            }
            if status == .ok || batch.count == 1 {
                resolve(batch, as: status)
                continue
            }
            // 409 (some already stored) or 400/403 (some invalid): a commit is
            // all-or-nothing, so resend one at a time to find out which.
            for item in batch {
                let single = await sendItems([item])
                if single == .retry {
                    locked { backoff() }
                    return
                }
                resolve([item], as: single)
            }
        }
        while true {
            guard let batch = locked({ meta.isEmpty ? nil : Array(meta.prefix(400)) }) else { break }
            let status = await commit(batch, what: "profile updates")
            let stop: Bool = locked {
                if status == .retry {
                    backoff()
                    return true
                }
                meta.removeFirst(min(batch.count, meta.count))
                return false
            }
            if stop { return }
        }
    }

    /// Removes `items` (a prefix of the queue when sent) once the server has
    /// answered for them. By sequence number, not position: while they were
    /// in flight newer items may have been added and older ones dropped.
    private func resolve(_ items: [QueueItem], as status: SendResult) {
        guard let last = items.last else { return }
        locked {
            remove(upTo: last.seq)
            failures = 0
            switch status {
            case .duplicate:
                // Stored by an earlier send whose response was lost.
                _duplicates += items.count
            case .rejected:
                _dropped += items.count
            case .ok:
                // Keep "last seen" current for everyone who just sent events.
                var people: [String] = []
                for item in items where item.kind == .event {
                    if case .string(let id)? = item.fields["distinctId"], !people.contains(id) {
                        people.append(id)
                    }
                }
                for id in people { person(id, [:]) }
            case .retry:
                break
            }
        }
    }

    /// Must be called under `lock`.
    private func backoff() {
        failures += 1
        retryAfter = Date().addingTimeInterval(TimeInterval(min(300, 1 << min(failures, 9))))
    }

    /// Lets tests retry at once instead of waiting out the backoff.
    func resetBackoff() {
        locked { retryAfter = .distantPast }
    }

    /// One commit of `items`, each created under its own fixed document ID
    /// (`currentDocument.exists = false`, so a resend can't store it twice).
    /// The one-time service registration rides along until a 200.
    private func sendItems(_ items: [QueueItem]) async -> SendResult {
        let registerService = locked { !serviceRegistered && Self.serviceIdOk(service) }
        var writes: [[String: Any]] = []
        if registerService {
            // Once per logger: list this service in the project's services.
            writes.append([
                "update": ["name": "\(root)/services/\(service)",
                           "fields": ["key": ["stringValue": ingestKey]]],
                "updateMask": ["fieldPaths": ["key"]],
                "updateTransforms": [["fieldPath": "lastSeen", "setToServerValue": "REQUEST_TIME"]],
            ])
        }
        for item in items {
            let collection = item.kind == .event ? "events" : "logs"
            writes.append([
                "update": ["name": "\(root)/\(collection)/\(item.docId)",
                           "fields": item.fields.mapValues { $0.firestore }],
                "currentDocument": ["exists": false],
                "updateTransforms": [["fieldPath": "receivedAt", "setToServerValue": "REQUEST_TIME"]],
            ])
        }
        let status = await commit(writes, what: "logs/events")
        if status == .ok && registerService { locked { serviceRegistered = true } }
        return status
    }

    private func commit(_ writes: [[String: Any]], what: String) async -> SendResult {
        guard let body = try? JSONSerialization.data(withJSONObject: ["writes": writes]) else {
            return .rejected
        }
        var req = URLRequest(url: endpoint, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return await withCheckedContinuation { (cont: CheckedContinuation<SendResult, Never>) in
            session.dataTask(with: req) { [printToConsole] data, response, error in
                guard error == nil, let http = response as? HTTPURLResponse else {
                    cont.resume(returning: .retry)
                    return
                }
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                switch http.statusCode {
                case 200:
                    cont.resume(returning: .ok)
                case 409 where Self.errorStatus(data) == "ALREADY_EXISTS":
                    // A document with this ID is already stored. (409 ABORTED,
                    // i.e. contention, falls through to a retry.)
                    cont.resume(returning: .duplicate)
                case 400, 403:
                    // Bad data or a disabled key: retrying won't help.
                    if printToConsole { print("LogSight rejected \(writes.count) \(what): \(text)") }
                    cont.resume(returning: .rejected)
                default:
                    cont.resume(returning: .retry)
                }
            }.resume()
        }
    }

    /// `error.status` of a Firestore error response, e.g. `ALREADY_EXISTS`.
    static func errorStatus(_ data: Data?) -> String? {
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        return error["status"] as? String
    }

    static func randomId() -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var rng = SystemRandomNumberGenerator()
        return String((0..<20).map { _ in chars[Int(rng.next(upperBound: UInt64(chars.count)))] })
    }

    static func anonId() -> String { "anon_" + randomId() }

    // MARK: - Background

    private func observeBackground() {
        #if canImport(UIKit) && !os(watchOS)
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.flushInBackgroundTask() }
        #elseif canImport(AppKit)
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.startFlush() }
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    /// Flushes inside a background task so iOS gives the send time to finish.
    private func flushInBackgroundTask() {
        guard let task = startFlush() else { return }
        let app = UIApplication.shared
        let ended = Atomic(false)
        var id = UIBackgroundTaskIdentifier.invalid
        let end = {
            if !ended.swap(true), id != .invalid { app.endBackgroundTask(id) }
        }
        id = app.beginBackgroundTask(withName: "AppTrack flush") { end() }
        Task {
            await task.value
            DispatchQueue.main.async { end() }
        }
    }
    #endif

    /// Flushes and stops the timer. The logger can't be used afterwards.
    public func close() async {
        if let o = backgroundObserver {
            NotificationCenter.default.removeObserver(o)
            backgroundObserver = nil
        }
        timer?.cancel()
        CrashHandler.unregister(self)
        locked { retryAfter = .distantPast }
        await flush()
        locked {
            closed = true
            store?.close()
        }
    }

    // MARK: - Crashes

    /// Records uncaught Objective-C exceptions (`NSException`) as `fatal`
    /// logs. They are written to the queue file synchronously and sent on
    /// the next launch, so set `queueFileURL`. Any handler installed before
    /// is still called. Swift runtime traps (`fatalError`, force-unwrapping
    /// nil, out-of-bounds) end the process with a signal and are not
    /// captured: handling signals safely needs async-signal-safe code that
    /// can't allocate, lock or write JSON.
    public func installCrashHandler() {
        CrashHandler.register(self)
    }

    /// The uncaught-exception path (called by the installed handler).
    func recordUncaughtException(_ exception: NSException) {
        let stack = exception.callStackSymbols.joined(separator: "\n")
        recordUncaught(
            type: exception.name.rawValue, message: exception.reason ?? exception.name.rawValue,
            reason: nil, stack: stack.isEmpty ? Self.currentStack() : stack,
            mechanism: "NSUncaughtExceptionHandler", handled: false, fatal: true, flushNow: false,
            lockTimeout: 1)
    }

    private func recordUncaught(
        type: String, message raw: String, reason: String?, stack: String?, mechanism: String,
        handled: Bool, fatal: Bool, flushNow: Bool, lockTimeout: TimeInterval? = nil
    ) {
        if let timeout = lockTimeout {
            // The process is about to die: don't wait forever for the lock.
            guard lock.lock(before: Date().addingTimeInterval(timeout)) else { return }
        } else {
            lock.lock()
        }
        defer { lock.unlock() }
        if closed { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false).first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let message = firstLine.isEmpty ? type : firstLine
        let key = "\(type)|\(message)"
        let now = Date()
        let seen = recentCrashes[key]
        let count = seen.map { now.timeIntervalSince($0.0) < 60 ? $0.1 + 1 : 1 } ?? 1
        recentCrashes[key] = (count == 1 ? now : seen!.0, count)
        if recentCrashes.count > 200, let k = recentCrashes.keys.first { recentCrashes.removeValue(forKey: k) }
        if count > Self.crashRepeatLimit { return }

        let details = errorDetails(type: type, message: text, reason: reason, stack: stack)
        enqueueLog(
            fatal ? .fatal : .error, cut(message, 500),
            attributes: ["error.handled": .bool(handled), "error.mechanism": .string(mechanism)],
            traceId: nil, details: details,
            priorityKeys: ["error.handled", "error.mechanism"], flushNow: false)
        if flushNow { startFlush() }
    }
}

/// Process-wide `NSSetUncaughtExceptionHandler` hook shared by loggers.
enum CrashHandler {
    private static let lock = NSLock()
    private static var installed = false
    private static var previous: (@convention(c) (NSException) -> Void)?
    private static var loggers: [ObjectIdentifier: Weak] = [:]

    private final class Weak {
        weak var logger: AppTrackLogger?
        init(_ l: AppTrackLogger) { logger = l }
    }

    static func register(_ logger: AppTrackLogger) {
        lock.lock()
        defer { lock.unlock() }
        loggers[ObjectIdentifier(logger)] = Weak(logger)
        if installed { return }
        installed = true
        previous = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in CrashHandler.handle(exception) }
    }

    static func unregister(_ logger: AppTrackLogger) {
        lock.lock()
        loggers.removeValue(forKey: ObjectIdentifier(logger))
        lock.unlock()
    }

    static func handle(_ exception: NSException) {
        lock.lock()
        let targets = loggers.values.compactMap { $0.logger }
        let chained = previous
        lock.unlock()
        for l in targets { l.recordUncaughtException(exception) }
        chained?(exception)
    }
}

/// A value guarded by a lock.
final class Atomic<T> {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func swap(_ v: T) -> T {
        lock.lock(); defer { lock.unlock() }
        let old = value
        value = v
        return old
    }
}
