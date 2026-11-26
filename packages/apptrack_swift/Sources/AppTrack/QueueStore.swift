import Foundation

/// A queued log or event. `seq` is its sequence number (also its number in
/// the queue file); `docId` is its Firestore document ID, fixed when it is
/// queued so a resend can never store it twice; `fields` are the document
/// fields.
struct QueueItem: Equatable {
    enum Kind: String { case log, event }
    var seq: Int
    var kind: Kind
    var docId: String
    var fields: [String: LogValue]

    init(seq: Int, kind: Kind, docId: String = AppTrackLogger.randomId(), fields: [String: LogValue]) {
        self.seq = seq
        self.kind = kind
        self.docId = docId
        self.fields = fields
    }

    /// The `q` object of a journal line: fields plus `_kind` / `_id`.
    var journalFields: [String: LogValue] {
        var q = fields
        if kind == .event { q["_kind"] = .string("event") }
        q["_id"] = .string(docId)
        return q
    }

    init(seq: Int, journal: [String: LogValue]) {
        var q = journal
        var kind = Kind.log
        if case .string(let k)? = q.removeValue(forKey: "_kind"), k == "event" { kind = .event }
        var docId: String?
        if case .string(let id)? = q.removeValue(forKey: "_id"), AppTrackLogger.docIdOk(id) { docId = id }
        self.init(seq: seq, kind: kind, docId: docId ?? AppTrackLogger.randomId(), fields: q)
    }
}

/// One line of the queue journal: `{"n":7,"q":{...}}` when item 7 is
/// queued, `{"upto":7}` once items 1–7 have left the queue.
private struct JournalLine: Codable {
    var n: Int?
    var q: [String: LogValue]?
    var upto: Int?
}

/// Keeps queued logs and events on disk so ones not yet sent survive the
/// app being killed, crashing or going offline, and are sent next launch.
/// Same design as the Dart SDK's `queue_store_io.dart`: a journal of JSON
/// lines, written straight to the OS (no buffering), emptied when the queue
/// empties and rewritten when it grows past `compactBytes`. A line cut short
/// by a crash is skipped. Errors are swallowed: logging must never crash
/// the app. Not thread-safe; the logger calls it under its lock.
final class QueueStore {
    let url: URL
    let compactBytes: UInt64
    private var handle: FileHandle?
    private(set) var failed = false
    private let encoder = JSONEncoder()

    init(url: URL, compactBytes: UInt64 = 1024 * 1024) {
        self.url = url
        self.compactBytes = compactBytes
    }

    deinit { close() }

    /// Items still waiting from earlier runs, oldest first. Rewrites the
    /// file to hold just those (or the newest `limit` of them).
    func load(limit: Int = .max) -> (items: [QueueItem], skipped: Int) {
        do {
            guard FileManager.default.fileExists(atPath: url.path) else { return ([], 0) }
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            var items: [Int: QueueItem] = [:]
            var upto = 0
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let entry = try? decoder.decode(JournalLine.self, from: Data(line)) else {
                    continue // a line cut short by a crash
                }
                if let u = entry.upto, u > upto { upto = u }
                if let n = entry.n, let q = entry.q {
                    items[n] = QueueItem(seq: n, journal: q)
                }
            }
            let pending = items.values.filter { $0.seq > upto }.sorted { $0.seq < $1.seq }
            let keep = pending.count > limit ? Array(pending.suffix(limit)) : pending
            rewrite(keep)
            return (keep, pending.count - keep.count)
        } catch {
            failed = true
            return ([], 0)
        }
    }

    /// Records a newly queued item.
    func added(_ item: QueueItem) {
        append(JournalLine(n: item.seq, q: item.journalFields))
    }

    /// Records that items up to `seq` left the queue; `remaining` is what's
    /// still queued (used to empty or compact the file).
    func removed(upTo seq: Int, remaining: [QueueItem]) {
        if failed { return }
        if remaining.isEmpty {
            truncate()
            return
        }
        append(JournalLine(upto: seq))
        do {
            if let h = handle, try h.seekToEnd() > compactBytes { rewrite(remaining) }
        } catch {
            failed = true
        }
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    private func line(_ entry: JournalLine) throws -> Data {
        var d = try encoder.encode(entry)
        d.append(UInt8(ascii: "\n"))
        return d
    }

    private func open() throws -> FileHandle {
        if let h = handle { return h }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let h = try FileHandle(forWritingTo: url)
        handle = h
        return h
    }

    private func append(_ entry: JournalLine) {
        if failed { return }
        do {
            let h = try open()
            try h.seekToEnd()
            try h.write(contentsOf: try line(entry))
        } catch {
            failed = true
        }
    }

    private func truncate() {
        do {
            try open().truncate(atOffset: 0)
        } catch {
            failed = true
        }
    }

    /// Replaces the file with just `items` (temp file + atomic rename).
    private func rewrite(_ items: [QueueItem]) {
        close()
        do {
            var data = Data()
            for item in items {
                data.append(try line(JournalLine(n: item.seq, q: item.journalFields)))
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            failed = true
        }
    }
}
