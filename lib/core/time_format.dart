import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

/// The Clock setting (Account → Appearance).
enum ClockFormat {
  system('System'),
  h12('12-hour'),
  h24('24-hour');

  const ClockFormat(this.label);
  final String label;
}

/// Whether times show in 24-hour form. The app sets MediaQuery's
/// `alwaysUse24HourFormat` from the Clock setting, so reading it here makes
/// the widget rebuild when the setting changes (and Flutter's own time
/// pickers follow it too).
bool use24h(BuildContext context) => MediaQuery.alwaysUse24HourFormatOf(context);

/// Same setting for text built outside widgets (e.g. a time range's label).
/// Kept in sync by the app root.
bool clockUse24h = true;

/// `HH:mm[:ss[.SSS]]` or `h:mm[:ss[.SSS]] a`.
String timePattern(bool h24, {bool seconds = false, bool millis = false}) {
  final s = seconds || millis ? ':ss' : '';
  final ms = millis ? '.SSS' : '';
  return h24 ? 'HH:mm$s$ms' : 'h:mm$s$ms a';
}

/// A formatter for a time, optionally after a [date] pattern such as
/// `'MMM d,'`, in the user's clock format.
DateFormat timeFormat(BuildContext context, {String? date, bool seconds = false, bool millis = false}) =>
    timeFormatFor(use24h(context), date: date, seconds: seconds, millis: millis);

DateFormat timeFormatFor(bool h24, {String? date, bool seconds = false, bool millis = false}) =>
    DateFormat([?date, timePattern(h24, seconds: seconds, millis: millis)].join(' '));
