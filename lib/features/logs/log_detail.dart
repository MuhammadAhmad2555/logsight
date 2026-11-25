import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../data/log_query.dart';
import '../../data/models.dart';

/// Everything about one log, with shortcuts to filter by any value.
class LogDetail extends StatelessWidget {
  const LogDetail({super.key, required this.log, required this.onFilter, this.onClose, this.scrollController});

  final LogEntry log;
  final ValueChanged<AttrFilter> onFilter;
  final VoidCallback? onClose;
  final ScrollController? scrollController;

  static final _fmt = DateFormat('yyyy-MM-dd HH:mm:ss.SSS');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fields = <(String, String, Object?)>[
      ('Timestamp', 'timestamp', '${_fmt.format(log.timestamp)} (${log.timestamp.timeZoneName})'),
      if (log.receivedAt != null) ('Received', 'receivedAt', _fmt.format(log.receivedAt!)),
      ('Service', 'service', log.service),
      ('Severity', 'severity', log.severity.id),
      if (log.userId != null) ('User ID', 'userId', log.userId),
      if (log.sessionId != null) ('Session ID', 'sessionId', log.sessionId),
      if (log.traceId != null) ('Trace ID', 'traceId', log.traceId),
    ];
    final attrs = _flatten(log.attributes);

    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Row(
          children: [
            SeverityBadge(log.severity),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _fmt.format(log.timestamp),
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            IconButton(
              tooltip: 'Copy as JSON',
              icon: const Icon(Icons.data_object, size: 20),
              onPressed: () => copyToClipboard(
                context,
                const JsonEncoder.withIndent('  ').convert(log.toJson()),
                what: 'Log JSON copied',
              ),
            ),
            if (onClose != null)
              IconButton(tooltip: 'Close', icon: const Icon(Icons.close, size: 20), onPressed: onClose),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            log.message.isEmpty ? '(empty message)' : log.message,
            style: monoStyle.copyWith(fontSize: 13, height: 1.4),
          ),
        ),
        const SizedBox(height: 18),
        _Section('Fields'),
        for (final f in fields)
          _FieldRow(
            label: f.$1,
            value: '${f.$3}',
            onFilter: f.$2 == 'timestamp' || f.$2 == 'receivedAt'
                ? null
                : (op) => onFilter(AttrFilter(f.$2, op, '${f.$3}')),
          ),
        const SizedBox(height: 18),
        _Section('Attributes (${attrs.length})'),
        if (attrs.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('No attributes', style: TextStyle(color: theme.colorScheme.outline)),
          ),
        for (final e in attrs.entries)
          _FieldRow(
            label: e.key,
            value: _display(e.value),
            mono: true,
            onFilter: (op) => onFilter(AttrFilter(e.key, op, _display(e.value))),
          ),
      ],
    );
  }

  static Map<String, Object?> _flatten(Map<String, dynamic> m, [String prefix = '']) {
    final out = <String, Object?>{};
    final keys = m.keys.toList()..sort();
    for (final k in keys) {
      final v = m[k];
      final path = prefix.isEmpty ? k : '$prefix.$k';
      if (v is Map && v.isNotEmpty) {
        out.addAll(_flatten(v.cast<String, dynamic>(), path));
      } else {
        out[path] = v;
      }
    }
    return out;
  }

  static String _display(Object? v) {
    if (v == null) return 'null';
    if (v is Timestamp) return v.toDate().toUtc().toIso8601String();
    if (v is List || v is Map) return jsonEncode(v, toEncodable: (o) => o.toString());
    return '$v';
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      title.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        letterSpacing: 0.8,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.label, required this.value, this.onFilter, this.mono = false});

  final String label;
  final String value;
  final bool mono;
  final ValueChanged<FilterOp>? onFilter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(label, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
          Expanded(
            child: SelectableText(value, style: (mono ? monoStyle : const TextStyle()).copyWith(fontSize: 12.5)),
          ),
          PopupMenuButton<String>(
            tooltip: 'Actions',
            padding: EdgeInsets.zero,
            iconSize: 18,
            icon: const Icon(Icons.more_horiz, size: 18),
            onSelected: (v) {
              switch (v) {
                case 'eq':
                  onFilter?.call(FilterOp.equals);
                case 'ne':
                  onFilter?.call(FilterOp.notEquals);
                case 'copy':
                  copyToClipboard(context, value, what: 'Value copied');
              }
            },
            itemBuilder: (_) => [
              if (onFilter != null) ...[
                const PopupMenuItem(value: 'eq', child: Text('Filter: equals this')),
                const PopupMenuItem(value: 'ne', child: Text('Filter: exclude this')),
              ],
              const PopupMenuItem(value: 'copy', child: Text('Copy value')),
            ],
          ),
        ],
      ),
    );
  }
}
