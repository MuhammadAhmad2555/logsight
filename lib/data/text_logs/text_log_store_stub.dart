import '../models.dart';

class TextLogStore {
  // basePath is only used by the dart:io version (tests use it).
  TextLogStore(this.projectId, {String? basePath});

  final String projectId;

  bool get canAutoSave => false;

  Future<String?> folderPath() async => null;

  /// Nothing is saved on this platform.
  Future<void> clear() async {}

  Future<int> append(Iterable<LogEntry> logs) async => 0;

  Future<String?> export(List<LogEntry> logs, String label, {bool csv = false}) async => null;
}
