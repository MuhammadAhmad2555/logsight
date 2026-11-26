/// Keeps queued logs on disk. On the web there is no file system, so the
/// queue lives in memory only.
class QueueStore {
  QueueStore(String path);

  bool get isSupported => false;

  List<Map<String, Object?>> load() => const [];

  void added(Map<String, Object?> item) {}

  void removedUpTo(int seq, List<Map<String, Object?>> remaining) {}

  void close() {}
}
