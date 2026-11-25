import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../data/activity.dart';
import '../../data/log_query.dart';
import '../../data/log_repository.dart';
import '../../state/providers.dart';
import '../logs/filter_controls.dart';
import '../logs/volume_chart.dart';

String activityUri(String pid, ActivityQuery q) =>
    Uri(path: '/p/$pid/activity', queryParameters: q.toQueryParameters()).toString();

/// The Activity explorer: every product event, live, with filters.
class ActivityScreen extends ConsumerStatefulWidget {
  const ActivityScreen({super.key, required this.projectId, required this.query});

  final String projectId;
  final ActivityQuery query;

  @override
  ConsumerState<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends ConsumerState<ActivityScreen> {
  final _scroll = ScrollController();
  List<ActivityEvent> _events = [];
  final Set<String> _ids = {};
  DocumentSnapshot<Map<String, dynamic>>? _cursor;
  bool _hasMore = false;
  bool _loading = false;
  bool _loadingMore = false;
  Object? _error;
  int _scanned = 0;
  List<VolumeBucket>? _volume;
  int? _total;
  bool _paused = false;
  StreamSubscription<List<ActivityEvent>>? _tail;
  Timer? _chartTimer;
  ActivityEvent? _selected;
  final Set<String> _knownProps = {};
  final Set<String> _registered = {};
  int _gen = 0;

  ActivityQuery get _q => widget.query;
  bool get _liveOn => _q.range.isRelative && !_paused;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) _loadMore();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  void didUpdateWidget(ActivityScreen old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query || old.projectId != widget.projectId) _reload();
  }

  @override
  void dispose() {
    _stopTail();
    _scroll.dispose();
    super.dispose();
  }

  void _setQuery(ActivityQuery q) => context.go(activityUri(widget.projectId, q));

  void _remember(Iterable<ActivityEvent> events) {
    final defs = {for (final d in ref.read(eventDefinitionsProvider(widget.projectId)).value ?? const []) d.name};
    for (final e in events) {
      _knownProps.addAll(e.properties.keys);
      // Events sent without the SDK (plain HTTP) don't register their name.
      if (!defs.contains(e.event) && _registered.add(e.event)) {
        ref
            .read(activityRepositoryProvider)
            .registerDefinition(widget.projectId, e.event, e.properties.keys)
            .catchError((_) {});
      }
    }
  }

  Future<void> _reload() async {
    final gen = ++_gen;
    _stopTail();
    setState(() {
      _loading = true;
      _error = null;
      _events = [];
      _ids.clear();
      _cursor = null;
      _selected = null;
      _scanned = 0;
    });
    _loadChart(gen);
    try {
      final page = await ref.read(activityRepositoryProvider).fetchPage(widget.projectId, _q);
      if (gen != _gen || !mounted) return;
      _remember(page.events);
      setState(() {
        _events = page.events;
        _ids.addAll(page.events.map((e) => e.id));
        _cursor = page.cursor;
        _hasMore = page.hasMore;
        _scanned = page.scanned;
        _loading = false;
      });
      if (_liveOn) _startTail(gen);
    } catch (e) {
      if (gen != _gen || !mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _loadChart(int gen, {bool quiet = false}) async {
    if (!quiet) setState(() => _volume = null);
    try {
      final repo = ref.read(activityRepositoryProvider);
      final r = await Future.wait([repo.volume(widget.projectId, _q), repo.count(widget.projectId, _q)]);
      if (gen != _gen || !mounted) return;
      setState(() {
        _volume = r[0] as List<VolumeBucket>;
        _total = r[1] as int;
      });
    } catch (_) {
      if (gen == _gen && mounted && !quiet) setState(() => _volume = const []);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _cursor == null) return;
    final gen = _gen;
    setState(() => _loadingMore = true);
    try {
      final page = await ref.read(activityRepositoryProvider).fetchPage(widget.projectId, _q, after: _cursor);
      if (gen != _gen || !mounted) return;
      final fresh = page.events.where((e) => !_ids.contains(e.id)).toList();
      _remember(fresh);
      setState(() {
        _events = [..._events, ...fresh];
        _ids.addAll(fresh.map((e) => e.id));
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

  void _startTail(int gen) {
    _stopTail();
    final since = _events.isEmpty ? null : _events.first.timestamp;
    _tail = ref
        .read(activityRepositoryProvider)
        .watchSince(widget.projectId, _q, since: since)
        .listen(
          (events) {
            if (gen != _gen || !mounted) return;
            final fresh = events.where((e) => !_ids.contains(e.id)).toList()
              ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
            if (fresh.isEmpty) return;
            _remember(fresh);
            setState(() {
              _events = [...fresh, ..._events];
              _ids.addAll(fresh.map((e) => e.id));
              _total = (_total ?? 0) + fresh.length;
            });
          },
          onError: (Object e) {
            if (mounted) showMessage(context, 'Live updates stopped: ${friendlyError(e)}', error: true);
          },
        );
    _chartTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (gen == _gen && mounted) _loadChart(gen, quiet: true);
    });
  }

  void _stopTail() {
    _tail?.cancel();
    _tail = null;
    _chartTimer?.cancel();
    _chartTimer = null;
  }

  void _toggleLive() {
    if (!_q.range.isRelative) {
      _paused = false;
      _setQuery(_q.copyWith(range: const TimeRange.relative(RelativePreset.h1)));
      return;
    }
    setState(() => _paused = !_paused);
    _paused ? _stopTail() : _reload();
  }

  void _select(ActivityEvent e) {
    if (isWide(context)) {
      setState(() => _selected = _selected?.id == e.id ? null : e);
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
        builder: (ctx, controller) => EventDetail(
          projectId: widget.projectId,
          event: e,
          scrollController: controller,
          onFilter: (q) {
            Navigator.pop(ctx);
            _setQuery(q(_q));
          },
        ),
      ),
    );
  }

  Future<void> _pickEvents() async {
    final defs = ref.read(eventDefinitionsProvider(widget.projectId)).value ?? const <EventDefinition>[];
    final names = {...defs.map((d) => d.name), ..._q.events}.toList()..sort();
    final picked = await showDialog<List<String>>(
      context: context,
      builder: (_) => _EventPicker(all: names, selected: _q.events.toSet()),
    );
    if (picked != null) _setQuery(_q.copyWith(events: picked));
  }

  Future<void> _addFilter() async {
    final choice = await showFilterDialog(
      context,
      knownServices: ref.read(servicesProvider(widget.projectId)).value?.map((s) => s.name).toList() ?? const [],
      knownKeys: (_knownProps.toList()..sort()),
    );
    switch (choice) {
      case ServiceChoice c when !c.exclude:
        _setQuery(_q.copyWith(services: [c.service]));
      case ServiceChoice c:
        _setQuery(_q.copyWith(filters: [..._q.filters, AttrFilter('service', FilterOp.notEquals, c.service)]));
      case AttrChoice c:
        _setQuery(_q.copyWith(filters: [..._q.filters, c.filter]));
      case null:
        break;
    }
  }

  Future<void> _editColumns() async {
    final current = ref.read(activityColumnsProvider);
    final picked = await showDialog<List<String>>(
      context: context,
      builder: (_) => _EventPicker(
        all: {..._knownProps, ...current}.toList()..sort(),
        selected: current.toSet(),
        title: 'Property columns',
        allowCustom: true,
      ),
    );
    if (picked != null) ref.read(activityColumnsProvider.notifier).set(picked.take(6).toList());
  }

  @override
  Widget build(BuildContext context) {
    final wide = isWide(context);
    final columns = ref.watch(activityColumnsProvider);
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(),
        _activeFilters(),
        _chart(wide),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: GlassPanel(
              radius: 20,
              child: LayoutBuilder(builder: (context, c) => _table(columns, c.maxWidth >= 720)),
            ),
          ),
        ),
      ],
    );
    if (!wide || _selected == null) return content;
    return Row(
      children: [
        Expanded(child: content),
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 14, 16, 16),
          child: SizedBox(
            width: (MediaQuery.sizeOf(context).width * 0.4).clamp(300.0, 440.0),
            child: GlassPanel(
              radius: 22,
              strength: 1.3,
              child: EventDetail(
                key: ValueKey(_selected!.id),
                projectId: widget.projectId,
                event: _selected!,
                onClose: () => setState(() => _selected = null),
                onFilter: (q) => _setQuery(q(_q)),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _toolbar() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('Activity', style: theme.textTheme.headlineSmall),
          const SizedBox(width: 8),
          TimeRangeButton(
            range: _q.range,
            onChanged: (r) => _setQuery(_q.copyWith(range: r)),
          ),
          OutlinedButton.icon(
            onPressed: _pickEvents,
            icon: const Icon(Icons.bolt, size: 18),
            label: Text(
              _q.events.isEmpty ? 'All events' : '${_q.events.length} event${_q.events.length == 1 ? '' : 's'}',
            ),
          ),
          OutlinedButton.icon(
            onPressed: _addFilter,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Filter'),
          ),
          FilterChip(
            avatar: Icon(
              _liveOn ? Icons.fiber_manual_record : Icons.pause_circle_outline,
              size: 13,
              color: _liveOn ? Colors.redAccent : theme.colorScheme.outline,
            ),
            label: Text(_liveOn ? 'Live' : (_q.range.isRelative ? 'Paused' : 'Live')),
            selected: _liveOn,
            showCheckmark: false,
            tooltip: _liveOn ? 'New events appear automatically. Tap to pause.' : 'Tap for live updates',
            onSelected: (_) => _toggleLive(),
          ),
          IconButton(tooltip: 'Columns', onPressed: _editColumns, icon: const Icon(Icons.view_column_outlined)),
          IconButton(tooltip: 'Refresh', onPressed: _reload, icon: const Icon(Icons.refresh)),
        ],
      ),
    );
  }

  Widget _activeFilters() {
    final people = ref.watch(peopleProvider(widget.projectId)).value ?? const <Person>[];
    String personLabel(String id) => people.where((p) => p.id == id).map((p) => p.displayName).firstOrNull ?? id;
    final chips = <Widget>[
      for (final e in _q.events)
        InputChip(
          label: Text('event = $e'),
          onDeleted: () => _setQuery(_q.copyWith(events: _q.events.where((x) => x != e).toList())),
        ),
      if (_q.distinctIds.isNotEmpty)
        InputChip(
          avatar: const Icon(Icons.person_outline, size: 16),
          label: Text('person = ${personLabel(_q.distinctIds.first)}'),
          onDeleted: () => _setQuery(_q.copyWith(distinctIds: const [])),
        ),
      if (_q.sessionId != null)
        InputChip(
          label: Text('session = ${_q.sessionId}'),
          onDeleted: () => _setQuery(_q.copyWith(clearSession: true)),
        ),
      for (final s in _q.services)
        InputChip(
          label: Text('service.name = $s'),
          onDeleted: () => _setQuery(_q.copyWith(services: _q.services.where((x) => x != s).toList())),
        ),
      for (final f in _q.filters)
        InputChip(
          label: Text(f.label),
          onDeleted: () => _setQuery(_q.copyWith(filters: _q.filters.where((x) => x != f).toList())),
        ),
    ];
    if (chips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ...chips,
          TextButton(
            onPressed: () => _setQuery(ActivityQuery(range: _q.range)),
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
  }

  Widget _chart(bool wide) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: GlassCard(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _total == null ? 'Events' : '${NumberFormat.decimalPattern().format(_total)} events',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: wide ? 110 : 90,
                child: _volume == null
                    ? const Center(
                        child: SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : VolumeChart(
                        buckets: _volume!,
                        onZoom: (from, to) => _setQuery(_q.copyWith(range: TimeRange.absolute(from, to))),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _table(List<String> columns, bool roomy) {
    if (_loading && _events.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_error != null && _events.isEmpty) return ErrorView(_error!, onRetry: _reload);
    if (_events.isEmpty) {
      return EmptyState(
        icon: Icons.bolt_outlined,
        title: _liveOn ? 'Waiting for events…' : 'No events match',
        message: _q.hasFilters
            ? 'Try a wider time range or remove some filters.'
            : 'Send events with appTrack.capture(), screen() and identify(). See Ingest keys for setup.',
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final people = {for (final p in ref.watch(peopleProvider(widget.projectId)).value ?? const <Person>[]) p.id: p};
    final shownColumns = roomy ? columns : const <String>[];
    final header = DefaultTextStyle.merge(
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant),
      child: Row(
        children: [
          const SizedBox(width: 120, child: Text('TIME')),
          const Expanded(flex: 3, child: Text('EVENT')),
          const Expanded(flex: 3, child: Text('PERSON')),
          if (roomy) const Expanded(flex: 2, child: Text('APP')),
          for (final c in shownColumns)
            Expanded(flex: 2, child: Text(c.toUpperCase(), overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
          ),
          child: header,
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _reload,
            child: ListView.builder(
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: _events.length + 1,
              itemBuilder: (context, i) {
                if (i == _events.length) return _footer();
                final e = _events[i];
                final person = people[e.distinctId];
                return Material(
                  color: _selected?.id == e.id ? scheme.secondaryContainer.withValues(alpha: 0.6) : Colors.transparent,
                  child: InkWell(
                    onTap: () => _select(e),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6))),
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 120,
                            child: Tooltip(
                              message: DateFormat('yyyy-MM-dd HH:mm:ss.SSS').format(e.timestamp),
                              child: Text(
                                DateFormat('MMM dd HH:mm:ss').format(e.timestamp),
                                style: monoStyle.copyWith(fontSize: 12),
                              ),
                            ),
                          ),
                          Expanded(flex: 3, child: _EventName(event: e)),
                          Expanded(
                            flex: 3,
                            child: Text(
                              person?.displayName ?? e.distinctId,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: e.distinctId.startsWith('anon_') && person?.properties.isEmpty != false
                                    ? scheme.onSurfaceVariant
                                    : scheme.onSurface,
                              ),
                            ),
                          ),
                          if (roomy)
                            Expanded(
                              flex: 2,
                              child: Text(
                                e.service ?? '',
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                              ),
                            ),
                          for (final c in shownColumns)
                            Expanded(
                              flex: 2,
                              child: Text(
                                _cell(e.field(c)),
                                overflow: TextOverflow.ellipsis,
                                style: monoStyle.copyWith(fontSize: 12),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  static String _cell(Object? v) {
    if (v == null) return '—';
    if (v is Map || v is List) return jsonEncode(v, toEncodable: (o) => '$o');
    return '$v';
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
          Text('${_events.length} shown · $_scanned scanned', style: style),
        ],
      ),
    );
  }
}

class _EventName extends StatelessWidget {
  const _EventName({required this.event});

  final ActivityEvent event;

  static IconData iconFor(String name) => switch (name) {
    r'$screen' || r'$pageview' => Icons.visibility_outlined,
    r'$identify' => Icons.badge_outlined,
    _ => Icons.bolt_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final builtIn = event.event.startsWith(r'$');
    return Row(
      children: [
        Icon(iconFor(event.event), size: 16, color: builtIn ? scheme.onSurfaceVariant : scheme.primary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            event.label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 13,
              color: builtIn ? scheme.onSurface : scheme.primary,
            ),
          ),
        ),
      ],
    );
  }
}

/// Everything about one event, with links to the person, session and logs.
class EventDetail extends ConsumerWidget {
  const EventDetail({
    super.key,
    required this.projectId,
    required this.event,
    required this.onFilter,
    this.onClose,
    this.scrollController,
  });

  final String projectId;
  final ActivityEvent event;

  /// Receives a function that adds a filter to the current query.
  final void Function(ActivityQuery Function(ActivityQuery) apply) onFilter;
  final VoidCallback? onClose;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final person = ref.watch(peopleProvider(projectId)).value?.where((p) => p.id == event.distinctId).firstOrNull;
    final fmt = DateFormat('yyyy-MM-dd HH:mm:ss.SSS');
    final props = event.properties.entries.toList()..sort((a, b) => a.key.compareTo(b.key));

    Widget row(String label, String value, {VoidCallback? onTap, IconData? action}) => Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(label, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
          Expanded(child: SelectableText(value, style: monoStyle.copyWith(fontSize: 12.5))),
          if (onTap != null)
            IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              icon: Icon(action ?? Icons.filter_alt_outlined),
              onPressed: onTap,
            ),
        ],
      ),
    );

    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Row(
          children: [
            Expanded(child: _EventName(event: event)),
            IconButton(
              tooltip: 'Copy as JSON',
              icon: const Icon(Icons.data_object, size: 20),
              onPressed: () => copyToClipboard(
                context,
                const JsonEncoder.withIndent('  ').convert({
                  'event': event.event,
                  'distinctId': event.distinctId,
                  'timestamp': event.timestamp.toUtc().toIso8601String(),
                  'sessionId': event.sessionId,
                  'service': event.service,
                  'properties': event.properties,
                }),
                what: 'Event JSON copied',
              ),
            ),
            if (onClose != null)
              IconButton(tooltip: 'Close', icon: const Icon(Icons.close, size: 20), onPressed: onClose),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: () =>
                  context.go('/p/$projectId/people/${Uri.encodeComponent(person?.id ?? event.distinctId)}'),
              icon: const Icon(Icons.person_outline, size: 18),
              label: Text(person?.displayName ?? 'View person', overflow: TextOverflow.ellipsis),
            ),
            OutlinedButton.icon(
              onPressed: () {
                final q = LogQuery(
                  range: TimeRange.absolute(
                    event.timestamp.subtract(const Duration(minutes: 5)),
                    event.timestamp.add(const Duration(minutes: 5)),
                  ),
                  filters: [AttrFilter('userId', FilterOp.equals, person?.id ?? event.distinctId)],
                );
                context.go(Uri(path: '/p/$projectId/logs', queryParameters: q.toQueryParameters()).toString());
              },
              icon: const Icon(Icons.receipt_long_outlined, size: 18),
              label: const Text('Logs ±5 min'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        const SectionLabel('Event'),
        row('Event', event.event, onTap: () => onFilter((q) => q.copyWith(events: [event.event]))),
        row('Time', fmt.format(event.timestamp)),
        if (event.receivedAt != null) row('Received', fmt.format(event.receivedAt!)),
        row(
          'Person',
          event.distinctId,
          onTap: () => onFilter((q) => q.copyWith(distinctIds: person?.allIds ?? [event.distinctId])),
        ),
        if (event.sessionId != null)
          row('Session', event.sessionId!, onTap: () => onFilter((q) => q.copyWith(sessionId: event.sessionId))),
        if (event.service != null)
          row('App', event.service!, onTap: () => onFilter((q) => q.copyWith(services: [event.service!]))),
        const SizedBox(height: 16),
        SectionLabel('Properties (${props.length})'),
        if (props.isEmpty)
          Text('No properties', style: TextStyle(color: theme.colorScheme.outline))
        else
          for (final p in props)
            row(
              p.key,
              p.value is Map || p.value is List ? jsonEncode(p.value, toEncodable: (o) => '$o') : '${p.value}',
              onTap: () => onFilter(
                (q) => q.copyWith(filters: [...q.filters, AttrFilter(p.key, FilterOp.equals, '${p.value}')]),
              ),
            ),
      ],
    );
  }
}

/// Multi-select of names (events or property columns).
class _EventPicker extends StatefulWidget {
  const _EventPicker({required this.all, required this.selected, this.title = 'Events', this.allowCustom = false});

  final List<String> all;
  final Set<String> selected;
  final String title;
  final bool allowCustom;

  @override
  State<_EventPicker> createState() => _EventPickerState();
}

class _EventPickerState extends State<_EventPicker> {
  late final Set<String> _sel = {...widget.selected};
  late final List<String> _all = [...widget.all];
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim().toLowerCase();
    final shown = _all.where((n) => n.toLowerCase().contains(q)).toList();
    final canAdd = widget.allowCustom && q.isNotEmpty && !_all.contains(_search.text.trim());
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(
          children: [
            TextField(
              controller: _search,
              autofocus: true,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: widget.allowCustom ? 'Search or type a property name' : 'Search',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            if (canAdd)
              ListTile(
                leading: const Icon(Icons.add),
                title: Text('Add “${_search.text.trim()}”'),
                onTap: () => setState(() {
                  final n = _search.text.trim();
                  _all.insert(0, n);
                  _sel.add(n);
                  _search.clear();
                }),
              ),
            Expanded(
              child: shown.isEmpty
                  ? const Center(child: Text('Nothing found'))
                  : ListView(
                      children: [
                        for (final n in shown)
                          CheckboxListTile(
                            dense: true,
                            value: _sel.contains(n),
                            title: Text(n, style: monoStyle.copyWith(fontSize: 13)),
                            onChanged: (v) => setState(() => v == true ? _sel.add(n) : _sel.remove(n)),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => setState(_sel.clear), child: const Text('Clear')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _all.where(_sel.contains).toList()),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
