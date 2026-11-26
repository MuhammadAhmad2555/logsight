import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models.dart';
import 'text_log_format.dart';

/// Saves logs as text in LogSight's app folder:
///
///   `<app documents>/LogSight/<projectId>/all.txt`        every saved log
///   `<app documents>/LogSight/<projectId>/<service>.txt`  one file per service.name
///   `<app documents>/LogSight/<projectId>/exports/…`      "Save as .txt" files
///
/// Each log is saved once: IDs already written are kept in `.saved_ids`.
/// Lines are oldest-first within each batch. Errors never reach the UI.
class TextLogStore {
  /// [basePath] replaces the app documents folder (used by tests).
  TextLogStore(this.projectId, {this.basePath});

  final String projectId;
  final String? basePath;
  Directory? _dir;
  Set<String>? _saved;
  Future<void> _queue = Future.value();

  bool get canAutoSave => true;

  Future<Directory> _folder() async {
    if (_dir != null) return _dir!;
    final root = basePath ?? (await getApplicationDocumentsDirectory()).path;
    final dir = Directory('$root${Platform.pathSeparator}LogSight${Platform.pathSeparator}${safeFileName(projectId)}');
    await dir.create(recursive: true);
    return _dir = dir;
  }

  /// Deletes this project's saved text files on this device.
  Future<void> clear() {
    final result = _queue.then((_) async {
      final dir = await _folder();
      if (await dir.exists()) await dir.delete(recursive: true);
      _dir = null;
      _saved = null;
    });
    _queue = result.catchError((Object _) {});
    return result;
  }

  Future<String?> folderPath() async {
    try {
      return (await _folder()).path;
    } catch (_) {
      return null;
    }
  }

  Future<Set<String>> _savedIds(Directory dir) async {
    if (_saved != null) return _saved!;
    final f = File('${dir.path}${Platform.pathSeparator}.saved_ids');
    _saved = await f.exists() ? (await f.readAsLines()).where((l) => l.isNotEmpty).toSet() : <String>{};
    return _saved!;
  }

  /// Appends logs not saved before. Returns how many were written.
  /// Calls run one after another so files never interleave.
  Future<int> append(Iterable<LogEntry> logs) {
    final list = logs.toList();
    final result = _queue.then((_) => _append(list)).catchError((Object _) => 0);
    _queue = result.then((_) {});
    return result;
  }

  Future<int> _append(List<LogEntry> logs) async {
    final dir = await _folder();
    final saved = await _savedIds(dir);
    final fresh = logs.where((l) => !saved.contains(l.id)).toList()..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    if (fresh.isEmpty) return 0;

    final all = StringBuffer();
    final byService = <String, StringBuffer>{};
    for (final log in fresh) {
      final line = '${formatLogLine(log)}\n';
      all.write(line);
      byService.putIfAbsent(safeFileName(log.service), StringBuffer.new).write(line);
    }
    final sep = Platform.pathSeparator;
    await File('${dir.path}${sep}all.txt').writeAsString(all.toString(), mode: FileMode.append, flush: true);
    for (final e in byService.entries) {
      await File('${dir.path}$sep${e.key}.txt').writeAsString(e.value.toString(), mode: FileMode.append, flush: true);
    }
    await File(
      '${dir.path}$sep.saved_ids',
    ).writeAsString('${fresh.map((l) => l.id).join('\n')}\n', mode: FileMode.append, flush: true);
    saved.addAll(fresh.map((l) => l.id));
    return fresh.length;
  }

  /// Writes [logs] (oldest first) to a new file in `exports/`. Returns its path.
  Future<String?> export(List<LogEntry> logs, String label, {bool csv = false}) async {
    final dir = await _folder();
    final exports = Directory('${dir.path}${Platform.pathSeparator}exports');
    await exports.create(recursive: true);
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    final file = File('${exports.path}${Platform.pathSeparator}${safeFileName(label)}-$stamp.${csv ? 'csv' : 'txt'}');
    final sorted = [...logs]..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    await file.writeAsString(csv ? formatLogsCsv(sorted) : '${sorted.map(formatLogLine).join('\n')}\n', flush: true);
    return file.path;
  }
}
