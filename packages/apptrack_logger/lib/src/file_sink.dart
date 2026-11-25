// Picks the dart:io file writer on Android, iOS, macOS, Windows, Linux and
// servers, and a no-op on the web (browsers have no file system).
export 'file_sink_stub.dart' if (dart.library.io) 'file_sink_io.dart';
