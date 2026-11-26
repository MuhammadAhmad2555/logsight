import Foundation

/// Search tokens for a log message. Must match the Dart SDK and the
/// dashboard's tokenizer: lowercase, split on `[^a-z0-9_]+`, keep tokens of
/// 2–40 characters, unique, in order, at most `maxTokens`.
public func tokenize(_ text: String, maxTokens: Int = 64) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    if maxTokens <= 0 { return out }
    var current = String.UnicodeScalarView()
    var done = false

    func take() {
        let n = current.count
        if n >= 2 && n <= 40 {
            let token = String(current)
            if seen.insert(token).inserted { out.append(token) }
            if out.count >= maxTokens { done = true }
        }
        current = String.UnicodeScalarView()
    }

    for scalar in text.lowercased().unicodeScalars {
        let v = scalar.value
        let word = (v >= 0x61 && v <= 0x7A) || (v >= 0x30 && v <= 0x39) || v == 0x5F
        if word {
            current.append(scalar)
        } else if !current.isEmpty {
            take()
            if done { return out }
        }
    }
    if !current.isEmpty { take() }
    return out
}

/// The optional `error` map of a log ({type, message, reason, stack}), or
/// nil when there's nothing to record. Values are trimmed and cut to the
/// server's limits (200 / 4000 / 4000 / 16000).
func errorDetails(type: String?, message: String?, reason: String?, stack: String?) -> [String: LogValue]? {
    func clean(_ v: String?, _ max: Int) -> String? {
        guard let t = v?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return cut(t, max)
    }
    var out: [String: LogValue] = [:]
    if let v = clean(type, 200) { out["type"] = .string(v) }
    if let v = clean(message, 4000) { out["message"] = .string(v) }
    if let v = clean(reason, 4000) { out["reason"] = .string(v) }
    if let v = clean(stack, 16000) { out["stack"] = .string(v) }
    return out.isEmpty ? nil : out
}

/// Swift type name of an error, e.g. `URLError` or `PaymentError`.
func errorTypeName(_ error: Error) -> String {
    // Foundation's error structs are stored as NSError inside `Error`.
    if error is URLError { return "URLError" }
    if error is CocoaError { return "CocoaError" }
    return String(describing: type(of: error))
}
