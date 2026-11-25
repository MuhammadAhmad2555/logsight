import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/glass.dart';
import '../../core/severity.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../data/insights.dart';
import '../../data/log_query.dart';
import '../../data/log_repository.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../logs/volume_chart.dart';

/// Everything loaded for one Overview range.
class _OverviewData {
  _OverviewData({
    required this.total,
    required this.errors,
    required this.perService,
    required this.volume,
    required this.issues,
    required this.recentErrors,
  });

  final int total;
  final int errors;
  final Map<String, int> perService;
  final List<VolumeBucket> volume;
  final List<IssueGroup> issues;
  final List<LogEntry> recentErrors;
}

/// Project dashboard: totals, error rate, logs per service, volume,
/// top issues and recent errors.
class OverviewScreen extends ConsumerStatefulWidget {
  const OverviewScreen({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<OverviewScreen> createState() => _OverviewScreenState();
}

class _OverviewScreenState extends ConsumerState<OverviewScreen> {
  RelativePreset _range = RelativePreset.h24;
  Future<_OverviewData>? _future;
  List<String> _servicesLoaded = const [];

  static const _errorLevels = {Severity.error, Severity.fatal};

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(OverviewScreen old) {
    super.didUpdateWidget(old);
    if (old.projectId != widget.projectId) _refresh();
  }

  void _refresh() => setState(() => _future = _load());

  Future<_OverviewData> _load() async {
    final repo = ref.read(logRepositoryProvider);
    final pid = widget.projectId;
    final q = LogQuery(range: TimeRange.relative(_range));
    final errQ = q.copyWith(severities: _errorLevels);
    final services = (await ref.read(servicesProvider(pid).future)).map((s) => s.name).take(12).toList();
    _servicesLoaded = services;

    final results = await Future.wait([
      repo.count(pid, q),
      repo.count(pid, errQ),
      repo.volume(pid, q, maxBuckets: 30),
      repo.fetchPage(pid, errQ, want: 1000, maxScan: 1000),
      for (final s in services) repo.count(pid, q.copyWith(services: [s])),
    ]);
    final errorPage = results[3] as LogPage;
    final states = await ref.read(issueStatesProvider(pid).future);
    return _OverviewData(
      total: results[0] as int,
      errors: results[1] as int,
      volume: results[2] as List<VolumeBucket>,
      issues: groupIssues(errorPage.logs, states).where((i) => i.status != IssueStatus.ignored).take(5).toList(),
      recentErrors: errorPage.logs.take(8).toList(),
      perService: {for (var i = 0; i < services.length; i++) services[i]: results[4 + i] as int},
    );
  }

  void _openLogs({String? service, Set<Severity>? severities, AttrFilter? filter}) {
    final q = LogQuery(
      range: TimeRange.relative(_range),
      services: service == null ? const [] : [service],
      severities: severities ?? const {},
      filters: filter == null ? const [] : [filter],
    );
    context.go(Uri(path: '/p/${widget.projectId}/logs', queryParameters: q.toQueryParameters()).toString());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wide = isWide(context);
    return RefreshIndicator(
      onRefresh: () async {
        _refresh();
        await _future;
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Text('Overview', style: theme.textTheme.headlineSmall),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SegmentedButton<RelativePreset>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: RelativePreset.h24, label: Text('24h')),
                      ButtonSegment(value: RelativePreset.d7, label: Text('7d')),
                      ButtonSegment(value: RelativePreset.d30, label: Text('30d')),
                    ],
                    selected: {_range},
                    onSelectionChanged: (s) {
                      _range = s.first;
                      _refresh();
                    },
                  ),
                  IconButton(tooltip: 'Refresh', onPressed: _refresh, icon: const Icon(Icons.refresh)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          FutureBuilder<_OverviewData>(
            future: _future,
            builder: (context, snap) {
              if (snap.hasError) return ErrorView(snap.error!, onRetry: _refresh);
              if (!snap.hasData) {
                return const Padding(
                  padding: EdgeInsets.all(48),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              return _body(snap.data!, wide);
            },
          ),
        ],
      ),
    );
  }

  Widget _body(_OverviewData d, bool wide) {
    final fmt = NumberFormat.decimalPattern();
    final rate = d.total == 0 ? 0.0 : d.errors / d.total * 100;
    final active = d.perService.values.where((c) => c > 0).length;
    final tiles = [
      _StatTile(label: 'Logs', value: fmt.format(d.total), icon: Icons.receipt_long, onTap: () => _openLogs()),
      _StatTile(
        label: 'Errors',
        value: fmt.format(d.errors),
        icon: Icons.error_outline,
        color: Severity.error.color,
        onTap: () => _openLogs(severities: _errorLevels),
      ),
      _StatTile(
        label: 'Error rate',
        value: '${rate.toStringAsFixed(rate < 10 ? 1 : 0)}%',
        icon: Icons.percent,
        color: rate >= 5 ? Severity.error.color : null,
      ),
      _StatTile(label: 'Active services', value: '$active / ${_servicesLoaded.length}', icon: Icons.apps),
    ];

    final serviceCard = GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionLabel('Logs per service.name'),
            if (d.perService.isEmpty)
              const Padding(padding: EdgeInsets.all(8), child: Text('No services yet.'))
            else
              ..._serviceBars(d.perService),
          ],
        ),
      ),
    );

    final volumeCard = GlassCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionLabel('Log volume'),
            SizedBox(
              height: 150,
              child: VolumeChart(
                buckets: d.volume,
                onZoom: (from, to) {
                  final q = LogQuery(range: TimeRange.absolute(from, to));
                  context.go(
                    Uri(path: '/p/${widget.projectId}/logs', queryParameters: q.toQueryParameters()).toString(),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );

    final issuesCard = GlassCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionLabel(
              'Top issues',
              trailing: TextButton(
                onPressed: () => context.go('/p/${widget.projectId}/issues'),
                child: const Text('All issues'),
              ),
            ),
            if (d.issues.isEmpty)
              const Padding(padding: EdgeInsets.fromLTRB(4, 0, 4, 12), child: Text('No errors in this range 🎉'))
            else
              for (final i in d.issues)
                ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  leading: Icon(
                    i.regressed ? Icons.replay : Icons.bug_report_outlined,
                    color: i.regressed ? Severity.warn.color : Severity.error.color,
                  ),
                  title: Text(i.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${i.service} · ${timeAgo(i.lastSeen)}${i.regressed ? ' · regressed' : ''}'),
                  trailing: Text('${i.count}×', style: const TextStyle(fontWeight: FontWeight.w700)),
                  onTap: () => _openLogs(
                    service: i.service,
                    severities: _errorLevels,
                    filter: AttrFilter('pattern', FilterOp.equals, i.pattern),
                  ),
                ),
          ],
        ),
      ),
    );

    final recentCard = GlassCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionLabel('Recent errors'),
            if (d.recentErrors.isEmpty)
              const Padding(padding: EdgeInsets.fromLTRB(4, 0, 4, 12), child: Text('Nothing to show.'))
            else
              for (final l in d.recentErrors)
                ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  leading: SeverityBadge(l.severity, compact: true),
                  title: Text(l.message, maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle),
                  subtitle: Text('${l.service} · ${timeAgo(l.timestamp)}'),
                  onTap: () => _openLogs(service: l.service, severities: _errorLevels),
                ),
          ],
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, c) {
            final cols = c.maxWidth > 900 ? 4 : 2;
            final w = (c.maxWidth - 12 * (cols - 1)) / cols;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [for (final t in tiles) SizedBox(width: w, child: t)],
            );
          },
        ),
        const SizedBox(height: 16),
        if (wide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: volumeCard),
              const SizedBox(width: 16),
              Expanded(flex: 2, child: serviceCard),
            ],
          )
        else ...[
          volumeCard,
          const SizedBox(height: 16),
          serviceCard,
        ],
        const SizedBox(height: 16),
        if (wide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: issuesCard),
              const SizedBox(width: 16),
              Expanded(child: recentCard),
            ],
          )
        else ...[
          issuesCard,
          const SizedBox(height: 16),
          recentCard,
        ],
      ],
    );
  }

  List<Widget> _serviceBars(Map<String, int> perService) {
    final scheme = Theme.of(context).colorScheme;
    final entries = perService.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final max = entries.isEmpty ? 1 : (entries.first.value == 0 ? 1 : entries.first.value);
    return [
      for (final e in entries)
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => _openLogs(service: e.key),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(e.key, style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    Text(NumberFormat.compact().format(e.value)),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: e.value / max,
                    minHeight: 6,
                    backgroundColor: scheme.outlineVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
    ];
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.label, required this.value, required this.icon, this.color, this.onTap});

  final String label;
  final String value;
  final IconData icon;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = color ?? theme.colorScheme.primary;
    return GlassCard(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(12)),
                child: Icon(icon, color: c, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    Text(value, style: theme.textTheme.titleLarge?.copyWith(color: color)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
