import Foundation

/// A value stored on a log or event (attribute, property, field).
///
/// Values passed as `Any` are converted to this once, when the log is
/// queued, so what is sent (and what is kept in the queue file) never
/// depends on objects the app may change later.
public enum LogValue: Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case date(Date)
    case array([LogValue])
    case map([String: LogValue])

    /// Converts any Swift / Foundation value. Unknown types are stored as
    /// their `String(describing:)` text, like the Dart SDK's `'$v'`.
    public init(_ any: Any?) {
        guard let any = any else { self = .null; return }
        if let v = any as? LogValue { self = v; return }
        // Unwrap Optionals hidden inside `Any`.
        let mirror = Mirror(reflecting: any)
        if mirror.displayStyle == .optional {
            if let child = mirror.children.first { self = LogValue(child.value) } else { self = .null }
            return
        }
        // Check the dynamic type first: `Any` holding an Int would otherwise
        // bridge to NSNumber and could be read as a Bool or Double.
        switch any {
        case let v as Bool where type(of: any) == Bool.self: self = .bool(v)
        case let v as Int where type(of: any) == Int.self: self = .int(Int64(v))
        case let v as Int8 where type(of: any) == Int8.self: self = .int(Int64(v))
        case let v as Int16 where type(of: any) == Int16.self: self = .int(Int64(v))
        case let v as Int32 where type(of: any) == Int32.self: self = .int(Int64(v))
        case let v as Int64 where type(of: any) == Int64.self: self = .int(v)
        case let v as UInt where type(of: any) == UInt.self: self = LogValue.unsigned(UInt64(v))
        case let v as UInt8 where type(of: any) == UInt8.self: self = .int(Int64(v))
        case let v as UInt16 where type(of: any) == UInt16.self: self = .int(Int64(v))
        case let v as UInt32 where type(of: any) == UInt32.self: self = .int(Int64(v))
        case let v as UInt64 where type(of: any) == UInt64.self: self = LogValue.unsigned(v)
        case let v as Double where type(of: any) == Double.self: self = .double(v)
        case let v as Float where type(of: any) == Float.self: self = .double(Double(v))
        case let v as String: self = .string(v)
        case let v as Substring: self = .string(String(v))
        case let v as Character: self = .string(String(v))
        case let v as Date: self = .date(v)
        case is NSNull: self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else if CFNumberIsFloatType(n) {
                self = .double(n.doubleValue)
            } else {
                self = .int(n.int64Value)
            }
        case let d as [String: Any]:
            self = .map(d.mapValues { LogValue($0) })
        case let d as [AnyHashable: Any]:
            var out: [String: LogValue] = [:]
            for (k, v) in d { out["\(k.base)"] = LogValue(v) }
            self = .map(out)
        case let a as [Any]:
            self = .array(a.map { LogValue($0) })
        case let s as Set<AnyHashable>:
            self = .array(s.map { LogValue($0.base) })
        default:
            self = .string(String(describing: any))
        }
    }

    private static func unsigned(_ v: UInt64) -> LogValue {
        if let i = Int64(exactly: v) { return .int(i) }
        return .double(Double(v))
    }

    /// Firestore REST `Value` encoding (same as Dart `toFirestoreValue`).
    var firestore: [String: Any] {
        switch self {
        case .null: return ["nullValue": NSNull()]
        case .bool(let b): return ["booleanValue": b]
        case .int(let i): return ["integerValue": String(i)]
        case .double(let d):
            if d.isNaN { return ["stringValue": "NaN"] }
            if d.isInfinite { return ["stringValue": d < 0 ? "-Infinity" : "Infinity"] }
            return ["doubleValue": d]
        case .string(let s): return ["stringValue": s]
        case .date(let d): return ["timestampValue": formatTimestamp(d)]
        case .array(let a): return ["arrayValue": ["values": a.map { $0.firestore }]]
        case .map(let m): return ["mapValue": ["fields": m.mapValues { $0.firestore }]]
        }
    }
}

extension LogValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
}

// MARK: - Queue file encoding

/// JSON for the queue file. Strings, bools, null, arrays and maps are plain
/// JSON; numbers and dates are tagged so they come back with the same type
/// and value: `{"$i":"42"}`, `{"$f":1.5}`, `{"$dt":<seconds since 2001>}`.
/// A map with a single `$`-prefixed key is wrapped as `{"$m":{...}}`.
extension LogValue: Codable {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var c = encoder.singleValueContainer()
            try c.encodeNil()
        case .bool(let b):
            var c = encoder.singleValueContainer()
            try c.encode(b)
        case .string(let s):
            var c = encoder.singleValueContainer()
            try c.encode(s)
        case .int(let i):
            var c = encoder.container(keyedBy: Key.self)
            try c.encode(String(i), forKey: Key("$i"))
        case .double(let d):
            var c = encoder.container(keyedBy: Key.self)
            if d.isFinite {
                try c.encode(d, forKey: Key("$f"))
            } else {
                try c.encode(d.isNaN ? "NaN" : (d < 0 ? "-Infinity" : "Infinity"), forKey: Key("$f"))
            }
        case .date(let d):
            var c = encoder.container(keyedBy: Key.self)
            try c.encode(d.timeIntervalSinceReferenceDate, forKey: Key("$dt"))
        case .array(let a):
            var c = encoder.unkeyedContainer()
            for v in a { try c.encode(v) }
        case .map(let m):
            var c = encoder.container(keyedBy: Key.self)
            if m.count == 1, let k = m.keys.first, k.hasPrefix("$") {
                try c.encode(m, forKey: Key("$m"))
            } else {
                for (k, v) in m { try c.encode(v, forKey: Key(k)) }
            }
        }
    }

    public init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: Key.self) {
            let keys = c.allKeys
            if keys.count == 1 {
                let k = keys[0]
                switch k.stringValue {
                case "$i":
                    let s = try c.decode(String.self, forKey: k)
                    guard let i = Int64(s) else {
                        throw DecodingError.dataCorruptedError(forKey: k, in: c, debugDescription: "bad int")
                    }
                    self = .int(i); return
                case "$f":
                    if let d = try? c.decode(Double.self, forKey: k) { self = .double(d); return }
                    let s = try c.decode(String.self, forKey: k)
                    self = .double(s == "NaN" ? .nan : (s.hasPrefix("-") ? -.infinity : .infinity)); return
                case "$dt":
                    self = .date(Date(timeIntervalSinceReferenceDate: try c.decode(Double.self, forKey: k))); return
                case "$m":
                    self = .map(try c.decode([String: LogValue].self, forKey: k)); return
                default: break
                }
            }
            var m: [String: LogValue] = [:]
            for k in keys { m[k.stringValue] = try c.decode(LogValue.self, forKey: k) }
            self = .map(m)
            return
        }
        if var c = try? decoder.unkeyedContainer() {
            var a: [LogValue] = []
            while !c.isAtEnd { a.append(try c.decode(LogValue.self)) }
            self = .array(a)
            return
        }
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        self = .string(try c.decode(String.self))
    }
}

// MARK: - Shared helpers

private let timestampFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}()

/// RFC 3339 UTC with milliseconds, e.g. `2026-11-25T17:39:43.374Z`.
func formatTimestamp(_ d: Date) -> String { timestampFormatter.string(from: d) }

/// Cuts [s] to at most [max] UTF-16 code units (what the Dart SDK and the
/// server's limits count) without splitting a surrogate pair.
func cut(_ s: String, _ max: Int) -> String {
    if s.utf16.count <= max { return s }
    var out = String.UnicodeScalarView()
    var n = 0
    for scalar in s.unicodeScalars {
        let w = scalar.utf16.count
        if n + w > max { break }
        out.append(scalar)
        n += w
    }
    return String(out)
}
