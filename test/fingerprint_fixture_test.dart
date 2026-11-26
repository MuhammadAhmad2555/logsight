import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trackapp/core/patterns.dart';

void main() {
  // The aggregateLogs Cloud Function computes fingerprints in JavaScript
  // (functions/aggregate.js); its tests check this same file.
  test('fingerprints match the shared fixture used by the Cloud Function', () {
    final cases = jsonDecode(File('test/fixtures/fingerprints.json').readAsStringSync()) as List;
    expect(cases, isNotEmpty);
    for (final c in cases.cast<Map<String, dynamic>>()) {
      final message = c['message'] as String;
      expect(patternOf(message), c['pattern'], reason: message);
      expect(
        issueFingerprint(c['service'] as String, message, exceptionType: c['type'] as String?),
        c['fingerprint'],
        reason: message,
      );
    }
  });
}
