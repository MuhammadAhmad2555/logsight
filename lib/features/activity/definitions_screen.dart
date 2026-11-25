import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../data/activity.dart';
import '../../data/log_query.dart';
import '../../state/providers.dart';
import 'activity_screen.dart';

/// Data management: every event name and property the project has seen,
/// with team descriptions, a verified badge and 7-day volume.
class DefinitionsScreen extends ConsumerStatefulWidget {
  const DefinitionsScreen({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<DefinitionsScreen> createState() => _DefinitionsScreenState();
}

class _DefinitionsScreenState extends ConsumerState<DefinitionsScreen> {
  bool _properties = false;
  final _search = TextEditingController();
  final Map<String, Future<int>> _volumes = {};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<int> _volume(String name) => _volumes[name] ??= ref
      .read(activityRepositoryProvider)
      .count(widget.projectId, ActivityQuery(range: const TimeRange.relative(RelativePreset.d7), events: [name]));

  Future<void> _edit(EventDefinition d) async {
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final c = TextEditingController(text: d.description ?? '');
        return AlertDialog(
          title: Text(d.name, style: monoStyle),
          content: SizedBox(
            width: 420,
            child: TextField(
              controller: c,
              autofocus: true,
              maxLines: 4,
              maxLength: 500,
              decoration: const InputDecoration(labelText: 'Description', hintText: 'When is this event sent?'),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Save')),
          ],
        );
      },
    );
    if (text == null) return;
    await _update(d.name, description: text);
  }

  Future<void> _update(String name, {String? description, bool? verified}) async {
    final uid = ref.read(userProvider).value?.uid;
    if (uid == null) return;
    try {
      await ref
          .read(activityRepositoryProvider)
          .updateDefinition(widget.projectId, name, uid, description: description, verified: verified);
    } catch (e) {
      if (mounted) showMessage(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final defs = ref.watch(eventDefinitionsProvider(widget.projectId));
    final canEdit = ref.watch(myRoleProvider(widget.projectId))?.canManageKeys ?? false;
    final q = _search.text.trim().toLowerCase();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
      children: [
        Text('Data management', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          'Events and properties are added automatically when apps send them. '
          'Admins can describe them and mark them verified.',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Text('Events'), icon: Icon(Icons.bolt, size: 16)),
                ButtonSegment(value: true, label: Text('Properties'), icon: Icon(Icons.tune, size: 16)),
              ],
              selected: {_properties},
              onSelectionChanged: (s) => setState(() => _properties = s.first),
            ),
            SizedBox(
              width: 300,
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search, size: 20), hintText: 'Search'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        defs.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(48),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => ErrorView(e),
          data: (list) => _properties ? _propertyList(list, q) : _eventList(list, q, canEdit),
        ),
      ],
    );
  }

  Widget _eventList(List<EventDefinition> list, String q, bool canEdit) {
    final theme = Theme.of(context);
    final shown = list
        .where((d) => d.name.toLowerCase().contains(q) || (d.description ?? '').toLowerCase().contains(q))
        .toList();
    if (shown.isEmpty) {
      return const GlassCard(
        child: EmptyState(icon: Icons.bolt_outlined, title: 'No events yet'),
      );
    }
    return GlassCard(
      child: Column(
        children: [
          for (var i = 0; i < shown.length; i++) ...[
            if (i > 0) const Divider(),
            ListTile(
              title: Row(
                children: [
                  Flexible(
                    child: Text(shown[i].name, style: monoStyle.copyWith(fontWeight: FontWeight.w600)),
                  ),
                  if (shown[i].verified) ...[
                    const SizedBox(width: 6),
                    Tooltip(
                      message: 'Verified',
                      child: Icon(Icons.verified, size: 16, color: theme.colorScheme.primary),
                    ),
                  ],
                ],
              ),
              subtitle: Text(
                [
                  if ((shown[i].description ?? '').isNotEmpty) shown[i].description!,
                  '${shown[i].properties.length} properties · last seen ${timeAgo(shown[i].lastSeen)}',
                ].join('\n'),
              ),
              isThreeLine: (shown[i].description ?? '').isNotEmpty,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FutureBuilder<int>(
                    future: _volume(shown[i].name),
                    builder: (_, s) => Tooltip(
                      message: 'Events in the last 7 days',
                      child: Text(
                        s.hasData ? NumberFormat.compact().format(s.data) : '…',
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                  ),
                  if (canEdit)
                    PopupMenuButton<String>(
                      onSelected: (v) => switch (v) {
                        'edit' => _edit(shown[i]),
                        'verify' => _update(shown[i].name, verified: !shown[i].verified),
                        _ => context.go(activityUri(widget.projectId, ActivityQuery(events: [shown[i].name]))),
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'edit', child: Text('Edit description')),
                        PopupMenuItem(
                          value: 'verify',
                          child: Text(shown[i].verified ? 'Remove verified' : 'Mark verified'),
                        ),
                        const PopupMenuItem(value: 'open', child: Text('View in Activity')),
                      ],
                    ),
                ],
              ),
              onTap: () => context.go(activityUri(widget.projectId, ActivityQuery(events: [shown[i].name]))),
            ),
          ],
        ],
      ),
    );
  }

  Widget _propertyList(List<EventDefinition> list, String q) {
    final theme = Theme.of(context);
    final usage = <String, List<String>>{};
    for (final d in list) {
      for (final p in d.properties) {
        usage.putIfAbsent(p, () => []).add(d.name);
      }
    }
    final keys = usage.keys.where((k) => k.toLowerCase().contains(q)).toList()..sort();
    if (keys.isEmpty) {
      return const GlassCard(
        child: EmptyState(icon: Icons.tune, title: 'No properties yet'),
      );
    }
    return GlassCard(
      child: Column(
        children: [
          for (var i = 0; i < keys.length; i++) ...[
            if (i > 0) const Divider(),
            ListTile(
              dense: true,
              title: Text(keys[i], style: monoStyle.copyWith(fontWeight: FontWeight.w600)),
              subtitle: Text(
                'Used by ${usage[keys[i]]!.length} event${usage[keys[i]]!.length == 1 ? '' : 's'}: ${usage[keys[i]]!.join(', ')}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
