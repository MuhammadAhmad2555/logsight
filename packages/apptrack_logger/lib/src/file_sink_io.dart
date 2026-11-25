import 'dart:io';

/// Appends lines to a text file and rotates it when it gets too big:
/// `logs.txt` becomes `logs.1.txt` (replacing the older one), so at most
/// two files of [maxBytes] each are kept. Writes are synchronous, so lines
/// written just before a crash are still on disk. Errors are swallowed:
/// logging must never crash the app.
class LogFileSink {
  LogFileSink(this.path, {this.maxBytes = 5 * 1024 * 1024});

  final String path;
  final int maxBytes;
  RandomAccessFile? _file;
  bool _failed = false;

  bool get isSupported => true;

  void write(String line) {
    if (_failed) return;
    try {
      final f = _file ??= _open();
      f.writeStringSync(line.endsWith('\n') ? line : '$line\n');
      if (maxBytes > 0 && f.lengthSync() > maxBytes) _rotate();
    } catch (_) {
      _failed = true;
    }
  }

  RandomAccessFile _open() {
    final file = File(path);
    file.parent.createSync(recursive: true);
    return file.openSync(mode: FileMode.append);
  }

  void _rotate() {
    _file?.closeSync();
    _file = null;
    final dot = path.lastIndexOf('.');
    final rotated = dot > path.lastIndexOf(Platform.pathSeparator)
        ? '${path.substring(0, dot)}.1${path.substring(dot)}'
        : '$path.1';
    final old = File(rotated);
    if (old.existsSync()) old.deleteSync();
    File(path).renameSync(rotated);
    _file = _open();
  }

  void close() {
    try {
      _file?.closeSync();
    } catch (_) {}
    _file = null;
  }
}
