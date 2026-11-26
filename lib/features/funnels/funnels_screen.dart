import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/app_menu.dart';
import '../../core/glass.dart';
import '../../core/ui.dart';
import '../../data/activity.dart';
import '../../data/funnels.dart';
import '../../data/log_query.dart';
import '../../state/providers.dart';
import '../logs/filter_controls.dart';

enum _Mode { funnel, retention }

/// Funnels (how many people get from step 1 to the last step, in order) and
/// retention (how many come back after their first time), computed in the app
/// from up to [_maxEvents] events of the chosen names.
class FunnelsScreen extends ConsumerStatefulWidget {
  const FunnelsScreen({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<FunnelsScreen> createState() => _FunnelsScreenState();
}

class _FunnelsScreenState extends ConsumerState<FunnelsScreen> {
  /// Events read per run (one Firestore read each).
  static const _maxEvents = 5000;
  static const _windows = <(String, Duration)>[
    ('5 minutes', Duration(minutes: 5)),
    ('30 minutes', Duration(minutes: 30)),
    ('1 hour', Duration(hours: 1)),
    ('1 day', Duration(days: 1)),
    ('7 days', Duration(days: 7)),
    ('14 days', Duration(days: 14)),
  ];

  _Mode _mode = _Mode.funnel;

  // Funnel
  List<String> _steps = [];
  Duration _window = const Duration(days: 1);
  TimeRange _range = const TimeRange.relative(RelativePreset.d7);

  // Retention
  String? _startEvent;
  String? _returnEvent;
  RetentionUnit _unit = RetentionUnit.day;

  Future<_Result>? _future;

  String get _prefKey => 'funnels_${widget.projectId}';

  @override
  void initState() {
    super.initState();
    _restore();
    _run();
  }

  // ------------------------------------------------------- remembered setup

  void _restore() {
    try {
      final raw = ref.read(sharedPreferencesProvider).getString(_prefKey);
      if (raw == null) return;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      _mode = m['mode'] == 'retention' ? _Mode.retention : _Mode.funnel;
      _steps = ((m['steps'] as List?) ?? const []).map((e) => '$e').toList();
      _window = Duration(minutes: (m['windowMin'] as num?)?.toInt() ?? 1440);
      _range = TimeRange.relative(RelativePreset.tryParse(m['range'] as String?) ?? RelativePreset.d7);
      _startEvent = m['start'] as String?;
      _returnEvent = m['return'] as String?;
      _unit = m['unit'] == 'week' ? RetentionUnit.week : RetentionUnit.day;
    } catch (_) {}
  }

  void _save() {
    try {
      ref
          .read(sharedPreferencesProvider)
          .setString(
            _prefKey,
            jsonEncode({
              'mode': _mode.name,
              'steps': _steps,
              'windowMin': _window.inMinutes,
              'range': _range.preset?.id,
              'start': _startEvent,
              'return': _returnEvent,
              'unit': _unit.name,
            }),
          );
    } catch (_) {}
  }

  void _changed(VoidCallback change) {
    setState(change);
    _save();
    _run();
  }

  // ----------------------------------------------------------------- loading

  /// Retention looks back far enough for its cohorts plus their periods.
  int get _periods => _unit == RetentionUnit.day ? 7 : 6;
  Duration get _retentionSpan => _unit.length * (_periods * 2);

  void _run() {
    final pid = widget.projectId;
    final repo = ref.read(activityRepositoryProvider);
    if (_mode == _Mode.funnel) {
      final steps = [..._steps];
      if (steps.length < 2) {
        setState(() => _future = null);
        return;
      }
      final q = ActivityQuery(range: _range, events: steps.toSet().toList());
      setState(() {
        _future = repo.fetchPage(pid, q, want: _maxEvents, maxScan: _maxEvents, pageSize: 500).then(
          (p) => _Result(events: p.events.length, capped: p.hasMore, funnel: computeFunnel(p.events, steps, _window)),
        );
      });
    } else {
      final start = _startEvent, back = _returnEvent;
      if (start == null || back == null) {
        setState(() => _future = null);
        return;
      }
      final now = DateTime.now();
      final from = periodStart(now.subtract(_retentionSpan), _unit);
      final q = ActivityQuery(range: TimeRange.absolute(from, now), events: {start, back}.toList());
      final unit = _unit, periods = _periods;
      setState(() {
        _future = repo.fetchPage(pid, q, want: _maxEvents, maxScan: _maxEvents, pageSize: 500).then(
          (p) => _Result(
            events: p.events.length,
            capped: p.hasMore,
            retention: computeRetention(
              p.events,
              startEvent: start,
              returnEvent: back,
              unit: unit,
              periods: periods,
              from: from,
              now: now,
            ),
          ),
        );
      });
    }
  }

  // --------------------------------------------------------------------- UI

  List<MenuEntry<String>> _eventEntries() {
    final defs = ref.read(eventDefinitionsProvider(widget.projectId)).value ?? const <EventDefinition>[];
    return [for (final d in defs) MenuEntry(d.name, d.name, mono: true)];
  }

  Widget _eventPicker({required String? value, required String hint, required ValueChanged<String> onSelected}) =>
      AppMenuAnchor<String>(
        tooltip: hint,
        selected: {?value},
        searchHint: 'Search events',
        entries: _eventEntries,
        onSelected: onSelected,
        onCustom: (query) => query.trim(), // events not seen yet can be typed in
        builder: (context, open) =>
            MenuPill(icon: Icons.bolt_outlined, label: value ?? hint, mono: value != null, active: value != null, open: open),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    ref.watch(eventDefinitionsProvider(widget.projectId));
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
      children: [
        Text('Funnels & retention', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          _mode == _Mode.funnel
              ? 'How many people get through a series of events, in order.'
              : 'How many people come back after the first time they did something.',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        SegmentedButton<_Mode>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: _Mode.funnel, label: Text('Funnel'), icon: Icon(Icons.filter_alt_outlined)),
            ButtonSegment(value: _Mode.retention, label: Text('Retention'), icon: Icon(Icons.replay_rounded)),
          ],
          selected: {_mode},
          onSelectionChanged: (s) => _changed(() => _mode = s.first),
        ),
        const SizedBox(height: 16),
        if (_mode == _Mode.funnel) _funnelControls(theme) else _retentionControls(),
        const SizedBox(height: 16),
        _results(theme),
      ],
    );
  }

  Widget _funnelControls(ThemeData theme) => GlassCard(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TimeRangeButton(range: _range, onChanged: (r) => _changed(() => _range = r)),
              AppMenuAnchor<Duration>(
                tooltip: 'Conversion window',
                searchable: false,
                selected: {_window},
                entries: () => [for (final w in _windows) MenuEntry(w.$2, 'Within ${w.$1}')],
                onSelected: (w) => _changed(() => _window = w),
                builder: (context, open) => MenuPill(
                  icon: Icons.timer_outlined,
                  label: 'Within ${_windows.firstWhere((w) => w.$2 == _window, orElse: () => _windows[3]).$1}',
                  open: open,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < _steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  _StepNumber(i + 1),
                  const SizedBox(width: 10),
                  Flexible(
                    child: _eventPicker(
                      value: _steps[i],
                      hint: 'Event',
                      onSelected: (v) => _changed(() => _steps[i] = v),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Remove step',
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () => _changed(() => _steps.removeAt(i)),
                  ),
                ],
              ),
            ),
          if (_steps.length < 10)
            Row(
              children: [
                _StepNumber(_steps.length + 1, faded: true),
                const SizedBox(width: 10),
                _eventPicker(
                  value: null,
                  hint: _steps.isEmpty ? 'Add the first step' : 'Add a step',
                  onSelected: (v) => _changed(() => _steps.add(v)),
                ),
              ],
            ),
        ],
      ),
    ),
  );

  Widget _retentionControls() => GlassCard(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Wrap(
        spacing: 8,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text('People who did'),
          _eventPicker(value: _startEvent, hint: 'Start event', onSelected: (v) => _changed(() => _startEvent = v)),
          const Text('and came back to do'),
          _eventPicker(value: _returnEvent, hint: 'Return event', onSelected: (v) => _changed(() => _returnEvent = v)),
          SegmentedButton<RetentionUnit>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: RetentionUnit.day, label: Text('Daily')),
              ButtonSegment(value: RetentionUnit.week, label: Text('Weekly')),
            ],
            selected: {_unit},
            onSelectionChanged: (s) => _changed(() => _unit = s.first),
          ),
        ],
      ),
    ),
  );

  Widget _results(ThemeData theme) {
    if (_future == null) {
      return GlassCard(
        child: EmptyState(
          icon: _mode == _Mode.funnel ? Icons.filter_alt_outlined : Icons.replay_rounded,
          title: _mode == _Mode.funnel ? 'Add at least two steps' : 'Pick a start and a return event',
          message: _mode == _Mode.funnel
              ? 'For example app_open → signup_completed → purchase_completed.'
              : 'For example signup_completed, then app_open.',
        ),
      );
    }
    return FutureBuilder<_Result>(
      future: _future,
      builder: (context, snap) {
        if (snap.hasError) return ErrorView(snap.error!, onRetry: _run);
        if (!snap.hasData) {
          return const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()));
        }
        final r = snap.data!;
        final fmt = NumberFormat.decimalPattern();
        final note = Text(
          r.capped
              ? 'Based on the latest ${fmt.format(r.events)} matching events in the range; a shorter range gives exact results.'
              : 'Based on all ${fmt.format(r.events)} matching events in the range.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (r.funnel != null) _FunnelView(r.funnel!) else _RetentionView(r.retention!),
            const SizedBox(height: 8),
            note,
          ],
        );
      },
    );
  }
}

class _Result {
  const _Result({required this.events, required this.capped, this.funnel, this.retention});

  final int events;

  /// Stopped at the event limit, so results cover only the newest events.
  final bool capped;
  final FunnelResult? funnel;
  final RetentionResult? retention;
}

class _StepNumber extends StatelessWidget {
  const _StepNumber(this.n, {this.faded = false});

  final int n;
  final bool faded;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CircleAvatar(
      radius: 12,
      backgroundColor: faded ? scheme.surfaceContainerHighest : scheme.primaryContainer,
      child: Text(
        '$n',
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: faded ? scheme.outline : scheme.onPrimaryContainer),
      ),
    );
  }
}

String _pct(double v) => '${(v * 100).toStringAsFixed(v < 0.1 && v > 0 ? 1 : 0)}%';

String _duration(Duration d) {
  if (d.inDays >= 1) return '${d.inDays}d ${d.inHours % 24}h';
  if (d.inHours >= 1) return '${d.inHours}h ${d.inMinutes % 60}m';
  if (d.inMinutes >= 1) return '${d.inMinutes}m ${d.inSeconds % 60}s';
  return '${d.inSeconds}s';
}

class _FunnelView extends StatelessWidget {
  const _FunnelView(this.r);

  final FunnelResult r;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (r.entered == 0) {
      return GlassCard(
        child: EmptyState(
          icon: Icons.search_off_rounded,
          title: 'Nobody did “${r.steps.first}” in this range',
          message: 'Try a longer range or another first step.',
        ),
      );
    }
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${_pct(r.conversion)} converted', style: theme.textTheme.titleLarge),
            Text(
              '${r.reached.last} of ${r.entered} people reached the last step',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            for (var i = 0; i < r.steps.length; i++) ...[
              if (i > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 34, top: 2, bottom: 6),
                  child: Text(
                    [
                      '↓ ${_pct(r.ofPrevious(i))} continued',
                      '${r.reached[i - 1] - r.reached[i]} dropped off',
                      if (r.medianToNext[i - 1] != null) 'median ${_duration(r.medianToNext[i - 1]!)}',
                    ].join(' · '),
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              Row(
                children: [
                  _StepNumber(i + 1),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                r.steps[i],
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600),
                              ),
                            ),
                            Text('${r.reached[i]}', style: theme.textTheme.titleSmall),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 48,
                              child: Text(
                                _pct(r.ofFirst(i)),
                                textAlign: TextAlign.right,
                                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: r.ofFirst(i),
                            minHeight: 10,
                            backgroundColor: scheme.surfaceContainerHighest,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RetentionView extends StatelessWidget {
  const _RetentionView(this.r);

  final RetentionResult r;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (r.cohorts.isEmpty) {
      return const GlassCard(
        child: EmptyState(icon: Icons.search_off_rounded, title: 'Nobody did the start event in this period'),
      );
    }
    final dateFmt = DateFormat(r.unit == RetentionUnit.day ? 'EEE d MMM' : "'Week of' d MMM");
    const cellW = 64.0, firstW = 130.0, sizeW = 70.0;

    Widget cell(double? rate, {bool bold = false}) => Container(
      width: cellW,
      height: 34,
      margin: const EdgeInsets.all(1.5),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: rate == null ? null : scheme.primary.withValues(alpha: 0.08 + 0.72 * rate),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        rate == null ? '' : _pct(rate),
        style: TextStyle(
          fontSize: 12,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
          color: rate != null && rate > 0.5 ? scheme.onPrimary : scheme.onSurface,
        ),
      ),
    );

    Widget head(String text, double w) => SizedBox(
      width: w,
      child: Text(
        text,
        textAlign: w == firstW ? TextAlign.left : TextAlign.center,
        style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );

    final total = r.cohorts.fold<int>(0, (a, c) => a + c.size);
    return GlassCard(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                head('Cohort', firstW),
                head('People', sizeW),
                for (var p = 1; p <= r.periods; p++) head('${r.unit.label} $p', cellW + 3),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                SizedBox(width: firstW, child: Text('Average', style: theme.textTheme.labelLarge)),
                SizedBox(width: sizeW, child: Text('$total', textAlign: TextAlign.center)),
                for (final a in r.average) cell(a, bold: true),
              ],
            ),
            const Divider(),
            for (final c in r.cohorts.reversed)
              Row(
                children: [
                  SizedBox(width: firstW, child: Text(dateFmt.format(c.start), style: theme.textTheme.bodySmall)),
                  SizedBox(width: sizeW, child: Text('${c.size}', textAlign: TextAlign.center)),
                  for (var p = 0; p < r.periods; p++) cell(c.rate(p)),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
