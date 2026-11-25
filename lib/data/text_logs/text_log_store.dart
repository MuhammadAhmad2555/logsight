// Saves logs as text files. dart:io (Android, iOS, macOS, Windows) writes into
// LogSight's app folder; the web version can only download an export.
export 'text_log_store_stub.dart'
    if (dart.library.io) 'text_log_store_io.dart'
    if (dart.library.js_interop) 'text_log_store_web.dart';
