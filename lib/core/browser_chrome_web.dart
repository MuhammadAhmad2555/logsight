import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/material.dart';

Brightness? _last;

/// Calls window.setBrowserChrome(isDark), defined in web/index.html.
void setBrowserChrome(Brightness brightness) {
  if (_last == brightness) return;
  _last = brightness;
  if (!globalContext.has('setBrowserChrome')) return;
  globalContext.callMethod('setBrowserChrome'.toJS, (brightness == Brightness.dark).toJS);
}
