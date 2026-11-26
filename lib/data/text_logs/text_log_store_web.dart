import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../models.dart';
import 'text_log_format.dart';

/// Browsers have no app folder: auto-save is off and "Save as .txt"
/// downloads the file instead.
class TextLogStore {
  // basePath is only used by the dart:io version (tests use it).
  TextLogStore(this.projectId, {String? basePath});

  final String projectId;

  bool get canAutoSave => false;

  Future<String?> folderPath() async => null;

  /// Nothing is saved on this platform.
  Future<void> clear() async {}

  Future<int> append(Iterable<LogEntry> logs) async => 0;

  Future<String?> export(List<LogEntry> logs, String label, {bool csv = false}) async {
    final sorted = [...logs]..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final text = csv ? formatLogsCsv(sorted) : sorted.map(formatLogLine).join('\n');
    final blob = web.Blob([text.toJS].toJS, web.BlobPropertyBag(type: csv ? 'text/csv' : 'text/plain'));
    final url = web.URL.createObjectURL(blob);
    final name = '${safeFileName(label)}-${DateTime.now().millisecondsSinceEpoch}.${csv ? 'csv' : 'txt'}';
    (web.document.createElement('a') as web.HTMLAnchorElement)
      ..href = url
      ..download = name
      ..click();
    web.URL.revokeObjectURL(url);
    return 'Downloads/$name';
  }
}
