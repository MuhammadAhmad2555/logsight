import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/time_format.dart';
import '../../core/glass.dart';
import '../../core/severity.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../data/activity.dart';
import '../../data/log_query.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../activity/activity_screen.dart';

String personPath(String pid, String id) => '/p/$pid/people/${Uri.encodeComponent(id)}';

/// Everyone who sent events, most recently seen first.
class PeopleScreen extends ConsumerStatefulWidget {
  const PeopleScreen({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends ConsumerState<PeopleScreen> {
  final _search = TextEditingController();
  bool _showAnonymous = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final people = ref.watch(peopleProvider(widget.projectId));
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
      children: [
        Text('People', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          'Everyone who sent events. Signed-in users appear by email or name once your app calls identify().',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 360,
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search, size: 20),
                  hintText: 'Search by ID, email, name or any property',
                ),
              ),
            ),
            FilterChip(
              label: const Text('Show anonymous'),
              selected: _showAnonymous,
              onSelected: (v) => setState(() => _showAnonymous = v),
            ),
          ],
        ),
        const SizedBox(height: 16),
        people.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(48),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => ErrorView(e),
          data: (list) {
            final shown = list
                .where((p) => (_showAnonymous || !p.isAnonymous) && p.matchesSearch(_search.text))
                .toList();
            if (shown.isEmpty) {
              return GlassCard(
                child: EmptyState(
                  icon: Icons.people_outline,
                  title: list.isEmpty ? 'No people yet' : 'Nobody matches',
                  message: list.isEmpty
                      ? 'People appear when your app sends events with capture() or identify().'
                      : (!_showAnonymous ? 'Anonymous visitors are hidden. Turn on “Show anonymous”.' : null),
                ),
              );
            }
            return GlassCard(
              child: Column(
                children: [
                  for (var i = 0; i < shown.length; i++) ...[
                    if (i > 0) const Divider(),
                    _PersonTile(projectId: widget.projectId, person: shown[i]),
                  ],
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      '${shown.length} of ${list.length} most recently seen people',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

class _PersonTile extends StatelessWidget {
  const _PersonTile({required this.projectId, required this.person});

  final String projectId;
  final Person person;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = person;
    final subtitle = [
      if (p.displayName != p.id) p.id,
      'seen ${timeAgo(p.lastSeen)}',
      if (p.firstSeen != null) 'first ${DateFormat.yMMMd().format(p.firstSeen!)}',
    ].join(' · ');
    return ListTile(
      leading: _Avatar(person: p),
      title: Text(p.isAnonymous ? 'Anonymous' : p.displayName, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (p.properties['plan'] != null)
            Chip(label: Text('${p.properties['plan']}'), visualDensity: VisualDensity.compact),
          Icon(Icons.chevron_right, color: theme.colorScheme.outline),
        ],
      ),
      onTap: () => context.go(personPath(projectId, p.id)),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.person, this.size = 40});

  final Person person;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = [Colors.indigo, Colors.teal, Colors.deepOrange, Colors.purple, Colors.blue, Colors.pink];
    final c = colors[person.id.codeUnits.fold<int>(0, (a, b) => a + b) % colors.length];
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: person.isAnonymous ? scheme.outlineVariant : c.withValues(alpha: 0.18),
      child: person.isAnonymous
          ? Icon(Icons.person_outline, size: size * 0.5, color: scheme.onSurfaceVariant)
          : Text(
              person.displayName.characters.first.toUpperCase(),
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: size * 0.42, color: c),
            ),
    );
  }
}

/// One person: properties, IDs, activity timeline, sessions, logs and errors.
class PersonScreen extends ConsumerStatefulWidget {
  const PersonScreen({super.key, required this.projectId, required this.personId});

  final String projectId;
  final String personId;

  @override
  ConsumerState<PersonScreen> createState() => _PersonScreenState();
}

enum _Tab { activity, sessions, logs, properties }

class _PersonScreenState extends ConsumerState<PersonScreen> {
  _Tab _tab = _Tab.activity;
  RelativePreset _range = RelativePreset.d30;
  Future<List<ActivityEvent>>? _events;
  Future<List<LogEntry>>? _logs;
  List<String>? _loadedFor;

  void _load(List<String> ids) {
    _loadedFor = ids;
    final range = TimeRange.relative(_range);
    _events = ref
        .read(activityRepositoryProvider)
        .fetchPage(widget.projectId, ActivityQuery(range: range, distinctIds: ids), want: 1000, maxScan: 1000)
        .then((p) => p.events);
    _logs = Future.wait([
      for (final id in ids.take(10))
        ref
            .read(logRepositoryProvider)
            .fetchPage(
              widget.projectId,
              LogQuery(range: range, filters: [AttrFilter('userId', FilterOp.equals, id)]),
              want: 200,
              maxScan: 2000,
            ),
    ]).then((pages) => pages.expand((p) => p.logs).toList()..sort((a, b) => b.timestamp.compareTo(a.timestamp)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final key = (widget.projectId, widget.personId);
    final personAsync = ref.watch(personProvider(key));
    return personAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorView(e),
      data: (person) {
        final p = person ?? Person(id: widget.personId, properties: const {}, aliases: const []);
        final ids = p.allIds;
        if (_loadedFor == null || _loadedFor!.join('|') != ids.join('|')) _load(ids);
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => context.go('/p/${widget.projectId}/people'),
                icon: const Icon(Icons.arrow_back, size: 18),
                label: const Text('People'),
              ),
            ),
            GlassCard(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Row(
                  children: [
                    _Avatar(person: p, size: 56),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(p.isAnonymous ? 'Anonymous' : p.displayName, style: theme.textTheme.titleLarge),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 14,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              InkWell(
                                onTap: () => copyToClipboard(context, p.id, what: 'ID copied'),
                                child: Text('ID ${p.id}  ⧉', style: monoStyle.copyWith(fontSize: 12)),
                              ),
                              Text('Last seen ${timeAgo(p.lastSeen)}', style: theme.textTheme.bodySmall),
                              if (p.firstSeen != null)
                                Text(
                                  'First seen ${DateFormat.yMMMd().add_Hm().format(p.firstSeen!)}',
                                  style: theme.textTheme.bodySmall,
                                ),
                              if (p.aliases.isNotEmpty)
                                Tooltip(
                                  message: p.aliases.join('\n'),
                                  child: Text('${p.aliases.length} linked ID(s)', style: theme.textTheme.bodySmall),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () => context.go(activityUri(widget.projectId, ActivityQuery(distinctIds: ids))),
                      icon: const Icon(Icons.bolt, size: 18),
                      label: const Text('Open in Activity'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<_Tab>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: _Tab.activity, label: Text('Activity'), icon: Icon(Icons.bolt, size: 16)),
                    ButtonSegment(value: _Tab.sessions, label: Text('Sessions'), icon: Icon(Icons.timelapse, size: 16)),
                    ButtonSegment(value: _Tab.logs, label: Text('Logs'), icon: Icon(Icons.receipt_long, size: 16)),
                    ButtonSegment(value: _Tab.properties, label: Text('Properties'), icon: Icon(Icons.tune, size: 16)),
                  ],
                  selected: {_tab},
                  onSelectionChanged: (s) => setState(() => _tab = s.first),
                ),
                SegmentedButton<RelativePreset>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: RelativePreset.d7, label: Text('7d')),
                    ButtonSegment(value: RelativePreset.d30, label: Text('30d')),
                    ButtonSegment(value: RelativePreset.d90, label: Text('90d')),
                  ],
                  selected: {_range},
                  onSelectionChanged: (s) => setState(() {
                    _range = s.first;
                    _load(ids);
                  }),
                ),
              ],
            ),
            const SizedBox(height: 14),
            switch (_tab) {
              _Tab.activity => _timeline(),
              _Tab.sessions => _sessions(),
              _Tab.logs => _logList(),
              _Tab.properties => _properties(p),
            },
          ],
        );
      },
    );
  }

  Widget _loader<T>(Future<T>? f, Widget Function(T) build) => FutureBuilder<T>(
    future: f,
    builder: (context, snap) {
      if (snap.hasError) return ErrorView(snap.error!);
      if (!snap.hasData) {
        return const Padding(
          padding: EdgeInsets.all(40),
          child: Center(child: CircularProgressIndicator()),
        );
      }
      return build(snap.data as T);
    },
  );

  Widget _timeline() => _loader<List<ActivityEvent>>(_events, (events) {
    if (events.isEmpty) {
      return const GlassCard(
        child: EmptyState(icon: Icons.bolt_outlined, title: 'No events in this range'),
      );
    }
    final theme = Theme.of(context);
    final byDay = <String, List<ActivityEvent>>{};
    for (final e in events) {
      byDay.putIfAbsent(DateFormat.yMMMEd().format(e.timestamp), () => []).add(e);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final day in byDay.entries) ...[
          SectionLabel('${day.key} · ${day.value.length} events'),
          GlassCard(
            child: Column(
              children: [
                for (final e in day.value)
                  ListTile(
                    dense: true,
                    leading: Text(timeFormat(context, seconds: true).format(e.timestamp), style: monoStyle.copyWith(fontSize: 12)),
                    title: Text(e.label, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: e.properties.isEmpty
                        ? null
                        : Text(
                            e.properties.entries
                                .where((p) => !p.key.startsWith(r'$'))
                                .take(4)
                                .map((p) => '${p.key}: ${p.value}')
                                .join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                    trailing: e.service == null ? null : Text(e.service!, style: theme.textTheme.bodySmall),
                    onTap: () => context.go(
                      activityUri(
                        widget.projectId,
                        ActivityQuery(
                          range: TimeRange.absolute(
                            e.timestamp.subtract(const Duration(minutes: 30)),
                            e.timestamp.add(const Duration(minutes: 30)),
                          ),
                          distinctIds: [e.distinctId],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
        ],
      ],
    );
  });

  Widget _sessions() => _loader<List<ActivityEvent>>(_events, (events) {
    final sessions = groupSessions(events);
    if (sessions.isEmpty) {
      return const GlassCard(
        child: EmptyState(
          icon: Icons.timelapse,
          title: 'No sessions',
          message: 'Set appTrack.sessionId in your app to group events into sessions.',
        ),
      );
    }
    String dur(Duration d) => d.inHours > 0
        ? '${d.inHours}h ${d.inMinutes % 60}m'
        : (d.inMinutes > 0 ? '${d.inMinutes}m ${d.inSeconds % 60}s' : '${d.inSeconds}s');
    return GlassCard(
      child: Column(
        children: [
          for (var i = 0; i < sessions.length; i++) ...[
            if (i > 0) const Divider(),
            ListTile(
              leading: const Icon(Icons.timelapse),
              title: Text(timeFormat(context, date: 'MMM d,').format(sessions[i].start)),
              subtitle: Text(
                '${sessions[i].events.length} events · ${dur(sessions[i].duration)}'
                '${sessions[i].services.isEmpty ? '' : ' · ${sessions[i].services.join(', ')}'}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.go(
                activityUri(
                  widget.projectId,
                  ActivityQuery(range: const TimeRange.relative(RelativePreset.d90), sessionId: sessions[i].id),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  });

  Widget _logList() => _loader<List<LogEntry>>(_logs, (logs) {
    if (logs.isEmpty) {
      return const GlassCard(
        child: EmptyState(
          icon: Icons.receipt_long_outlined,
          title: 'No logs for this person',
          message: 'Logs are linked when the app sets appTrack.userId (identify() does this).',
        ),
      );
    }
    final errors = logs.where((l) => l.severity.index >= Severity.error.index).length;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel('${logs.length} logs · $errors errors'),
        GlassCard(
          child: Column(
            children: [
              for (final l in logs.take(200))
                ListTile(
                  dense: true,
                  leading: SeverityBadge(l.severity, compact: true),
                  title: Text(l.message, maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle),
                  subtitle: Text(
                    '${timeFormat(context, date: 'MMM d', seconds: true).format(l.timestamp)} · ${l.service}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  });

  Widget _properties(Person p) {
    final theme = Theme.of(context);
    final props = p.properties.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    if (props.isEmpty) {
      return const GlassCard(
        child: EmptyState(
          icon: Icons.tune,
          title: 'No properties',
          message: 'Set them with identify(id, properties: {...}) or setPersonProperties().',
        ),
      );
    }
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          children: [
            for (final e in props)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 180, child: Text(e.key, style: theme.textTheme.bodySmall)),
                    Expanded(
                      child: SelectableText(
                        e.value is Map || e.value is List
                            ? jsonEncode(e.value, toEncodable: (o) => '$o')
                            : '${e.value}',
                        style: monoStyle.copyWith(fontSize: 12.5),
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
