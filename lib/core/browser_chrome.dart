// Tints the browser's own UI (Safari's status bar / address bar area) to match
// the app's theme on web. A no-op on every other platform.
export 'browser_chrome_stub.dart' if (dart.library.js_interop) 'browser_chrome_web.dart';
