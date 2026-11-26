// Picks the dart:io queue file on Android, iOS, macOS, Windows, Linux and
// servers, and a no-op on the web.
export 'queue_store_stub.dart' if (dart.library.io) 'queue_store_io.dart';
export 'queue_codec.dart';
