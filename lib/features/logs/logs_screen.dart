import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/app_menu.dart';
import '../../core/glass.dart';
import '../../core/severity.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../data/log_query.dart';
import '../../data/insights.dart';
import '../../data/log_repository.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import 'filter_controls.dart';
import 'log_detail.dart';
import 'volume_chart.dart';

/// The log explorer: time range, filters, volume chart, results and details.
/// All filters live in the URL, so any view can be bookmarked or shared.
class LogsScreen extends ConsumerStatefulWidget {
  const LogsScreen({super.key, required this.projectId, required this.query});

  final String projectId;
  final LogQuery query;

  @override
  ConsumerState<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends ConsumerState<LogsScreen> {
  final _scroll = ScrollController();
  late final TextEditingController _search = TextEditingController(text: widget.query.search);

  List<LogEntry> _logs = [];
  DocumentSnapshot<Map<String, dynamic>>? _cursor;
  bool _hasMore = false;
  bool _loading = false;
  bool _loadingMore = false;
  Object? _error;
  int _scanned = 0;

  List<VolumeBucket>? _volume;
  Map<Severity, int>? _totals;
  Object? _volumeError;

  /// null = automatic: shown unless the window is short.
  bool? _chartPref;
  _View _view = _View.logs;
  String _groupKey = 'service.name';

  /// Live updates are on whenever the time range is relative ("Last hour"),
  /// unless the user pauses them. New logs stream in at the top while older
  /// pages still load on scroll.
  bool _paused = false;
  StreamSubscription<List<LogEntry>>? _tailSub;
  Timer? _chartTimer;
  DateTime? _lastLiveUpdate;
  final Set<String> _ids = {};

  bool get _liveOn => _q.range.isRelative && !_paused;

  LogEntry? _selected;
  final Set<String> _knownServices = {};
  final Set<String> _knownKeys = {};
  final Set<String> _registering = {};

  /// Bumped on every reload so results from older requests are ignored.
  int _generation = 0;

  LogRepository get _repo => ref.read(logRepositoryProvider);
  LogQuery get _q => widget.query;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  void didUpdateWidget(LogsScreen old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query || old.projectId != widget.projectId) {
      if (_search.text != widget.query.search) _search.text = widget.query.search;
      if (old.projectId != widget.projectId) {
        _knownServices.clear();
        _knownKeys.clear();
      }
      _reload();
    }
  }

  @override
  void dispose() {
    _stopTail();
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _setQuery(LogQuery q) {
    final uri = Uri(path: '/p/${widget.projectId}/logs', queryParameters: q.toQueryParameters());
    context.go(uri.toString());
  }

  void _remember(Iterable<LogEntry> logs) {
    final registry = {
      for (final s in ref.read(servicesProvider(widget.projectId)).value ?? const <ServiceInfo>[]) s.name,
    };
    for (final l in logs) {
      _knownServices.add(l.service);
      _addKeys(l.attributes, '');
      // Logs from older SDKs or plain HTTP don't register their service.name;
      // add it to the project's service list so it appears in the switcher.
      if (l.service.isNotEmpty && !registry.contains(l.service) && _registering.add(l.service)) {
        ref.read(projectRepositoryProvider).registerService(widget.projectId, l.service).catchError((_) {});
      }
    }
  }

  /// Records attribute names, including nested ones as dot paths (device.model).
  void _addKeys(Map<String, dynamic> m, String prefix) {
    for (final e in m.entries) {
      final k = prefix.isEmpty ? e.key : '$prefix.${e.key}';
      if (e.value is Map && (e.value as Map).isNotEmpty && prefix.split('.').length < 3) {
        _addKeys((e.value as Map).cast<String, dynamic>(), k);
      } else {
        _knownKeys.add(k);
      }
    }
  }

  /// Auto-save: append newly loaded logs to the project's text files.
  void _save(List<LogEntry> logs) {
    if (logs.isEmpty || !ref.read(autoSaveProvider)) return;
    final store = ref.read(textLogStoreProvider(widget.projectId));
    if (store.canAutoSave) store.append(logs);
  }

  Future<void> _exportText({bool csv = false}) async {
    if (_logs.isEmpty) {
      showMessage(context, 'No logs to save in this view.');
      return;
    }
    final label = _q.services.length == 1 ? _q.services.first : 'logs';
    try {
      final path = await ref.read(textLogStoreProvider(widget.projectId)).export(_logs, label, csv: csv);
      if (!mounted || path == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Saved ${_logs.length} logs to $path'),
          action: SnackBarAction(
            label: 'Copy path',
            onPressed: () => copyToClipboard(context, path, what: 'Path copied'),
          ),
        ),
      );
    } catch (e) {
      if (mounted) showMessage(context, 'Couldn’t save the file: $e', error: true);
    }
  }

  Future<void> _reload() async {
    final gen = ++_generation;
    _stopTail();
    setState(() {
      _loading = true;
      _error = null;
      _logs = [];
      _ids.clear();
      _cursor = null;
      _scanned = 0;
      _selected = null;
    });
    _loadChart(gen);
    try {
      final page = await _repo.fetchPage(widget.projectId, _q);
      if (gen != _generation || !mounted) return;
      _remember(page.logs);
      _save(page.logs);
      setState(() {
        _logs = page.logs;
        _ids.addAll(page.logs.map((l) => l.id));
        _cursor = page.cursor;
        _hasMore = page.hasMore;
        _scanned = page.scanned;
        _loading = false;
      });
      if (_liveOn) _startTail(gen);
    } catch (e) {
      if (gen != _generation || !mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// [quiet] keeps the current chart on screen while it refreshes.
  Future<void> _loadChart(int gen, {bool quiet = false}) async {
    if (!quiet) {
      setState(() {
        _volume = null;
        _totals = null;
        _volumeError = null;
      });
    }
    try {
      final results = await Future.wait([
        _repo.volume(widget.projectId, _q),
        _repo.severityTotals(widget.projectId, _q),
      ]);
      if (gen != _generation || !mounted) return;
      setState(() {
        _volume = results[0] as List<VolumeBucket>;
        _totals = results[1] as Map<Severity, int>;
        _volumeError = null;
      });
    } catch (e) {
      if (gen != _generation || !mounted || quiet) return;
      setState(() => _volumeError = e);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _cursor == null) return;
    final gen = _generation;
    setState(() => _loadingMore = true);
    try {
      final page = await _repo.fetchPage(widget.projectId, _q, after: _cursor);
      if (gen != _generation || !mounted) return;
      final fresh = page.logs.where((l) => !_ids.contains(l.id)).toList();
      _remember(fresh);
      _save(fresh);
      setState(() {
        _logs = [..._logs, ...fresh];
        _ids.addAll(fresh.map((l) => l.id));
        _cursor = page.cursor;
        _hasMore = page.hasMore;
        _scanned += page.scanned;
      });
    } catch (e) {
      if (mounted) showMessage(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _onScroll() {
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) _loadMore();
  }

  /// Listens for logs newer than the newest one shown and adds them on top.
  void _startTail(int gen) {
    _stopTail();
    final since = _logs.isEmpty ? null : _logs.first.timestamp;
    _tailSub = _repo
        .watchLatest(widget.projectId, _q, since: since)
        .listen(
          (logs) {
            if (gen != _generation || !mounted) return;
            final fresh = logs.where((l) => !_ids.contains(l.id)).toList()
              ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
            setState(() => _lastLiveUpdate = DateTime.now());
            if (fresh.isEmpty) return;
            _remember(fresh);
            _save(fresh);
            setState(() {
              _logs = [...fresh, ..._logs];
              _ids.addAll(fresh.map((l) => l.id));
              _error = null;
            });
          },
          onError: (Object e) {
            if (mounted) showMessage(context, 'Live updates stopped: ${friendlyError(e)}', error: true);
          },
        );
    // Keep the chart and level totals current too.
    _chartTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (gen == _generation && mounted) _loadChart(gen, quiet: true);
    });
  }

  void _stopTail() {
    _tailSub?.cancel();
    _tailSub = null;
    _chartTimer?.cancel();
    _chartTimer = null;
  }

  void _toggleLive() {
    if (!_q.range.isRelative) {
      // Live needs a range that moves with time: switch to the last hour.
      _paused = false;
      _setQuery(_q.copyWith(range: const TimeRange.relative(RelativePreset.h1)));
      return;
    }
    setState(() => _paused = !_paused);
    if (_paused) {
      _stopTail();
    } else {
      _reload(); // catch up on anything that arrived while paused
    }
  }

  void _applyFilter(AttrFilter f) {
    if (f.key == 'service' && (f.op == FilterOp.equals || f.op == FilterOp.notEquals)) {
      _addService(f.value, exclude: f.op == FilterOp.notEquals);
      return;
    }
    if (f.key == 'severity' && f.op == FilterOp.equals) {
      final s = Severity.tryParse(f.value);
      if (s != null) return _setQuery(_q.copyWith(severities: {s}));
    }
    if (_q.filters.contains(f)) return;
    _setQuery(_q.copyWith(filters: [..._q.filters, f]));
  }

  void _addService(String service, {required bool exclude}) {
    if (exclude) {
      _setQuery(
        _q.copyWith(
          excludedServices: {..._q.excludedServices, service}.toList(),
          services: _q.services.where((s) => s != service).toList(),
        ),
      );
    } else {
      _setQuery(
        _q.copyWith(
          services: {..._q.services, service}.toList(),
          excludedServices: _q.excludedServices.where((s) => s != service).toList(),
        ),
      );
    }
  }

  Future<void> _openAddFilter() async {
    final choice = await showFilterDialog(
      context,
      knownServices: _knownServices.toList()..sort(),
      knownKeys: _knownKeys.toList()..sort(),
    );
    switch (choice) {
      case ServiceChoice c:
        _addService(c.service, exclude: c.exclude);
      case AttrChoice c:
        _applyFilter(c.filter);
      case null:
        break;
    }
  }

  void _select(LogEntry log) {
    if (isWide(context)) {
      setState(() => _selected = _selected?.id == log.id ? null : log);
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (ctx, controller) => LogDetail(
          log: log,
          scrollController: controller,
          projectId: widget.projectId,
          related: _logs,
          onFilter: (f) {
            Navigator.pop(ctx);
            _applyFilter(f);
          },
          onOpen: (other) {
            Navigator.pop(ctx);
            _select(other);
          },
        ),
      ),
    );
  }

  /// True when some filters run only in the app, so chart counts include
  /// logs the list hides.
  bool get _hasAppOnlyFilters =>
      _q.excludedServices.isNotEmpty ||
      _q.filters.isNotEmpty ||
      _q.searchTokens.length > 1 ||
      _q.services.length > 30 ||
      (_q.services.length > 1 && _q.severities.length > 1);

  @override
  Widget build(BuildContext context) {
    final wide = isWide(context);
    final content = LayoutBuilder(
      builder: (context, c) {
        // Short windows hide the chart automatically (the ⋯ menu can bring it
        // back) so the table keeps most of the height.
        final showChart = _chartPref ?? c.maxHeight >= 760;
        _chartVisible = showChart;
        final header = <Widget>[
          _toolbar(wide),
          _ServiceBar(
            projectId: widget.projectId,
            selected: _q.services.length == 1 ? _q.services.first : null,
            discovered: _knownServices,
            onSelect: (name) =>
                _setQuery(_q.copyWith(services: name == null ? const [] : [name], excludedServices: const [])),
          ),
          _activeFilters(),
          if (showChart) _chartCard(wide),
        ];
        final table = Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: GlassPanel(
            radius: 20,
            child: switch (_view) {
              // Compact rows when the table itself is narrow (small window,
              // detail panel open), while the page keeps its desktop layout.
              _View.logs => LayoutBuilder(builder: (context, c) => _results(wide && c.maxWidth >= 620)),
              _View.patterns => _patterns(),
              _View.groups => _groups(),
            },
          ),
        );
        // Very short windows: the page scrolls and the table keeps a usable
        // height, so events are always reachable.
        if (c.maxHeight < 600) {
          return SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ...header,
                SizedBox(height: math.max(380.0, c.maxHeight - 24), child: table),
              ],
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...header,
            Expanded(child: table),
          ],
        );
      },
    );
    if (!wide || _selected == null) return content;
    return Row(
      children: [
        Expanded(child: content),
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 14, 16, 16),
          child: SizedBox(
            width: (MediaQuery.sizeOf(context).width * 0.42).clamp(340.0, 520.0),
            child: GlassPanel(
              radius: 22,
              strength: 1.3,
              child: LogDetail(
                key: ValueKey(_selected!.id),
                log: _selected!,
                projectId: widget.projectId,
                related: _logs,
                onFilter: _applyFilter,
                onOpen: (other) => setState(() => _selected = other),
                onClose: () => setState(() => _selected = null),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _toolbar(bool wide) {
    final search = SizedBox(
      height: 36,
      child: TextField(
        controller: _search,
        textInputAction: TextInputAction.search,
        onSubmitted: (v) => _setQuery(_q.copyWith(search: v)),
        decoration: InputDecoration(
          hintText: 'Search messages (whole words)…',
          prefixIcon: const Icon(Icons.search_rounded, size: 19),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          suffixIcon: _q.search.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear search',
                  icon: const Icon(Icons.close_rounded, size: 17),
                  onPressed: () {
                    _search.clear();
                    _setQuery(_q.copyWith(search: ''));
                  },
                ),
        ),
      ),
    );
    final updated = _lastLiveUpdate == null ? '' : ' · checked ${DateFormat.Hms().format(_lastLiveUpdate!)}';
    final liveButton = Tooltip(
      message: !_q.range.isRelative
          ? 'Switch to the last hour and show new logs as they arrive'
          : _liveOn
          ? 'New logs appear automatically$updated. Tap to pause.'
          : 'Paused. Tap to resume live updates.',
      child: FilterChip(
        avatar: _LiveDot(active: _liveOn),
        label: Text(_liveOn ? 'Live' : (_q.range.isRelative ? 'Paused' : 'Live')),
        selected: _liveOn,
        showCheckmark: false,
        visualDensity: const VisualDensity(vertical: -1),
        onSelected: (_) => _toggleLive(),
      ),
    );
    final filters = <Widget>[
      TimeRangeButton(
        range: _q.range,
        onChanged: (r) => _setQuery(_q.copyWith(range: r)),
      ),
      SeverityButton(
        selected: _q.severities,
        totals: _totals,
        onChanged: (s) => _setQuery(_q.copyWith(severities: s)),
      ),
      OutlinedButton.icon(
        onPressed: _openAddFilter,
        icon: const Icon(Icons.add_rounded, size: 17),
        label: const Text('Filter'),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      liveButton,
    ];
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh_rounded), onPressed: _reload),
        _moreMenu(),
      ],
    );

    return LayoutBuilder(
      builder: (context, c) {
        // One line when there's room; otherwise search + actions on top and
        // the filters on a single scrollable line below.
        if (c.maxWidth >= 860) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
            child: Row(
              children: [
                Expanded(child: search),
                const SizedBox(width: 10),
                for (final f in filters) ...[f, const SizedBox(width: 8)],
                actions,
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: search),
                  const SizedBox(width: 4),
                  actions,
                ],
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final f in filters) ...[f, const SizedBox(width: 8)],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Logs / Patterns / Group by switch.
  Widget _viewSwitch(bool compact) => SegmentedButton<_View>(
    showSelectedIcon: false,
    style: const ButtonStyle(visualDensity: VisualDensity(horizontal: -2, vertical: -3)),
    segments: [
      ButtonSegment(
        value: _View.logs,
        tooltip: compact ? 'Logs' : null,
        label: compact ? null : const Text('Logs'),
        icon: const Icon(Icons.view_list_rounded, size: 16),
      ),
      ButtonSegment(
        value: _View.patterns,
        tooltip: compact ? 'Patterns' : null,
        label: compact ? null : const Text('Patterns'),
        icon: const Icon(Icons.auto_awesome_motion_outlined, size: 16),
      ),
      ButtonSegment(
        value: _View.groups,
        tooltip: compact ? 'Group by' : null,
        label: compact ? null : const Text('Group by'),
        icon: const Icon(Icons.workspaces_outline, size: 16),
      ),
    ],
    selected: {_view},
    onSelectionChanged: (v) => setState(() => _view = v.first),
  );

  /// "⋯" menu: chart, saved views, export.
  Widget _moreMenu() {
    final currentQuery = Uri(queryParameters: _q.toQueryParameters()).query;
    return AppMenuAnchor<Object>(
      tooltip: 'More',
      searchable: false,
      showChecks: false,
      minWidth: 250,
      maxHeight: 460,
      entries: () {
        final views = ref.read(savedViewsProvider(widget.projectId)).value ?? const <SavedView>[];
        final uid = ref.read(userProvider).value?.uid;
        final isAdmin = ref.read(myRoleProvider(widget.projectId))?.canManageKeys ?? false;
        final chartOn = _chartVisible ?? true;
        return [
          MenuEntry<Object>(
            '_chart',
            chartOn ? 'Hide chart' : 'Show chart',
            icon: chartOn ? Icons.bar_chart_rounded : Icons.bar_chart_outlined,
            section: 'View',
          ),
          const MenuEntry<Object>(
            '_save',
            'Save current view…',
            icon: Icons.bookmark_add_outlined,
            section: 'Saved views',
          ),
          for (final v in views)
            MenuEntry<Object>(
              v,
              v.name,
              icon: v.query == currentQuery ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
              section: 'Saved views',
              action: v.createdBy == uid || isAdmin
                  ? MenuRowAction(Icons.close_rounded, 'Delete view', () {
                      Navigator.of(context).pop();
                      ref.read(insightsRepositoryProvider).deleteView(widget.projectId, v.id).catchError((Object e) {
                        if (mounted) showMessage(context, friendlyError(e), error: true);
                      });
                    })
                  : null,
            ),
          const MenuEntry<Object>('_txt', 'Export as .txt', icon: Icons.description_outlined, section: 'Export'),
          const MenuEntry<Object>('_csv', 'Export as .csv', icon: Icons.table_chart_outlined, section: 'Export'),
        ];
      },
      onSelected: (v) {
        switch (v) {
          case '_chart':
            setState(() => _chartPref = !(_chartVisible ?? true));
          case '_save':
            _saveCurrentView(currentQuery);
          case '_txt':
            _exportText();
          case '_csv':
            _exportText(csv: true);
          case final SavedView view:
            context.go('/p/${widget.projectId}/logs?${view.query}');
        }
      },
      builder: (context, open) => Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: open ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12) : null,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(Icons.more_horiz_rounded, color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }

  /// Chart visibility from the last layout (null before the first one).
  bool? _chartVisible;

  Future<void> _saveCurrentView(String currentQuery) async {
    final name = await promptText(
      context,
      title: 'Save view',
      label: 'Name (e.g. keyo_ios errors)',
      action: 'Save',
      validator: (v) => v.length > 60 ? 'Keep it under 60 characters' : null,
    );
    final user = ref.read(userProvider).value;
    if (name == null || user == null) return;
    try {
      await ref.read(insightsRepositoryProvider).saveView(widget.projectId, user, name, currentQuery);
      if (mounted) showMessage(context, 'View “$name” saved');
    } catch (e) {
      if (mounted) showMessage(context, friendlyError(e), error: true);
    }
  }

  Widget _activeFilters() {
    final chips = <Widget>[
      for (final s in _q.services)
        InputChip(
          label: Text('service.name = $s'),
          onDeleted: () => _setQuery(_q.copyWith(services: _q.services.where((x) => x != s).toList())),
        ),
      for (final s in _q.excludedServices)
        InputChip(
          label: Text('service.name ≠ $s'),
          onDeleted: () => _setQuery(_q.copyWith(excludedServices: _q.excludedServices.where((x) => x != s).toList())),
        ),
      for (final f in _q.filters)
        InputChip(
          label: Text(f.label),
          onDeleted: () => _setQuery(_q.copyWith(filters: _q.filters.where((x) => x != f).toList())),
        ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: LayoutBuilder(
        builder: (context, c) => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _viewSwitch(c.maxWidth < 560),
            const SizedBox(width: 10),
            Expanded(
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ...chips,
                  if (_q.hasFilters)
                    TextButton(onPressed: () => _setQuery(_q.cleared()), child: const Text('Clear all')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chartCard(bool wide) {
    final theme = Theme.of(context);
    final total = _volume?.fold<int>(0, (s, b) => s + b.count);
    Widget body;
    if (_volumeError != null) {
      body = Center(
        child: Text(
          friendlyError(_volumeError!),
          textAlign: TextAlign.center,
          style: TextStyle(color: theme.colorScheme.error),
        ),
      );
    } else if (_volume == null) {
      body = const Center(child: SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2)));
    } else {
      body = VolumeChart(
        buckets: _volume!,
        onZoom: (from, to) {
          _setQuery(_q.copyWith(range: TimeRange.absolute(from, to)));
        },
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: GlassCard(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    total == null ? 'Log volume' : '${NumberFormat.decimalPattern().format(total)} logs',
                    style: theme.textTheme.titleSmall,
                  ),
                  if (_totals != null)
                    for (final s in Severity.values.reversed)
                      if ((_totals![s] ?? 0) > 0)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(color: s.color, shape: BoxShape.circle),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${s.label} ${NumberFormat.compact().format(_totals![s])}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                  if (_hasAppOnlyFilters)
                    Tooltip(
                      message:
                          'Counts include time range, service, level and the first search word. '
                          'Other filters only apply to the list below.',
                      child: Icon(Icons.info_outline, size: 16, color: theme.colorScheme.outline),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(height: wide ? 130 : 100, child: body),
            ],
          ),
        ),
      ),
    );
  }

  Widget _results(bool wide) {
    if (_loading && _logs.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_error != null && _logs.isEmpty) return ErrorView(_error!, onRetry: _reload);
    if (_logs.isEmpty) {
      return EmptyState(
        icon: Icons.inbox_outlined,
        title: _liveOn ? 'Waiting for logs…' : 'No logs match',
        message: _liveOn
            ? 'New logs matching your filters will appear here.'
            : _q.hasFilters
            ? 'Try a wider time range or remove some filters.'
            : 'No logs in this time range. Send some from an app using an ingest key.',
        action: !_q.hasFilters && !_liveOn
            ? OutlinedButton.icon(
                onPressed: () => context.go('/p/${widget.projectId}/keys'),
                icon: const Icon(Icons.key_outlined),
                label: const Text('Set up an ingest key'),
              )
            : null,
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (wide)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
            ),
            child: DefaultTextStyle.merge(
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant),
              child: const Row(
                children: [
                  SizedBox(width: 170, child: Text('TIMESTAMP')),
                  SizedBox(width: 82, child: Text('LEVEL')),
                  SizedBox(width: 150, child: Text('SERVICE.NAME')),
                  Expanded(child: Text('MESSAGE')),
                ],
              ),
            ),
          )
        else
          const Divider(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _reload,
            child: ListView.builder(
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: _logs.length + 1,
              itemBuilder: (context, i) {
                if (i == _logs.length) return _footer();
                final log = _logs[i];
                return _LogRow(log: log, wide: wide, selected: _selected?.id == log.id, onTap: () => _select(log));
              },
            ),
          ),
        ),
      ],
    );
  }

  /// Logs grouped into message patterns (from the logs loaded so far).
  Widget _patterns() {
    if (_loading && _logs.isEmpty) return const Center(child: CircularProgressIndicator());
    final groups = groupPatterns(_logs);
    final theme = Theme.of(context);
    if (groups.isEmpty) {
      return const EmptyState(icon: Icons.auto_awesome_motion_outlined, title: 'No patterns yet');
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: groups.length + 1,
      separatorBuilder: (_, _) => const Divider(),
      itemBuilder: (context, i) {
        if (i == groups.length) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Text(
                  '${groups.length} patterns from ${_logs.length} loaded logs',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                ),
                if (_hasMore) ...[
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: _loadingMore ? null : _loadMore,
                    child: Text(_loadingMore ? 'Loading…' : 'Analyze more logs'),
                  ),
                ],
              ],
            ),
          );
        }
        final g = groups[i];
        final share = g.count / _logs.length;
        return InkWell(
          onTap: () {
            setState(() => _view = _View.logs);
            _applyFilter(AttrFilter('pattern', FilterOp.equals, g.pattern));
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                SizedBox(
                  width: 64,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${g.count}', style: theme.textTheme.titleMedium),
                      Text(
                        '${(share * 100).toStringAsFixed(share < 0.1 ? 1 : 0)}%',
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                      ),
                    ],
                  ),
                ),
                SeverityBadge(g.topSeverity, compact: true),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        g.pattern,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle.copyWith(fontSize: 12.5),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${g.services.join(', ')} · last ${timeAgo(g.lastSeen)}',
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Group-by keys offered in the picker: built-in fields, then attributes seen.
  static const _builtinGroupKeys = ['service.name', 'severity', 'userId', 'sessionId', 'pattern'];

  List<String> get _groupKeys => [..._builtinGroupKeys, ...(_knownKeys.toList()..sort())];

  /// Logs grouped by the values of one field or attribute.
  Widget _groups() {
    if (_loading && _logs.isEmpty) return const Center(child: CircularProgressIndicator());
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final groups = groupByField(_logs, _groupKey);
    final max = groups.fold<int>(1, (m, g) => g.count > m ? g.count : m);
    final keys = {..._groupKeys, _groupKey}.toList();

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('Group by', style: theme.textTheme.titleSmall),
          AppMenuAnchor<String>(
            tooltip: 'Choose a field or attribute',
            selected: {_groupKey},
            searchable: true,
            searchHint: 'Search fields and attributes',
            minWidth: 260,
            maxHeight: 420,
            onCustom: (q) => q,
            customLabel: 'Group by',
            entries: () => [
              for (final k in _builtinGroupKeys) MenuEntry(k, k, mono: true, section: 'Fields'),
              for (final k in keys.where((k) => !_builtinGroupKeys.contains(k)))
                MenuEntry(k, k, mono: true, section: 'Attributes'),
            ],
            onSelected: (k) => setState(() => _groupKey = k),
            builder: (context, open) =>
                MenuPill(icon: Icons.workspaces_outline, label: _groupKey, mono: true, active: true, open: open),
          ),
          Text(
            '${groups.length} values · ${_logs.length} loaded logs',
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline),
          ),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        const Divider(),
        Expanded(
          child: groups.isEmpty
              ? const EmptyState(icon: Icons.workspaces_outline, title: 'No logs to group')
              : ListView.separated(
                  itemCount: groups.length + 1,
                  separatorBuilder: (_, _) => const Divider(),
                  itemBuilder: (context, i) {
                    if (i == groups.length) {
                      return Padding(
                        padding: const EdgeInsets.all(16),
                        child: Center(
                          child: _hasMore
                              ? OutlinedButton(
                                  onPressed: _loadingMore ? null : _loadMore,
                                  child: Text(_loadingMore ? 'Loading…' : 'Include more logs'),
                                )
                              : Text('All matching logs included', style: theme.textTheme.bodySmall),
                        ),
                      );
                    }
                    final g = groups[i];
                    final share = g.count / _logs.length;
                    return InkWell(
                      onTap: () {
                        setState(() => _view = _View.logs);
                        _applyFilter(
                          g.value == null
                              ? AttrFilter(_groupKey, FilterOp.notExists)
                              : AttrFilter(
                                  _groupKey == 'service.name' ? 'service' : _groupKey,
                                  FilterOp.equals,
                                  g.value!,
                                ),
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    g.value ?? '(not set)',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: monoStyle.copyWith(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: g.value == null ? scheme.outline : null,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: LinearProgressIndicator(
                                      value: g.count / max,
                                      minHeight: 5,
                                      backgroundColor: scheme.outlineVariant,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    [
                                      '${(share * 100).toStringAsFixed(share < 0.1 ? 1 : 0)}%',
                                      if (g.errors > 0) '${g.errors} errors',
                                      if (g.users.isNotEmpty && _groupKey != 'userId') '${g.users.length} users',
                                      'last ${timeAgo(g.lastSeen)}',
                                    ].join(' · '),
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: g.errors > 0 ? Severity.error.color : scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 16),
                            Text('${g.count}', style: theme.textTheme.titleMedium),
                            const Icon(Icons.chevron_right),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _footer() {
    final style = TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          if (_loadingMore)
            const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))
          else if (_hasMore)
            OutlinedButton(onPressed: _loadMore, child: const Text('Load more'))
          else
            Text('End of results', style: style),
          const SizedBox(height: 6),
          Text('${_logs.length} shown · $_scanned scanned', style: style),
        ],
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.log, required this.wide, required this.selected, required this.onTap});

  final LogEntry log;
  final bool wide;
  final bool selected;
  final VoidCallback onTap;

  static final _wideFmt = DateFormat('MMM dd HH:mm:ss.SSS');
  static final _narrowFmt = DateFormat('MMM dd HH:mm:ss');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final row = wide
        ? Row(
            children: [
              SizedBox(
                width: 170,
                child: Text(_wideFmt.format(log.timestamp), style: monoStyle.copyWith(fontSize: 12)),
              ),
              SizedBox(
                width: 82,
                child: Align(alignment: Alignment.centerLeft, child: SeverityBadge(log.severity)),
              ),
              SizedBox(
                width: 150,
                child: Text(
                  log.service,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                ),
              ),
              Expanded(
                child: Text(
                  log.message,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: monoStyle.copyWith(fontSize: 12.5),
                ),
              ),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SeverityBadge(log.severity, compact: true),
                  const SizedBox(width: 8),
                  Text(_narrowFmt.format(log.timestamp), style: monoStyle.copyWith(fontSize: 11.5)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      log.service,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                log.message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: monoStyle.copyWith(fontSize: 12.5),
              ),
            ],
          );
    return Material(
      color: selected ? scheme.secondaryContainer.withValues(alpha: 0.6) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: wide ? 7 : 10),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: log.severity.color, width: 3),
              bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
            ),
          ),
          child: row,
        ),
      ),
    );
  }
}

/// Switch between apps/services (service.name), e.g. keyo_ios, keyo_android.
class _ServiceBar extends ConsumerWidget {
  const _ServiceBar({
    required this.projectId,
    required this.selected,
    required this.discovered,
    required this.onSelect,
  });

  final String projectId;
  final String? selected;
  final Set<String> discovered;
  final ValueChanged<String?> onSelect;

  static IconData iconFor(String name) {
    final n = name.toLowerCase();
    if (n.contains('ios') || n.contains('iphone') || n.contains('ipad')) return Icons.phone_iphone;
    if (n.contains('android')) return Icons.android;
    if (n.contains('mac')) return Icons.laptop_mac;
    if (n.contains('windows') || n.contains('win')) return Icons.desktop_windows_outlined;
    if (n.contains('web') || n.contains('site')) return Icons.language;
    if (n.contains('server') || n.contains('backend') || n.contains('api') || n.contains('worker')) {
      return Icons.dns_outlined;
    }
    return Icons.apps;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final registry = ref.watch(servicesProvider(projectId)).value ?? const <ServiceInfo>[];
    final names = {...registry.map((s) => s.name), ...discovered, ?selected}.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    if (names.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    Widget chip(String? name) {
      final isSel = name == selected;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Material(
          color: isSel ? scheme.primary : scheme.surface.withValues(alpha: 0.45),
          shape: StadiumBorder(side: BorderSide(color: isSel ? scheme.primary : scheme.outlineVariant)),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: () => onSelect(isSel ? null : name),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    name == null ? Icons.layers_outlined : iconFor(name),
                    size: 16,
                    color: isSel ? scheme.onPrimary : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    name ?? 'All services',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isSel ? scheme.onPrimary : scheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
        children: [chip(null), for (final n in names) chip(n)],
      ),
    );
  }
}

/// Pulsing red dot while live updates are on.
class _LiveDot extends StatefulWidget {
  const _LiveDot({required this.active});

  final bool active;

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));

  @override
  void initState() {
    super.initState();
    if (widget.active) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_LiveDot old) {
    super.didUpdateWidget(old);
    if (widget.active && !_c.isAnimating) _c.repeat(reverse: true);
    if (!widget.active) _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final off = Theme.of(context).colorScheme.outline;
    if (!widget.active) return Icon(Icons.pause_circle_outline, size: 14, color: off);
    return FadeTransition(
      opacity: Tween(begin: 0.35, end: 1.0).animate(_c),
      child: const Icon(Icons.fiber_manual_record, size: 12, color: Colors.redAccent),
    );
  }
}

/// Saved filter combinations for this project (shared with the team).
enum _View { logs, patterns, groups }
