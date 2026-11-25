import 'package:flutter/material.dart';

/// Log severity levels, from least to most severe (OpenTelemetry naming).
enum Severity {
  trace('trace', 'TRACE', Color(0xFF8A8F98)),
  debug('debug', 'DEBUG', Color(0xFF4F8BD6)),
  info('info', 'INFO', Color(0xFF2E9E6A)),
  warn('warn', 'WARN', Color(0xFFD9A21B)),
  error('error', 'ERROR', Color(0xFFE0533D)),
  fatal('fatal', 'FATAL', Color(0xFFA62CC2));

  const Severity(this.id, this.label, this.color);

  final String id;
  final String label;
  final Color color;

  static Severity parse(String? value) {
    final v = (value ?? '').toLowerCase();
    for (final s in Severity.values) {
      if (s.id == v) return s;
    }
    if (v == 'warning') return Severity.warn;
    if (v == 'critical') return Severity.fatal;
    return Severity.info;
  }

  static Severity? tryParse(String value) {
    for (final s in Severity.values) {
      if (s.id == value) return s;
    }
    return null;
  }
}
