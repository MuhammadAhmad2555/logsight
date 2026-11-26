import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/app_menu.dart';
import '../../core/glass.dart';
import '../../core/severity.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../data/endpoints.dart';
import '../../data/log_query.dart';
import '../../data/log_repository.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../flags/flags_screen.dart' show CodeBlock;
import '../help/help_screen.dart' show HelpLink;
import '../logs/filter_controls.dart';

enum _Sort {
  calls('Most calls'),
  errors('Most errors'),
  errorRate('Highest error rate'),
  slowest('Slowest (p95)');

  const _Sort(this.label);
  final String label;
}

/// API endpoints seen in request logs: calls, error rate and latency per
/// method + route. Apps send request logs with `appTrack.request(...)`.
class EndpointsScreen extends ConsumerStatefulWidget {
  const EndpointsScreen({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<EndpointsScreen> createState() => _EndpointsScreenState();
}

class _EndpointsScreenState extends ConsumerState<EndpointsScreen> {
  static const _maxLogs = 3000;

  TimeRange _range = const TimeRange.relative(RelativePreset.h24);
  String? _service;
  _Sort _sort = _Sort.calls;
  late Future<LogPage> _future = _load();

  LogQuery get _query => LogQuery(
    range: _range,
    services: _service == null ? const [] : [_service!],
    search: requestToken,
  );

  Future<LogPage> _load() => ref
      .read(logRepositoryProvider)
      .fetchPage(widget.projectId, _query, want: _maxLogs, maxScan: _maxLogs, pageSize: 500);

  void _reload() => setState(() => _future = _load());

  @override
  void didUpdateWidget(EndpointsScreen old) {
    super.didUpdateWidget(old);
    if (old.projectId != widget.projectId) _reload();
  }

  void _openLogs(EndpointStats e, {bool errorsOnly = false}) {
    final q = _query.copyWith(
      filters: [
        AttrFilter(e.routeKey, FilterOp.equals, e.route),
        if (e.method != '—') AttrFilter('http.method', FilterOp.equals, e.method),
      ],
      severities: errorsOnly ? {Severity.error, Severity.fatal} : null,
    );
    context.go(Uri(path: '/p/${widget.projectId}/logs', queryParameters: q.toQueryParameters()).toString());
  }

  List<EndpointStats> _sorted(List<EndpointStats> list) {
    final out = [...list];
    switch (_sort) {
      case _Sort.calls:
        out.sort((a, b) => b.calls.compareTo(a.calls));
      case _Sort.errors:
        out.sort((a, b) => b.serverErrors.compareTo(a.serverErrors));
      case _Sort.errorRate:
        out.sort((a, b) => b.errorRate.compareTo(a.errorRate));
      case _Sort.slowest:
        out.sort((a, b) => (b.p95 ?? -1).compareTo(a.p95 ?? -1));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final services = ref.watch(servicesProvider(widget.projectId)).value ?? const <ServiceInfo>[];
    return RefreshIndicator(
      onRefresh: () async {
        _reload();
        await _future;
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
        children: [
          Row(
            children: [
              Expanded(child: Text('Endpoints', style: theme.textTheme.headlineSmall)),
              HelpLink(projectId: widget.projectId, topic: 'endpoints-sdk'),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Calls, errors and latency of every API route your apps call or serve.',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TimeRangeButton(
                range: _range,
                onChanged: (r) {
                  _range = r;
                  _reload();
                },
              ),
              AppMenuAnchor<String>(
                tooltip: 'Service',
                selected: {_service ?? ''},
                entries: () => [
                  const MenuEntry('', 'All services'),
                  for (final s in services) MenuEntry(s.name, s.name, mono: true),
                ],
                onSelected: (v) {
                  _service = v.isEmpty ? null : v;
                  _reload();
                },
                builder: (context, open) => MenuPill(
                  icon: Icons.apps_rounded,
                  label: _service ?? 'All services',
                  open: open,
                  active: _service != null,
                ),
              ),
              AppMenuAnchor<_Sort>(
                tooltip: 'Sort',
                searchable: false,
                selected: {_sort},
                entries: () => [for (final s in _Sort.values) MenuEntry(s, s.label)],
                onSelected: (s) => setState(() => _sort = s),
                builder: (context, open) => MenuPill(icon: Icons.sort_rounded, label: _sort.label, open: open),
              ),
              IconButton(tooltip: 'Refresh', onPressed: _reload, icon: const Icon(Icons.refresh_rounded)),
            ],
          ),
          const SizedBox(height: 16),
          FutureBuilder<LogPage>(
            future: _future,
            builder: (context, snap) {
              if (snap.hasError) return ErrorView(snap.error!);
              if (!snap.hasData) {
                return const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()));
              }
              final page = snap.data!;
              final stats = endpointStats(page.logs);
              if (stats.isEmpty) return const _Empty();
              return _Results(
                stats: _sorted(stats),
                capped: page.hasMore,
                logCount: page.logs.length,
                onOpen: _openLogs,
              );
            },
          ),
        ],
      ),
    );
  }
}

class _Results extends StatelessWidget {
  const _Results({required this.stats, required this.capped, required this.logCount, required this.onOpen});

  final List<EndpointStats> stats;
  final bool capped;
  final int logCount;
  final void Function(EndpointStats e, {bool errorsOnly}) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final calls = stats.fold<int>(0, (s, e) => s + e.calls);
    final errors = stats.fold<int>(0, (s, e) => s + e.serverErrors);
    final p95s = [for (final e in stats) if (e.p95 != null) e.p95!]..sort();
    final worstP95 = p95s.isEmpty ? null : p95s.last;
    final fmt = NumberFormat.compact();
    final wide = isWide(context);
    final tiles = [
      _Stat('Requests', fmt.format(calls), Icons.swap_vert_rounded),
      _Stat(
        'Error rate',
        calls == 0 ? '—' : '${(errors / calls * 100).toStringAsFixed(errors / calls < 0.1 ? 1 : 0)}%',
        Icons.error_outline_rounded,
        color: errors > 0 ? Severity.error.color : null,
      ),
      _Stat('Endpoints', '${stats.length}', Icons.alt_route_rounded),
      _Stat('Slowest p95', worstP95 == null ? '—' : formatMs(worstP95), Icons.speed_rounded),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GridView.count(
          crossAxisCount: wide ? 4 : 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: wide ? 2.6 : 2.1,
          children: tiles,
        ),
        if (capped)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              'Based on the latest ${fmt.format(logCount)} requests in this range.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        const SizedBox(height: 16),
        GlassCard(
          child: Column(
            children: [
              for (var i = 0; i < stats.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                _EndpointRow(e: stats[i], maxCalls: stats.map((s) => s.calls).reduce((a, b) => a > b ? a : b), onOpen: onOpen),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

String formatMs(double ms) => ms >= 1000 ? '${(ms / 1000).toStringAsFixed(ms >= 10000 ? 0 : 1)} s' : '${ms.round()} ms';

Color methodColor(String m) => switch (m) {
  'GET' => const Color(0xFF3B82F6),
  'POST' => const Color(0xFF22C55E),
  'PUT' || 'PATCH' => const Color(0xFFF59E0B),
  'DELETE' => const Color(0xFFEF4444),
  _ => const Color(0xFF8B5CF6),
};

class _EndpointRow extends StatelessWidget {
  const _EndpointRow({required this.e, required this.maxCalls, required this.onOpen});

  final EndpointStats e;
  final int maxCalls;
  final void Function(EndpointStats e, {bool errorsOnly}) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mc = methodColor(e.method);
    final rate = e.errorRate * 100;
    final rateColor = rate >= 5 ? Severity.error.color : (rate > 0 ? Severity.warn.color : scheme.onSurfaceVariant);
    final metrics = Wrap(
      spacing: 14,
      runSpacing: 4,
      children: [
        _Metric('calls', NumberFormat.compact().format(e.calls)),
        _Metric('errors', rate == 0 ? '0%' : '${rate.toStringAsFixed(rate < 10 ? 1 : 0)}%', color: rateColor),
        if (e.clientErrors > 0) _Metric('4xx', '${e.clientErrors}'),
        _Metric('p50', e.p50 == null ? '—' : formatMs(e.p50!)),
        _Metric('p95', e.p95 == null ? '—' : formatMs(e.p95!)),
      ],
    );
    return InkWell(
      onTap: () => onOpen(e),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: mc.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          e.method,
                          style: TextStyle(color: mc, fontWeight: FontWeight.w800, fontSize: 11, letterSpacing: 0.4),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          e.route,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace', fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: maxCalls == 0 ? 0 : e.calls / maxCalls,
                      minHeight: 4,
                      backgroundColor: scheme.onSurface.withValues(alpha: 0.06),
                    ),
                  ),
                  const SizedBox(height: 6),
                  metrics,
                  const SizedBox(height: 2),
                  Text(
                    '${e.services.join(', ')} · last ${timeAgo(e.lastSeen)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
                  ),
                ],
              ),
            ),
            if (e.serverErrors > 0)
              IconButton(
                tooltip: 'Show failed requests',
                onPressed: () => onOpen(e, errorsOnly: true),
                icon: Icon(Icons.report_gmailerrorred_rounded, color: Severity.error.color),
              ),
            Icon(Icons.chevron_right_rounded, color: scheme.outline),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric(this.label, this.value, {this.color});
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: value,
            style: TextStyle(fontWeight: FontWeight.w700, color: color ?? theme.colorScheme.onSurface),
          ),
          TextSpan(text: ' $label', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
      style: theme.textTheme.labelMedium,
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, this.icon, {this.color});
  final String label;
  final String value;
  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = color ?? theme.colorScheme.primary;
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(11)),
              child: Icon(icon, color: c, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelMedium),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      value,
                      style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800, color: color),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.alt_route_rounded, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(child: Text('No requests in this range', style: theme.textTheme.titleMedium)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Log each API call with the AppTrack logger, e.g. in your HTTP client or server middleware:',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 10),
            const CodeBlock(
              '''final sw = Stopwatch()..start();
final res = await http.get(uri);
appTrack.request('GET', '/api/orders/:id',
    statusCode: res.statusCode, duration: sw.elapsed);''',
            ),
            const SizedBox(height: 10),
            Text(
              'Use the route pattern (/api/orders/:id), not the full URL, so calls group together. '
              '5xx responses count as errors, 4xx are shown separately.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
