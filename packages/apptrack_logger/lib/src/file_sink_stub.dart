/// Appends lines to a text file. On the web this does nothing.
class LogFileSink {
  LogFileSink(String path, {int maxBytes = 0});

  bool get isSupported => false;

  void write(String line) {}

  void close() {}
}
