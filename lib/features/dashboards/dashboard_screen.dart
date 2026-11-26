import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/app_menu.dart';
import '../../core/glass.dart';
import '../../core/severity.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../data/activity.dart';
import '../../data/dashboards.dart';
import '../../data/log_query.dart';
import '../../data/log_repository.dart';
import '../../state/providers.dart';
import '../../state/quick_access.dart';
import '../logs/volume_chart.dart';
import 'dashboards_screen.dart';

const _rangeChoices = [RelativePreset.h1, RelativePreset.h24, RelativePreset.d7, RelativePreset.d30, RelativePreset.d90];

/// One dashboard: a grid of tiles over a shared time range.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key, required this.projectId, required this.dashboardId});

  final String projectId;
  final String dashboardId;

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  /// Bumped by Refresh so every tile reloads.
  int _refresh = 0;
  String? _visitedName;

  String get _path => dashboardPath(widget.projectId, widget.dashboardId);

  DashboardsRepository get _repo => ref.read(dashboardsRepositoryProvider);

  void _remember(Dashboard d) {
    if (_visitedName == d.name) return;
    _visitedName = d.name;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final quick = ref.read(quickAccessProvider(widget.projectId).notifier);
      quick.visit(QuickLink(path: _path, title: d.name, kind: 'Dashboard'));
      quick.rename(_path, d.name);
    });
  }

  Future<void> _editTile(Dashboard d, [DashboardTile? tile]) async {
    final result = await showDialog<DashboardTile>(
      context: context,
      builder: (_) => TileDialog(projectId: widget.projectId, tile: tile),
    );
    if (result == null) return;
    final tiles = [...d.tiles];
    final i = tile == null ? -1 : tiles.indexWhere((t) => t.id == tile.id);
    i < 0 ? tiles.add(result) : tiles[i] = result;
    await _save(() => _repo.update(widget.projectId, d.id, tiles: tiles));
  }

  Future<void> _save(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) showMessage(context, friendlyError(e), error: true);
    }
  }

  Future<void> _move(Dashboard d, DashboardTile t, int delta) async {
    final tiles = [...d.tiles];
    final i = tiles.indexWhere((x) => x.id == t.id);
    final j = i + delta;
    if (i < 0 || j < 0 || j >= tiles.length) return;
    tiles.insert(j, tiles.removeAt(i));
    await _save(() => _repo.update(widget.projectId, d.id, tiles: tiles));
  }

  void _open(DashboardTile t, RelativePreset range) {
    final r = TimeRange.relative(range);
    final uri = t.source == TileSource.logs
        ? Uri(path: '/p/${widget.projectId}/logs', queryParameters: t.logQuery(r).toQueryParameters())
        : Uri(path: '/p/${widget.projectId}/activity', queryParameters: t.activityQuery(r).toQueryParameters());
    context.go(uri.toString());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final async = ref.watch(dashboardProvider((widget.projectId, widget.dashboardId)));
    final quick = ref.watch(quickAccessProvider(widget.projectId));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: ErrorView(e)),
      data: (d) {
        if (d == null) {
          return Center(
            child: EmptyState(
              icon: Icons.space_dashboard_outlined,
              title: 'Dashboard not found',
              message: 'It may have been deleted.',
              action: FilledButton(
                onPressed: () => context.go('/p/${widget.projectId}/dashboards'),
                child: const Text('All dashboards'),
              ),
            ),
          );
        }
        _remember(d);
        final starred = quick.isStarred(_path);
        return RefreshIndicator(
          onRefresh: () async => setState(() => _refresh++),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'All dashboards',
                    onPressed: () => context.go('/p/${widget.projectId}/dashboards'),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  Expanded(
                    child: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.headlineSmall),
                  ),
                  IconButton(
                    tooltip: starred ? 'Unstar' : 'Star',
                    onPressed: () => ref
                        .read(quickAccessProvider(widget.projectId).notifier)
                        .toggleStar(QuickLink(path: _path, title: d.name, kind: 'Dashboard')),
                    icon: Icon(
                      starred ? Icons.star_rounded : Icons.star_outline_rounded,
                      color: starred ? const Color(0xFFF5B301) : null,
                    ),
                  ),
                  AppMenuAnchor<String>(
                    tooltip: 'Dashboard options',
                    searchable: false,
                    minWidth: 190,
                    entries: () => [
                      const MenuEntry('rename', 'Rename', icon: Icons.edit_outlined),
                      const MenuEntry('describe', 'Edit description', icon: Icons.notes_rounded),
                    ],
                    onSelected: (v) async {
                      final value = await promptText(
                        context,
                        title: v == 'rename' ? 'Rename dashboard' : 'Description',
                        label: v == 'rename' ? 'Name' : 'Description',
                        initial: v == 'rename' ? d.name : d.description,
                        validator: v == 'rename'
                            ? (s) => s.trim().isEmpty ? 'Enter a name' : (s.trim().length > 80 ? 'Too long' : null)
                            : (s) => s.length > 500 ? 'Too long' : null,
                      );
                      if (value == null) return;
                      await _save(
                        () => v == 'rename'
                            ? _repo.update(widget.projectId, d.id, name: value)
                            : _repo.update(widget.projectId, d.id, description: value),
                      );
                    },
                    builder: (context, open) =>
                        const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.more_vert_rounded)),
                  ),
                ],
              ),
              if (d.description.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                  child: Text(
                    d.description,
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SegmentedButton<RelativePreset>(
                    showSelectedIcon: false,
                    style: const ButtonStyle(visualDensity: VisualDensity.compact),
                    segments: [for (final r in _rangeChoices) ButtonSegment(value: r, label: Text(r.id))],
                    selected: {_rangeChoices.contains(d.range) ? d.range : RelativePreset.h24},
                    onSelectionChanged: (s) => _save(() => _repo.update(widget.projectId, d.id, range: s.first)),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    onPressed: () => setState(() => _refresh++),
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: d.tiles.length >= Dashboard.maxTiles ? null : () => _editTile(d),
                    icon: const Icon(Icons.add_chart_rounded),
                    label: const Text('Add tile'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (d.tiles.isEmpty)
                GlassCard(
                  child: EmptyState(
                    icon: Icons.add_chart_rounded,
                    title: 'No tiles yet',
                    message: 'Add a number (e.g. errors today) or a chart (e.g. log volume of keyo_ios).',
                    action: FilledButton.icon(
                      onPressed: () => _editTile(d),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Add tile'),
                    ),
                  ),
                )
              else
                LayoutBuilder(
                  builder: (context, c) {
                    const gap = 12.0;
                    final cols = c.maxWidth >= 1100 ? 4 : (c.maxWidth >= 640 ? 2 : 1);
                    final unit = (c.maxWidth - gap * (cols - 1)) / cols;
                    // Numbers take one column (two side by side on phones),
                    // charts two columns (the full width on phones).
                    double widthOf(DashboardTile t) => t.viz == TileViz.number
                        ? (cols == 1 ? (c.maxWidth - gap) / 2 : unit)
                        : (cols == 1 ? c.maxWidth : unit * 2 + gap);
                    return Wrap(
                      spacing: gap,
                      runSpacing: gap,
                      children: [
                        for (var i = 0; i < d.tiles.length; i++)
                          SizedBox(
                            width: widthOf(d.tiles[i]),
                            child: _TileCard(
                              key: ValueKey('${d.tiles[i].id}-${d.range.id}-$_refresh-${d.tiles[i].query}'),
                              projectId: widget.projectId,
                              tile: d.tiles[i],
                              range: TimeRange.relative(d.range),
                              onOpen: () => _open(d.tiles[i], d.range),
                              onEdit: () => _editTile(d, d.tiles[i]),
                              onMove: (delta) => _move(d, d.tiles[i], delta),
                              canMoveUp: i > 0,
                              canMoveDown: i < d.tiles.length - 1,
                              onRemove: () => _save(
                                () => _repo.update(
                                  widget.projectId,
                                  d.id,
                                  tiles: d.tiles.where((t) => t.id != d.tiles[i].id).toList(),
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Result of loading one tile.
class _TileData {
  const _TileData({this.count, this.atLeast = false, this.buckets});
  final int? count;

  /// The count stopped at the scan limit ("1,000+").
  final bool atLeast;
  final List<VolumeBucket>? buckets;
}

class _TileCard extends ConsumerStatefulWidget {
  const _TileCard({
    super.key,
    required this.projectId,
    required this.tile,
    required this.range,
    required this.onOpen,
    required this.onEdit,
    required this.onMove,
    required this.onRemove,
    required this.canMoveUp,
    required this.canMoveDown,
  });

  final String projectId;
  final DashboardTile tile;
  final TimeRange range;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final ValueChanged<int> onMove;
  final VoidCallback onRemove;
  final bool canMoveUp;
  final bool canMoveDown;

  @override
  ConsumerState<_TileCard> createState() => _TileCardState();
}

class _TileCardState extends ConsumerState<_TileCard> {
  late final Future<_TileData> _future = _load();

  Future<_TileData> _load() async {
    final t = widget.tile;
    final pid = widget.projectId;
    if (t.source == TileSource.logs) {
      final repo = ref.read(logRepositoryProvider);
      final q = t.logQuery(widget.range);
      if (t.viz == TileViz.bars) return _TileData(buckets: await repo.volume(pid, q, maxBuckets: 30));
      // Filters Firestore can't run (attributes, extra search words) need the
      // logs themselves; otherwise a count query is enough.
      final appOnly = q.filters.isNotEmpty || q.searchTokens.length > 1 || q.excludedServices.isNotEmpty;
      if (!appOnly) return _TileData(count: await repo.count(pid, q));
      final page = await repo.fetchPage(pid, q, want: 5000, maxScan: 5000, pageSize: 500);
      return _TileData(count: page.logs.length, atLeast: page.hasMore);
    }
    final repo = ref.read(activityRepositoryProvider);
    final q = t.activityQuery(widget.range);
    if (t.viz == TileViz.bars) return _TileData(buckets: await repo.volume(pid, q, maxBuckets: 30));
    return _TileData(count: await repo.count(pid, q));
  }

  String get _subtitle {
    final t = widget.tile;
    final parts = <String>[t.source.label];
    if (t.source == TileSource.logs) {
      final q = t.logQuery(widget.range);
      if (q.services.isNotEmpty) parts.add(q.services.join(', '));
      if (q.severities.isNotEmpty) parts.add(Severity.values.where(q.severities.contains).map((s) => s.id).join('/'));
      if (q.search.trim().isNotEmpty) parts.add('“${q.search.trim()}”');
      if (q.filters.isNotEmpty) parts.add('${q.filters.length} filter${q.filters.length == 1 ? '' : 's'}');
    } else {
      final q = t.activityQuery(widget.range);
      if (q.events.isNotEmpty) parts.add(q.events.join(', '));
      if (q.services.isNotEmpty) parts.add(q.services.join(', '));
      if (q.filters.isNotEmpty) parts.add('${q.filters.length} filter${q.filters.length == 1 ? '' : 's'}');
    }
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = widget.tile;
    final isNumber = t.viz == TileViz.number;
    return GlassCard(
      child: InkWell(
        onTap: widget.onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 4, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.title.isEmpty ? 'Untitled' : t.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          _subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  AppMenuAnchor<String>(
                    tooltip: 'Tile options',
                    searchable: false,
                    minWidth: 180,
                    entries: () => [
                      MenuEntry('open', 'Open in ${t.source.label}', icon: Icons.open_in_new_rounded),
                      const MenuEntry('edit', 'Edit', icon: Icons.edit_outlined),
                      if (widget.canMoveUp) const MenuEntry('up', 'Move earlier', icon: Icons.arrow_upward_rounded),
                      if (widget.canMoveDown)
                        const MenuEntry('down', 'Move later', icon: Icons.arrow_downward_rounded),
                      const MenuEntry('remove', 'Remove', icon: Icons.delete_outline, destructive: true),
                    ],
                    onSelected: (v) {
                      switch (v) {
                        case 'open':
                          widget.onOpen();
                        case 'edit':
                          widget.onEdit();
                        case 'up':
                          widget.onMove(-1);
                        case 'down':
                          widget.onMove(1);
                        default:
                          widget.onRemove();
                      }
                    },
                    builder: (context, open) =>
                        const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.more_horiz_rounded, size: 20)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: isNumber ? 52 : 170,
                child: FutureBuilder<_TileData>(
                  future: _future,
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          friendlyError(snap.error!),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: scheme.error, fontSize: 12),
                        ),
                      );
                    }
                    if (!snap.hasData) {
                      return const Center(
                        child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
                      );
                    }
                    final data = snap.data!;
                    if (isNumber) {
                      final n = data.count ?? 0;
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            '${NumberFormat.decimalPattern().format(n)}${data.atLeast ? '+' : ''}',
                            style: theme.textTheme.displaySmall?.copyWith(
                              fontWeight: FontWeight.w800,
                              letterSpacing: -1,
                              color: _numberColor(t, scheme),
                            ),
                          ),
                        ),
                      );
                    }
                    final b = data.buckets ?? const <VolumeBucket>[];
                    if (b.every((x) => x.count == 0)) {
                      return Center(child: Text('Nothing in this range', style: TextStyle(color: scheme.outline)));
                    }
                    return Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: VolumeChart(buckets: b, onZoom: (_, _) => widget.onOpen()),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color? _numberColor(DashboardTile t, ColorScheme scheme) {
    if (t.source != TileSource.logs) return null;
    final sev = t.logQuery(widget.range).severities;
    if (sev.isNotEmpty && sev.every((s) => s.index >= Severity.error.index)) return Severity.error.color;
    return null;
  }
}

/// Create or edit a tile.
class TileDialog extends ConsumerStatefulWidget {
  const TileDialog({super.key, required this.projectId, this.tile});

  final String projectId;
  final DashboardTile? tile;

  @override
  ConsumerState<TileDialog> createState() => _TileDialogState();
}

class _TileDialogState extends ConsumerState<TileDialog> {
  late final _title = TextEditingController(text: widget.tile?.title ?? '');
  late TileSource _source = widget.tile?.source ?? TileSource.logs;
  late TileViz _viz = widget.tile?.viz ?? TileViz.number;
  late final _search = TextEditingController(
    text: widget.tile == null || _source != TileSource.logs ? '' : widget.tile!.logQuery(_any).search,
  );
  late String? _service = _initialService();
  late Set<Severity> _severities =
      widget.tile != null && _source == TileSource.logs ? widget.tile!.logQuery(_any).severities : {};
  late String? _event = widget.tile != null && _source == TileSource.events
      ? widget.tile!.activityQuery(_any).events.firstOrNull
      : null;

  /// Filters set elsewhere (e.g. via "Add to dashboard") that this dialog
  /// doesn't edit but keeps.
  late final List<AttrFilter> _keptFilters = widget.tile == null
      ? const []
      : (_source == TileSource.logs
            ? widget.tile!.logQuery(_any).filters
            : widget.tile!.activityQuery(_any).filters);

  static const _any = TimeRange.relative(RelativePreset.h24);

  String? _initialService() {
    final t = widget.tile;
    if (t == null) return null;
    final s = t.source == TileSource.logs ? t.logQuery(_any).services : t.activityQuery(_any).services;
    return s.firstOrNull;
  }

  @override
  void dispose() {
    _title.dispose();
    _search.dispose();
    super.dispose();
  }

  String _autoTitle() {
    if (_source == TileSource.events) return _event == null ? 'All events' : _event!;
    final sev = _severities.isEmpty ? 'Logs' : Severity.values.where(_severities.contains).map((s) => s.label).join(' + ');
    final scope = _service == null ? '' : ' · $_service';
    return _viz == TileViz.bars ? '$sev volume$scope' : '$sev$scope';
  }

  void _submit() {
    final String query;
    if (_source == TileSource.logs) {
      query = DashboardTile.queryWithoutRange(
        LogQuery(
          services: _service == null ? const [] : [_service!],
          severities: _severities,
          search: _search.text.trim(),
          filters: _keptFilters,
        ).toQueryParameters(),
      );
    } else {
      query = DashboardTile.queryWithoutRange(
        ActivityQuery(
          events: _event == null ? const [] : [_event!],
          services: _service == null ? const [] : [_service!],
          filters: _keptFilters,
        ).toQueryParameters(),
      );
    }
    Navigator.pop(
      context,
      DashboardTile(
        id: widget.tile?.id ?? DashboardTile.newId(),
        title: _title.text.trim().isEmpty ? _autoTitle() : _title.text.trim(),
        source: _source,
        viz: _viz,
        query: query,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final services = ref.watch(servicesProvider(widget.projectId)).value ?? const [];
    final events = ref.watch(eventDefinitionsProvider(widget.projectId)).value ?? const <EventDefinition>[];
    final form = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _title,
          decoration: InputDecoration(labelText: 'Title', hintText: _autoTitle()),
        ),
        const SizedBox(height: 14),
        Text('Data', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        SegmentedButton<TileSource>(
          showSelectedIcon: false,
          segments: [
            for (final s in TileSource.values)
              ButtonSegment(
                value: s,
                label: Text(s.label),
                icon: Icon(s == TileSource.logs ? Icons.receipt_long_outlined : Icons.bolt_outlined),
              ),
          ],
          selected: {_source},
          onSelectionChanged: (s) => setState(() => _source = s.first),
        ),
        const SizedBox(height: 14),
        Text('Show as', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        SegmentedButton<TileViz>(
          showSelectedIcon: false,
          segments: [
            for (final v in TileViz.values)
              ButtonSegment(
                value: v,
                label: Text(v.label),
                icon: Icon(v == TileViz.number ? Icons.numbers_rounded : Icons.bar_chart_rounded),
              ),
          ],
          selected: {_viz},
          onSelectionChanged: (s) => setState(() => _viz = s.first),
        ),
        const SizedBox(height: 14),
        AppSelectField<String>(
          label: 'Service',
          value: _service ?? '',
          searchable: true,
          entries: [
            const MenuEntry('', 'All services'),
            for (final s in services) MenuEntry(s.name, s.name, mono: true),
          ],
          onChanged: (v) => setState(() => _service = v.isEmpty ? null : v),
        ),
        const SizedBox(height: 14),
        if (_source == TileSource.logs) ...[
          Text('Levels', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final s in Severity.values)
                FilterChip(
                  label: Text(s.label),
                  selected: _severities.contains(s),
                  avatar: CircleAvatar(backgroundColor: s.color, radius: 5),
                  onSelected: (on) => setState(() => _severities = on ? {..._severities, s} : ({..._severities}..remove(s))),
                ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _search,
            decoration: const InputDecoration(labelText: 'Search words (optional)', hintText: 'payment failed'),
          ),
        ] else
          AppSelectField<String>(
            label: 'Event',
            value: _event ?? '',
            searchable: true,
            entries: [
              const MenuEntry('', 'All events'),
              for (final e in events) MenuEntry(e.name, e.name, mono: true),
            ],
            onChanged: (v) => setState(() => _event = v.isEmpty ? null : v),
          ),
        if (_keptFilters.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            'Also keeps ${_keptFilters.length} filter${_keptFilters.length == 1 ? '' : 's'}: '
            '${_keptFilters.map((f) => f.label).join(', ')}',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ],
    );
    final title = Text(widget.tile == null ? 'Add tile' : 'Edit tile');
    if (isMobileLayout(context)) {
      return Dialog.fullscreen(
        child: Scaffold(
          backgroundColor: Theme.of(context).colorScheme.surface,
          appBar: AppBar(
            title: title,
            leading: IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded)),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: FilledButton(onPressed: _submit, child: Text(widget.tile == null ? 'Add' : 'Save')),
              ),
            ],
          ),
          body: SafeArea(child: ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 24), children: [form])),
        ),
      );
    }
    return AlertDialog(
      title: title,
      content: SizedBox(width: 460, child: SingleChildScrollView(child: form)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: Text(widget.tile == null ? 'Add tile' : 'Save')),
      ],
    );
  }
}
