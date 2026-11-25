import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/patterns.dart';
import '../../core/severity.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../data/log_query.dart';
import '../../data/models.dart';

/// Everything about one log (PostHog-style): message, optional error
/// details, context links, attributes with include/exclude filters and value
/// breakdowns, the raw JSON, and related logs.
class LogDetail extends StatefulWidget {
  const LogDetail({
    super.key,
    required this.log,
    required this.onFilter,
    this.onClose,
    this.scrollController,
    this.related = const [],
    this.onOpen,
    this.projectId,
  });

  final LogEntry log;
  final ValueChanged<AttrFilter> onFilter;
  final VoidCallback? onClose;
  final ScrollController? scrollController;

  /// The logs currently loaded in the list: used for value breakdowns and
  /// the Related tab.
  final List<LogEntry> related;

  /// Opens another log (from the Related tab).
  final ValueChanged<LogEntry>? onOpen;

  /// Enables the link to the user's People page.
  final String? projectId;

  @override
  State<LogDetail> createState() => _LogDetailState();
}

enum _Tab { details, raw, related }

class _LogDetailState extends State<LogDetail> {
  static final _fmt = DateFormat('yyyy-MM-dd HH:mm:ss.SSS');
  _Tab _tab = _Tab.details;

  /// Attribute whose value breakdown is open.
  String? _breakdown;

  LogEntry get log => widget.log;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 28),
      children: [
        _header(theme),
        const SizedBox(height: 12),
        _contextChips(),
        const SizedBox(height: 14),
        _tabs(theme),
        const SizedBox(height: 16),
        ...switch (_tab) {
          _Tab.details => _details(theme),
          _Tab.raw => _raw(theme),
          _Tab.related => _relatedTab(theme),
        },
      ],
    );
  }

  // ---------------------------------------------------------------- header

  Widget _header(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text('Log details', style: theme.textTheme.titleLarge)),
            IconButton(
              tooltip: 'Copy as JSON',
              icon: const Icon(Icons.data_object_rounded, size: 19),
              onPressed: () => copyToClipboard(
                context,
                const JsonEncoder.withIndent('  ').convert(log.toJson()),
                what: 'Log JSON copied',
              ),
            ),
            if (widget.onClose != null)
              IconButton(tooltip: 'Close', icon: const Icon(Icons.close_rounded, size: 20), onPressed: widget.onClose),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 18,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _Meta(
              label: 'Timestamp',
              child: Tooltip(
                message: '${log.timestamp.toUtc().toIso8601String()} UTC',
                child: Text(_fmt.format(log.timestamp), style: monoStyle.copyWith(fontSize: 12.5)),
              ),
            ),
            _Meta(
              label: 'Severity',
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: log.severity.color, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    log.severity.label,
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, color: log.severity.color),
                  ),
                ],
              ),
            ),
            _Meta(
              label: 'Service',
              child: Text(log.service, style: monoStyle.copyWith(fontSize: 12.5, color: scheme.onSurface)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _contextChips() {
    final chips = <Widget>[
      if (log.sessionId != null)
        _LinkChip(
          icon: Icons.timelapse_rounded,
          label: 'Session',
          tooltip: 'Show all logs from session ${log.sessionId}',
          onTap: () => widget.onFilter(AttrFilter('sessionId', FilterOp.equals, log.sessionId!)),
        ),
      if (log.userId != null)
        _LinkChip(
          icon: Icons.person_outline_rounded,
          label: 'User',
          tooltip: widget.projectId == null ? 'Show logs from ${log.userId}' : 'Open ${log.userId} in People',
          onTap: () => widget.projectId == null
              ? widget.onFilter(AttrFilter('userId', FilterOp.equals, log.userId!))
              : context.go('/p/${widget.projectId}/people/${Uri.encodeComponent(log.userId!)}'),
        ),
      if (log.traceId != null)
        _LinkChip(
          icon: Icons.account_tree_outlined,
          label: 'Trace',
          tooltip: 'Show all logs in trace ${log.traceId}',
          onTap: () => widget.onFilter(AttrFilter('traceId', FilterOp.equals, log.traceId!)),
        ),
      _LinkChip(
        icon: Icons.pattern_rounded,
        label: 'Same pattern',
        tooltip: log.pattern,
        onTap: () => setState(() => _tab = _Tab.related),
      ),
    ];
    final missing = [if (log.sessionId == null) 'session', if (log.userId == null) 'user'];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ...chips,
        if (missing.isNotEmpty)
          Tooltip(
            message: 'Set userId / sessionId on the logger to link logs to people and sessions.',
            child: Text(
              'No ${missing.join(' or ')} link',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.outline),
            ),
          ),
      ],
    );
  }

  Widget _tabs(ThemeData theme) {
    final sameCount = _samePattern().length;
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: Row(
        children: [
          _TabButton(
            label: 'Details',
            selected: _tab == _Tab.details,
            onTap: () => setState(() => _tab = _Tab.details),
          ),
          _TabButton(label: 'Raw', selected: _tab == _Tab.raw, onTap: () => setState(() => _tab = _Tab.raw)),
          _TabButton(
            label: 'Related',
            count: sameCount,
            selected: _tab == _Tab.related,
            onTap: () => setState(() => _tab = _Tab.related),
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------------------- details

  List<Widget> _details(ThemeData theme) {
    final attrs = _flatten(log.attributes);
    final isError = log.severity.index >= Severity.error.index;
    return [
      _SectionTitle('Log message'),
      _Box(
        child: SelectableText(
          log.message.isEmpty ? '(empty message)' : log.message,
          style: monoStyle.copyWith(fontSize: 13.5, height: 1.5),
        ),
      ),
      if (log.error != null) ...[const SizedBox(height: 16), _ErrorCard(error: log.error!)],
      if (isError && log.error == null) ...[const SizedBox(height: 10), const _NoErrorDetailsHint()],
      const SizedBox(height: 18),
      _AttrTable(
        title: 'Log attributes',
        empty: 'No attributes',
        rows: [
          for (final e in attrs.entries)
            _AttrRow(key: e.key, filterKey: e.key, value: _display(e.value), mono: true),
        ],
        breakdownKey: _breakdown,
        onToggleBreakdown: (k) => setState(() => _breakdown = _breakdown == k ? null : k),
        breakdown: _breakdownFor,
        onFilter: widget.onFilter,
      ),
      const SizedBox(height: 14),
      _AttrTable(
        title: 'Resource attributes',
        rows: [
          _AttrRow(key: 'service.name', filterKey: 'service', value: log.service, mono: true),
          _AttrRow(key: 'severity', filterKey: 'severity', value: log.severity.id, mono: true),
          if (log.userId != null) _AttrRow(key: 'user.id', filterKey: 'userId', value: log.userId!, mono: true),
          if (log.sessionId != null)
            _AttrRow(key: 'session.id', filterKey: 'sessionId', value: log.sessionId!, mono: true),
          if (log.traceId != null) _AttrRow(key: 'trace.id', filterKey: 'traceId', value: log.traceId!, mono: true),
          _AttrRow(key: 'timestamp', value: log.timestamp.toUtc().toIso8601String(), mono: true),
          if (log.receivedAt != null)
            _AttrRow(
              key: 'received',
              value:
                  '${log.receivedAt!.toUtc().toIso8601String()}  (+${_lag(log.receivedAt!.difference(log.timestamp))})',
              mono: true,
            ),
          _AttrRow(key: 'log.id', value: log.id, mono: true),
        ],
        breakdownKey: _breakdown,
        onToggleBreakdown: (k) => setState(() => _breakdown = _breakdown == k ? null : k),
        breakdown: _breakdownFor,
        onFilter: widget.onFilter,
      ),
    ];
  }

  /// Value counts for one attribute across the loaded logs.
  _Breakdown _breakdownFor(String key) {
    final counts = <String, int>{};
    var have = 0;
    for (final l in widget.related) {
      final v = l.field(key);
      if (v == null) continue;
      have++;
      final s = _display(v);
      counts[s] = (counts[s] ?? 0) + 1;
    }
    final top = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return _Breakdown(total: widget.related.length, have: have, values: top.take(8).toList());
  }

  // ------------------------------------------------------------------- raw

  List<Widget> _raw(ThemeData theme) {
    final json = const JsonEncoder.withIndent('  ').convert(log.toJson());
    return [
      Row(
        children: [
          Expanded(child: _SectionTitle('Raw log', bottom: 0)),
          TextButton.icon(
            onPressed: () => copyToClipboard(context, json, what: 'Log JSON copied'),
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('Copy'),
          ),
        ],
      ),
      const SizedBox(height: 6),
      _Box(
        child: SelectableText(json, style: monoStyle.copyWith(fontSize: 12, height: 1.5)),
      ),
    ];
  }

  // --------------------------------------------------------------- related

  List<LogEntry> _samePattern() =>
      widget.related.where((l) => l.id != log.id && l.fingerprint == log.fingerprint).take(25).toList();

  List<LogEntry> _sameSession() => log.sessionId == null
      ? const []
      : widget.related.where((l) => l.id != log.id && l.sessionId == log.sessionId).take(25).toList();

  List<Widget> _relatedTab(ThemeData theme) {
    final same = _samePattern();
    final session = _sameSession();
    return [
      _SectionTitle('Same pattern'),
      _Box(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Text(log.pattern, style: monoStyle.copyWith(fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
      ),
      const SizedBox(height: 8),
      if (same.isEmpty)
        _muted('No other loaded logs match this pattern.')
      else
        _RelatedList(logs: same, onOpen: widget.onOpen),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => widget.onFilter(AttrFilter('message', FilterOp.contains, _patternProbe(log.message))),
          icon: const Icon(Icons.search_rounded, size: 16),
          label: const Text('Search similar logs'),
        ),
      ),
      if (log.sessionId != null) ...[
        const SizedBox(height: 14),
        _SectionTitle('Same session'),
        if (session.isEmpty)
          _muted('No other loaded logs from this session.')
        else
          _RelatedList(logs: session, onOpen: widget.onOpen),
      ],
      const SizedBox(height: 8),
      _muted('Based on the ${widget.related.length} logs currently loaded.'),
    ];
  }

  Widget _muted(String s) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Text(s, style: Theme.of(context).textTheme.bodySmall),
  );

  /// The longest constant chunk of the message, to search for similar logs.
  static String _patternProbe(String message) {
    final parts = patternOf(message).split(RegExp(r'<[^>]+>')).map((p) => p.trim()).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    return parts.isEmpty || parts.first.isEmpty ? message : parts.first;
  }

  static String _lag(Duration d) {
    final ms = d.inMilliseconds.abs();
    if (ms < 1000) return '${ms}ms';
    if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)}s';
    return '${d.inMinutes.abs()}m';
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

// =================================================================== parts

class _Meta extends StatelessWidget {
  const _Meta({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.outline,
            letterSpacing: 0.8,
            fontSize: 10.5,
          ),
        ),
        const SizedBox(width: 8),
        child,
      ],
    );
  }
}

class _LinkChip extends StatelessWidget {
  const _LinkChip({required this.icon, required this.label, required this.onTap, this.tooltip});

  final IconData icon;
  final String label;
  final String? tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final b = OutlinedButton.icon(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        textStyle: Theme.of(context).textTheme.labelMedium,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      icon: Icon(icon, size: 15),
      label: Text(label),
    );
    return tooltip == null ? b : Tooltip(message: tooltip, child: b);
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({required this.label, required this.selected, required this.onTap, this.count});

  final String label;
  final bool selected;
  final int? count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
        margin: const EdgeInsets.only(right: 18),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: selected ? scheme.primary : Colors.transparent, width: 2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
            if (count != null && count! > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: (selected ? scheme.primary : scheme.outline).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '$count',
                  style: theme.textTheme.labelSmall?.copyWith(color: selected ? scheme.primary : scheme.outline),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {this.bottom = 8});

  final String text;
  final double bottom;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Text(text, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    );
  }
}

/// A quiet bordered box for message / JSON / pattern text.
class _Box extends StatelessWidget {
  const _Box({required this.child, this.padding = const EdgeInsets.all(14)});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: dark ? Colors.black.withValues(alpha: 0.18) : Colors.white.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: child,
    );
  }
}

// ----------------------------------------------------------------- errors

/// Full error details: type, message, reason and a collapsible stack trace.
class _ErrorCard extends StatefulWidget {
  const _ErrorCard({required this.error});

  final LogError error;

  @override
  State<_ErrorCard> createState() => _ErrorCardState();
}

class _ErrorCardState extends State<_ErrorCard> {
  static const _previewLines = 8;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final red = Severity.error.color;
    final e = widget.error;
    final lines = e.stackLines;
    final shown = _expanded ? lines : lines.take(_previewLines).toList();

    return Container(
      decoration: BoxDecoration(
        color: red.withValues(alpha: dark ? 0.10 : 0.05),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: red.withValues(alpha: dark ? 0.35 : 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 6),
            child: Row(
              children: [
                Icon(Icons.error_outline_rounded, size: 18, color: red),
                const SizedBox(width: 8),
                Text('Error details', style: theme.textTheme.titleSmall?.copyWith(color: red)),
                const Spacer(),
                IconButton(
                  tooltip: 'Copy error',
                  icon: const Icon(Icons.copy_rounded, size: 17),
                  onPressed: () => copyToClipboard(context, e.toText(), what: 'Error copied'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (e.type != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: red.withValues(alpha: dark ? 0.18 : 0.10),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      e.type!,
                      style: monoStyle.copyWith(fontSize: 12, fontWeight: FontWeight.w600, color: red),
                    ),
                  ),
                if (e.message != null)
                  SelectableText(e.message!, style: monoStyle.copyWith(fontSize: 13, height: 1.5)),
                if (e.reason != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    'REASON',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                      letterSpacing: 0.8,
                      fontSize: 10.5,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(e.reason!, style: theme.textTheme.bodyMedium),
                ],
                if (lines.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text(
                        'STACK TRACE',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.outline,
                          letterSpacing: 0.8,
                          fontSize: 10.5,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text('${lines.length} frames', style: theme.textTheme.bodySmall),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: dark ? Colors.black.withValues(alpha: 0.28) : Colors.white.withValues(alpha: 0.75),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: theme.colorScheme.outlineVariant),
                    ),
                    child: SelectableText(
                      shown.join('\n'),
                      style: monoStyle.copyWith(fontSize: 11.5, height: 1.55),
                    ),
                  ),
                  if (lines.length > _previewLines)
                    TextButton.icon(
                      onPressed: () => setState(() => _expanded = !_expanded),
                      icon: Icon(_expanded ? Icons.unfold_less_rounded : Icons.unfold_more_rounded, size: 16),
                      label: Text(_expanded ? 'Show less' : 'Show all ${lines.length} frames'),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NoErrorDetailsHint extends StatelessWidget {
  const _NoErrorDetailsHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: "logger.error('Purchase failed', error: e, stackTrace: st, reason: 'Receipt rejected')",
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, size: 15, color: theme.colorScheme.outline),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'No error details. Pass error, stackTrace or reason to logger.error() to capture the full cause.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------- attributes

class _AttrRow {
  const _AttrRow({required this.key, required this.value, this.filterKey, this.mono = false});

  final String key;

  /// The field name used for filters and breakdowns; null = not filterable.
  final String? filterKey;
  final String value;
  final bool mono;
}

class _Breakdown {
  const _Breakdown({required this.total, required this.have, required this.values});

  final int total;
  final int have;
  final List<MapEntry<String, int>> values;
}

class _AttrTable extends StatelessWidget {
  const _AttrTable({
    required this.title,
    required this.rows,
    required this.breakdownKey,
    required this.onToggleBreakdown,
    required this.breakdown,
    required this.onFilter,
    this.empty,
  });

  final String title;
  final List<_AttrRow> rows;
  final String? empty;
  final String? breakdownKey;
  final ValueChanged<String> onToggleBreakdown;
  final _Breakdown Function(String key) breakdown;
  final ValueChanged<AttrFilter> onFilter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            child: Row(
              children: [
                Text(
                  title.toUpperCase(),
                  style: theme.textTheme.labelSmall?.copyWith(
                    letterSpacing: 0.9,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 6),
                Text('${rows.length}', style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline)),
              ],
            ),
          ),
          if (rows.isEmpty && empty != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: Text(empty!, style: theme.textTheme.bodySmall),
            ),
          for (final r in rows) ...[
            Divider(height: 1, color: scheme.outlineVariant),
            _AttrLine(
              row: r,
              open: r.filterKey != null && breakdownKey == r.filterKey,
              onFilter: onFilter,
              onToggleBreakdown: r.filterKey == null ? null : () => onToggleBreakdown(r.filterKey!),
            ),
            if (r.filterKey != null && breakdownKey == r.filterKey)
              _BreakdownView(field: r.filterKey!, data: breakdown(r.filterKey!), onFilter: onFilter),
          ],
        ],
      ),
    );
  }
}

class _AttrLine extends StatefulWidget {
  const _AttrLine({required this.row, required this.open, required this.onFilter, this.onToggleBreakdown});

  final _AttrRow row;
  final bool open;
  final ValueChanged<AttrFilter> onFilter;
  final VoidCallback? onToggleBreakdown;

  @override
  State<_AttrLine> createState() => _AttrLineState();
}

class _AttrLineState extends State<_AttrLine> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final r = widget.row;
    final fk = r.filterKey;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        color: widget.open || _hover ? scheme.onSurface.withValues(alpha: 0.035) : null,
        padding: const EdgeInsets.fromLTRB(6, 4, 8, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _MiniAction(
              icon: Icons.add_box_outlined,
              tooltip: 'Include: ${r.key} = value',
              onTap: fk == null ? null : () => widget.onFilter(AttrFilter(fk, FilterOp.equals, r.value)),
            ),
            _MiniAction(
              icon: Icons.indeterminate_check_box_outlined,
              tooltip: 'Exclude: ${r.key} ≠ value',
              onTap: fk == null ? null : () => widget.onFilter(AttrFilter(fk, FilterOp.notEquals, r.value)),
            ),
            _MiniAction(
              icon: Icons.bar_chart_rounded,
              tooltip: 'Value breakdown',
              selected: widget.open,
              onTap: widget.onToggleBreakdown,
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 120,
              child: Text(
                r.key,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: monoStyle.copyWith(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SelectableText(
                r.value,
                style: (r.mono ? monoStyle : const TextStyle()).copyWith(fontSize: 12.5, color: scheme.onSurface),
              ),
            ),
            AnimatedOpacity(
              duration: const Duration(milliseconds: 120),
              opacity: _hover ? 1 : 0,
              child: _MiniAction(
                icon: Icons.copy_rounded,
                tooltip: 'Copy value',
                onTap: () => copyToClipboard(context, r.value, what: 'Value copied'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniAction extends StatelessWidget {
  const _MiniAction({required this.icon, required this.tooltip, this.onTap, this.selected = false});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? scheme.primary.withValues(alpha: 0.14) : null,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Icon(
            icon,
            size: 16,
            color: selected ? scheme.primary : (enabled ? scheme.outline : scheme.outline.withValues(alpha: 0.3)),
          ),
        ),
      ),
    );
  }
}

class _BreakdownView extends StatelessWidget {
  const _BreakdownView({required this.field, required this.data, required this.onFilter});

  final String field;
  final _Breakdown data;
  final ValueChanged<AttrFilter> onFilter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final pct = NumberFormat.percentPattern();
    return Container(
      color: scheme.onSurface.withValues(alpha: 0.035),
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            data.total == 0
                ? 'No logs loaded to compare with.'
                : '${data.have} of the ${data.total} loaded logs have $field',
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (data.values.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final v in data.values)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    _MiniAction(
                      icon: Icons.add_box_outlined,
                      tooltip: 'Include',
                      onTap: () => onFilter(AttrFilter(field, FilterOp.equals, v.key)),
                    ),
                    _MiniAction(
                      icon: Icons.indeterminate_check_box_outlined,
                      tooltip: 'Exclude',
                      onTap: () => onFilter(AttrFilter(field, FilterOp.notEquals, v.key)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Stack(
                        alignment: Alignment.centerLeft,
                        children: [
                          // Share bar behind the value.
                          FractionallySizedBox(
                            widthFactor: data.have == 0 ? 0 : (v.value / data.have).clamp(0.02, 1.0),
                            child: Container(
                              height: 26,
                              decoration: BoxDecoration(
                                color: scheme.primary.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(6),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    v.key,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: monoStyle.copyWith(fontSize: 12),
                                  ),
                                ),
                                Text(
                                  '${v.value}  ·  ${pct.format(data.have == 0 ? 0 : v.value / data.have)}',
                                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- related

class _RelatedList extends StatelessWidget {
  const _RelatedList({required this.logs, this.onOpen});

  final List<LogEntry> logs;
  final ValueChanged<LogEntry>? onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fmt = DateFormat('MMM d, HH:mm:ss');
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          children: [
            for (var i = 0; i < logs.length; i++) ...[
              if (i > 0) Divider(height: 1, color: scheme.outlineVariant),
              InkWell(
                onTap: onOpen == null ? null : () => onOpen!(logs[i]),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Row(
                    children: [
                      SeverityBadge(logs[i].severity, compact: true),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          logs[i].message,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: monoStyle.copyWith(fontSize: 12),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(fmt.format(logs[i].timestamp), style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
