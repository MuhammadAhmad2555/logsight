/// Log patterns (like PostHog's Patterns view): messages that differ only in
/// variable parts (IDs, numbers, emails, URLs…) share one template, e.g.
/// `Payment failed for order 42` and `Payment failed for order 7` both become
/// `Payment failed for order <num>`.
library;

final List<(RegExp, String)> _rules = [
  (RegExp(r'https?://\S+'), '<url>'),
  (RegExp(r'[\w.+-]+@[\w-]+\.[\w.-]+'), '<email>'),
  (RegExp(r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b'), '<uuid>'),
  (RegExp(r'\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b'), '<ip>'),
  (RegExp(r'\b\d{4}-\d{2}-\d{2}[T ][\d:.]+Z?\b'), '<time>'),
  (RegExp(r'\b0x[0-9a-fA-F]+\b'), '<hex>'),
  (RegExp(r'\b[0-9a-fA-F]{16,}\b'), '<hex>'),
  (RegExp(r'"[^"]{0,200}"'), '"<str>"'),
  (RegExp(r"'[^']{0,200}'"), "'<str>'"),
  // Words mixing letters and digits (tokens, IDs like a1b2c3, atk_x9…).
  (RegExp(r'\b(?=[A-Za-z_]*\d)(?=\d*[A-Za-z_])[A-Za-z0-9_-]{8,}\b'), '<id>'),
  (RegExp(r'-?\b\d+(?:\.\d+)?(?:ms|s|kb|mb|gb|%)?\b', caseSensitive: false), '<num>'),
];

/// The message with its variable parts replaced by placeholders.
String patternOf(String message) {
  var s = message.length > 500 ? message.substring(0, 500) : message;
  s = s.split('\n').first;
  for (final (re, rep) in _rules) {
    s = s.replaceAll(re, rep);
  }
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Stable 64-bit FNV-1a hash as 16 hex chars (same input → same ID on every
/// platform, including the web, where Dart ints are 53-bit).
String stableHash(String input) {
  // Two 32-bit FNV-1a halves with different offsets, so this works on the web.
  int h1 = 0x811c9dc5, h2 = 0x050c5d1f;
  // h * 0x01000193 mod 2^32, split as (h << 24) + h * 0x193 so no step goes
  // past 2^53 (JavaScript's exact-integer limit).
  int mul(int h) => (((h << 24) & 0xFFFFFFFF) + h * 0x193) & 0xFFFFFFFF;
  for (final unit in input.codeUnits) {
    h1 = mul((h1 ^ unit) & 0xFFFFFFFF);
    h2 = mul((h2 ^ unit) & 0xFFFFFFFF);
  }
  return h1.toRadixString(16).padLeft(8, '0') + h2.toRadixString(16).padLeft(8, '0');
}

/// Issue fingerprint for an error: service + exception type (if any) + pattern.
String issueFingerprint(String service, String message, {String? exceptionType}) =>
    stableHash('$service|${exceptionType ?? ''}|${patternOf(message)}');
