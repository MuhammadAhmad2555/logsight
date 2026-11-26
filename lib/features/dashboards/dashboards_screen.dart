import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_menu.dart';
import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../data/dashboards.dart';
import '../../state/providers.dart';
import '../../state/quick_access.dart';

String dashboardPath(String pid, String id) => '/p/$pid/dashboards/$id';

/// Asks for a name and creates a dashboard; returns its ID.
Future<String?> createDashboard(
  BuildContext context,
  WidgetRef ref,
  String pid, {
  List<DashboardTile> tiles = const [],
}) async {
  final name = await promptText(
    context,
    title: 'New dashboard',
    label: 'Name',
    action: 'Create',
    validator: (v) => v.trim().isEmpty ? 'Enter a name' : (v.trim().length > 80 ? 'Too long' : null),
  );
  if (name == null) return null;
  final uid = ref.read(userProvider).value?.uid;
  if (uid == null) return null;
  try {
    return await ref.read(dashboardsRepositoryProvider).create(pid, name, uid: uid, tiles: tiles);
  } catch (e) {
    if (context.mounted) showMessage(context, friendlyError(e), error: true);
    return null;
  }
}

/// "Add to dashboard" from Logs or Activity: pick a dashboard (or make one)
/// and add [tile] to it.
Future<void> addTileToDashboard(BuildContext context, WidgetRef ref, String pid, DashboardTile tile) async {
  final dashboards = ref.read(dashboardsProvider(pid)).value ??
      await ref.read(dashboardsRepositoryProvider).watchAll(pid).first;
  if (!context.mounted) return;
  final picked = await showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('Add to dashboard'),
      children: [
        for (final d in dashboards)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, d.id),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.space_dashboard_outlined),
              title: Text(d.name),
              subtitle: Text('${d.tiles.length} tile${d.tiles.length == 1 ? '' : 's'}'),
              enabled: d.tiles.length < Dashboard.maxTiles,
            ),
          ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, ''),
          child: const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.add_rounded),
            title: Text('New dashboard…'),
          ),
        ),
      ],
    ),
  );
  if (picked == null || !context.mounted) return;
  String? id = picked;
  try {
    if (picked.isEmpty) {
      id = await createDashboard(context, ref, pid, tiles: [tile]);
    } else {
      await ref.read(dashboardsRepositoryProvider).addTile(pid, picked, tile);
    }
  } catch (e) {
    if (context.mounted) showMessage(context, friendlyError(e), error: true);
    return;
  }
  if (id == null || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: const Text('Added to dashboard'),
      action: SnackBarAction(label: 'Open', onPressed: () => context.go(dashboardPath(pid, id!))),
    ),
  );
}

/// All dashboards of a project.
class DashboardsScreen extends ConsumerWidget {
  const DashboardsScreen({super.key, required this.projectId});

  final String projectId;

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final id = await createDashboard(context, ref, projectId);
    if (id != null && context.mounted) context.go(dashboardPath(projectId, id));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final dashboards = ref.watch(dashboardsProvider(projectId));
    final quick = ref.watch(quickAccessProvider(projectId));
    final isAdmin = ref.watch(myRoleProvider(projectId))?.canManageKeys ?? false;
    final uid = ref.watch(userProvider).value?.uid;
    final wide = isWide(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
      children: [
        Row(
          children: [
            Expanded(child: Text('Dashboards', style: theme.textTheme.headlineSmall)),
            FilledButton.icon(
              onPressed: () => _create(context, ref),
              icon: const Icon(Icons.add_rounded),
              label: const Text('New dashboard'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Your own views of the numbers that matter: log volume, errors and events, side by side.',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        dashboards.when(
          loading: () => const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => ErrorView(e),
          data: (list) => list.isEmpty
              ? GlassCard(
                  child: EmptyState(
                    icon: Icons.space_dashboard_outlined,
                    title: 'No dashboards yet',
                    message: 'Create one here, or use “Add to dashboard” on any Logs or Activity view.',
                    action: FilledButton.icon(
                      onPressed: () => _create(context, ref),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Create dashboard'),
                    ),
                  ),
                )
              : GridView.count(
                  crossAxisCount: wide ? 3 : 1,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: wide ? 2.4 : 3.6,
                  children: [
                    for (final d in list)
                      _DashboardCard(
                        dashboard: d,
                        starred: quick.isStarred(dashboardPath(projectId, d.id)),
                        canDelete: isAdmin || d.createdBy == uid,
                        onOpen: () => context.go(dashboardPath(projectId, d.id)),
                        onStar: () => ref
                            .read(quickAccessProvider(projectId).notifier)
                            .toggleStar(QuickLink(path: dashboardPath(projectId, d.id), title: d.name, kind: 'Dashboard')),
                        onDelete: () async {
                          final ok = await confirm(
                            context,
                            title: 'Delete “${d.name}”?',
                            message: 'The dashboard and its tiles are removed for everyone. Logs and events stay.',
                            action: 'Delete',
                            destructive: true,
                          );
                          if (!ok) return;
                          await ref.read(dashboardsRepositoryProvider).delete(projectId, d.id);
                          ref.read(quickAccessProvider(projectId).notifier).remove(dashboardPath(projectId, d.id));
                        },
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _DashboardCard extends StatelessWidget {
  const _DashboardCard({
    required this.dashboard,
    required this.starred,
    required this.canDelete,
    required this.onOpen,
    required this.onStar,
    required this.onDelete,
  });

  final Dashboard dashboard;
  final bool starred;
  final bool canDelete;
  final VoidCallback onOpen;
  final VoidCallback onStar;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final d = dashboard;
    return GlassCard(
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: Brand.accent(theme.brightness),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: const Icon(Icons.space_dashboard_rounded, color: Colors.white, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      '${d.tiles.length} tile${d.tiles.length == 1 ? '' : 's'} · ${d.range.label}'
                      '${d.updatedAt == null ? '' : ' · edited ${timeAgo(d.updatedAt)}'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: starred ? 'Unstar' : 'Star',
                onPressed: onStar,
                icon: Icon(
                  starred ? Icons.star_rounded : Icons.star_outline_rounded,
                  color: starred ? const Color(0xFFF5B301) : scheme.outline,
                ),
              ),
              if (canDelete)
                AppMenuAnchor<String>(
                  tooltip: 'More',
                  searchable: false,
                  minWidth: 160,
                  entries: () => [const MenuEntry('delete', 'Delete', icon: Icons.delete_outline, destructive: true)],
                  onSelected: (_) => onDelete(),
                  builder: (context, open) =>
                      const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.more_vert_rounded, size: 20)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
