import 'dart:async';

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
    required this.errorLogs,
    required this.states,
  });

  /// Counts and the chart; re-counted every minute while the page is open.
  int total;
  int errors;
  Map<String, int> perService;
  List<VolumeBucket> volume;

  /// Latest error logs, newest first; new ones are added as they arrive.
  List<LogEntry> errorLogs;
  final Map<String, IssueState> states;

  List<IssueGroup> get issues =>
      groupIssues(errorLogs, states).where((i) => i.status != IssueStatus.ignored).take(5).toList();
  List<LogEntry> get recentErrors => errorLogs.take(8).toList();
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

  /// Live updates: new error logs are merged in as they arrive; counts and
  /// the chart are re-counted every [_recount].
  static const _recount = Duration(minutes: 1);
  static const _errorCap = 1000;
  int _gen = 0;
  StreamSubscription<List<LogEntry>>? _tail;
  Timer? _timer;
  final Set<String> _errorIds = {};

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void dispose() {
    _stopLive();
    super.dispose();
  }

  void _stopLive() {
    _tail?.cancel();
    _tail = null;
    _timer?.cancel();
    _timer = null;
  }

  void _startLive(int gen, _OverviewData data, DateTime since) {
    final pid = widget.projectId;
    final errQ = LogQuery(range: TimeRange.relative(_range), severities: _errorLevels);
    _tail = ref
        .read(logRepositoryProvider)
        .watchArrivals(pid, errQ, since: since)
        .listen((logs) {
          if (gen != _gen || !mounted) return;
          final (from, _) = errQ.range.resolve();
          final fresh = logs.where((l) => _errorIds.add(l.id) && !l.timestamp.isBefore(from)).toList();
          if (fresh.isEmpty) return;
          setState(() {
            data.errorLogs = ([...fresh, ...data.errorLogs]..sort((a, b) => b.timestamp.compareTo(a.timestamp)))
                .take(_errorCap)
                .toList();
          });
        }, onError: (_) {});
    _timer = Timer.periodic(_recount, (_) async {
      try {
        final c = await _counts(pid, _servicesLoaded);
        if (gen != _gen || !mounted) return;
        setState(() {
          data.total = c.total;
          data.errors = c.errors;
          data.volume = c.volume;
          data.perService = c.perService;
        });
      } catch (_) {
        // Keep the last numbers; the next tick tries again.
      }
    });
  }

  Future<({int total, int errors, List<VolumeBucket> volume, Map<String, int> perService})> _counts(
    String pid,
    List<String> services,
  ) async {
    final repo = ref.read(logRepositoryProvider);
    final q = LogQuery(range: TimeRange.relative(_range));
    final r = await Future.wait([
      repo.count(pid, q),
      repo.count(pid, q.copyWith(severities: _errorLevels)),
      repo.volume(pid, q, maxBuckets: 30),
      for (final s in services) repo.count(pid, q.copyWith(services: [s])),
    ]);
    return (
      total: r[0] as int,
      errors: r[1] as int,
      volume: r[2] as List<VolumeBucket>,
      perService: {for (var i = 0; i < services.length; i++) services[i]: r[3 + i] as int},
    );
  }

  @override
  void didUpdateWidget(OverviewScreen old) {
    super.didUpdateWidget(old);
    if (old.projectId != widget.projectId) _refresh();
  }

  void _refresh() => setState(() => _future = _load());

  Future<_OverviewData> _load() async {
    final gen = ++_gen;
    _stopLive();
    _errorIds.clear();
    // Errors arriving from here on are merged in live (duplicates dropped by id).
    final since = DateTime.now().subtract(const Duration(minutes: 2));
    final repo = ref.read(logRepositoryProvider);
    final pid = widget.projectId;
    final q = LogQuery(range: TimeRange.relative(_range));
    final errQ = q.copyWith(severities: _errorLevels);
    // Read the streams' first value directly: in Riverpod 3 a provider read
    // with ref.read (no listener) is paused, so awaiting its .future hangs.
    final services = (await ref.read(projectRepositoryProvider).watchServices(pid).first)
        .map((s) => s.name)
        .take(12)
        .toList();
    _servicesLoaded = services;

    final results = await Future.wait([
      _counts(pid, services),
      repo.fetchPage(pid, errQ, want: _errorCap, maxScan: _errorCap),
      ref.read(insightsRepositoryProvider).watchIssues(pid).first,
    ]);
    final c = results[0] as ({int total, int errors, List<VolumeBucket> volume, Map<String, int> perService});
    final errorPage = results[1] as LogPage;
    final data = _OverviewData(
      total: c.total,
      errors: c.errors,
      volume: c.volume,
      perService: c.perService,
      errorLogs: errorPage.logs,
      states: results[2] as Map<String, IssueState>,
    );
    _errorIds.addAll(errorPage.logs.map((l) => l.id));
    if (gen == _gen && mounted) _startLive(gen, data, since);
    return data;
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
