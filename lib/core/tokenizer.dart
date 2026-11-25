/// Splits text into lowercase whole-word tokens for full-text search.
///
/// Firestore has no full-text search, so every log stores the tokens of its
/// message and search uses `array-contains`. Logging SDKs must use the same
/// rules: keep the copy in packages/apptrack_logger in sync with this one.
List<String> tokenize(String text, {int maxTokens = 64}) {
  final seen = <String>{};
  for (final raw in text.toLowerCase().split(_separator)) {
    if (raw.length < 2 || raw.length > 40) continue;
    seen.add(raw);
    if (seen.length >= maxTokens) break;
  }
  return seen.toList();
}

final RegExp _separator = RegExp(r'[^a-z0-9_]+');
