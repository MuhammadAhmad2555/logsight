import 'dart:io';

import 'queue_codec.dart';

/// Keeps queued logs and events on disk, so ones not yet sent survive the
/// app being killed, crashing or going offline, and are sent next launch.
///
/// The file is a journal of JSON lines: `{"n": 7, "q": {...}}` when item 7
/// is queued and `{"upto": 7}` once items 1–7 have left the queue (sent,
/// rejected or dropped). Writes go straight to the OS (no Dart buffering),
/// so a line written just before a crash is kept. The file is emptied when
/// the queue empties and rewritten when it grows past [compactBytes].
/// Errors are swallowed: logging must never crash the app.
class QueueStore {
  QueueStore(this.path, {this.compactBytes = 1024 * 1024});

  final String path;
  final int compactBytes;
  RandomAccessFile? _file;
  bool _failed = false;

  bool get isSupported => true;

  /// Items still waiting from earlier runs, oldest first, each with its
  /// sequence number in `_n`. Rewrites the file to hold just those.
  List<Map<String, Object?>> load() {
    try {
      final file = File(path);
      if (!file.existsSync()) return const [];
      final items = <int, Map<String, Object?>>{};
      var upto = 0;
      for (final line in file.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        try {
          final entry = decodeQueueLine(line);
          final done = entry['upto'];
          if (done is int && done > upto) upto = done;
          final n = entry['n'];
          final q = entry['q'];
          if (n is int && q is Map) items[n] = {...q.cast<String, Object?>(), '_n': n};
        } catch (_) {
          // A line cut short by a crash: skip it.
        }
      }
      final pending = (items.entries.where((e) => e.key > upto).toList()..sort((a, b) => a.key.compareTo(b.key)))
          .map((e) => e.value)
          .toList();
      _rewrite(pending);
      return pending;
    } catch (_) {
      _failed = true;
      return const [];
    }
  }

  /// Records a newly queued item (with its `_n`).
  void added(Map<String, Object?> item) {
    final n = item['_n'];
    if (n is! int) return;
    _append({'n': n, 'q': Map.of(item)..remove('_n')});
  }

  /// Records that items up to [seq] left the queue; [remaining] is what's
  /// still queued (used to empty or compact the file).
  void removedUpTo(int seq, List<Map<String, Object?>> remaining) {
    if (_failed) return;
    if (remaining.isEmpty) {
      _truncate();
      return;
    }
    _append({'upto': seq});
    try {
      if ((_file?.lengthSync() ?? 0) > compactBytes) _rewrite(remaining);
    } catch (_) {
      _failed = true;
    }
  }

  void close() {
    try {
      _file?.closeSync();
    } catch (_) {}
    _file = null;
  }

  void _append(Map<String, Object?> entry) {
    if (_failed) return;
    try {
      (_file ??= _open()).writeStringSync('${encodeQueueLine(entry)}\n');
    } catch (_) {
      _failed = true;
    }
  }

  RandomAccessFile _open() {
    final file = File(path);
    file.parent.createSync(recursive: true);
    return file.openSync(mode: FileMode.append);
  }

  void _truncate() {
    try {
      final f = _file ??= _open();
      f.truncateSync(0);
      f.setPositionSync(0);
    } catch (_) {
      _failed = true;
    }
  }

  /// Replaces the file with just [items] (write a temp file, then rename).
  void _rewrite(List<Map<String, Object?>> items) {
    close();
    final tmp = File('$path.tmp');
    final b = StringBuffer();
    for (final item in items) {
      b.writeln(encodeQueueLine({'n': item['_n'], 'q': Map.of(item)..remove('_n')}));
    }
    tmp.parent.createSync(recursive: true);
    tmp.writeAsStringSync(b.toString(), flush: true);
    tmp.renameSync(path);
  }
}
