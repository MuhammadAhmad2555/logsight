import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../auth/auth_layout.dart';
import '../projects/projects_screen.dart';

class _NavItem {
  const _NavItem(this.segment, this.label, this.icon, this.selectedIcon);
  final String segment;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// How many items fit in the phone tab bar; the rest go under "More".
const _phoneTabs = 4;

const _items = [
  _NavItem('overview', 'Overview', Icons.space_dashboard_outlined, Icons.space_dashboard),
  _NavItem('activity', 'Activity', Icons.bolt_outlined, Icons.bolt),
  _NavItem('logs', 'Logs', Icons.receipt_long_outlined, Icons.receipt_long),
  _NavItem('issues', 'Issues', Icons.bug_report_outlined, Icons.bug_report),
  _NavItem('people', 'People', Icons.people_outline, Icons.people),
  _NavItem('alerts', 'Alerts', Icons.notifications_outlined, Icons.notifications),
  _NavItem('data', 'Data management', Icons.dataset_outlined, Icons.dataset),
  _NavItem('keys', 'Ingest keys', Icons.key_outlined, Icons.key),
  _NavItem('members', 'Members', Icons.group_outlined, Icons.group),
  _NavItem('settings', 'Settings', Icons.settings_outlined, Icons.settings),
];

/// Navigation around a project's pages: a sidebar on wide screens and a
/// bottom bar on phones.
class ProjectShell extends ConsumerStatefulWidget {
  const ProjectShell({super.key, required this.projectId, required this.location, required this.child});

  final String projectId;
  final String location;
  final Widget child;

  @override
  ConsumerState<ProjectShell> createState() => _ProjectShellState();
}

class _ProjectShellState extends ConsumerState<ProjectShell> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(lastProjectProvider.notifier).set(widget.projectId);
    });
  }

  @override
  void didUpdateWidget(ProjectShell old) {
    super.didUpdateWidget(old);
    if (old.projectId != widget.projectId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(lastProjectProvider.notifier).set(widget.projectId);
      });
    }
  }

  int get _index {
    final seg = widget.location.split('/').elementAtOrNull(3) ?? 'logs';
    final i = _items.indexWhere((e) => e.segment == seg);
    return i < 0 ? 0 : i;
  }

  void _go(int i) => context.go('/p/${widget.projectId}/${_items[i].segment}');

  void _showMore() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = _phoneTabs; i < _items.length; i++)
              ListTile(
                leading: Icon(i == _index ? _items[i].selectedIcon : _items[i].icon),
                title: Text(_items[i].label),
                selected: i == _index,
                onTap: () {
                  Navigator.pop(ctx);
                  _go(i);
                },
              ),
            ListTile(
              leading: const Icon(Icons.account_circle_outlined),
              title: const Text('Account'),
              onTap: () {
                Navigator.pop(ctx);
                context.push('/account');
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final project = ref.watch(projectProvider(widget.projectId));
    return project.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(body: _NoAccess(error: e)),
      data: (p) {
        if (p == null) return const Scaffold(body: _NoAccess());
        return isWide(context) ? _wide(p) : _narrow(p);
      },
    );
  }

  Widget _wide(Project p) {
    // The user's choice wins; otherwise collapse automatically in narrow windows.
    final pref = ref.watch(sidebarCollapsedProvider);
    final collapsed = pref ?? MediaQuery.sizeOf(context).width < 1100;
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 0, 14),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                width: collapsed ? 76 : 236,
                child: GlassPanel(
                  radius: 26,
                  child: LayoutBuilder(
                    builder: (context, c) {
                      // Switch to icons as soon as the animating width gets tight,
                      // so labels never overflow mid-animation.
                      final rail = c.maxWidth < 170;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: EdgeInsets.fromLTRB(rail ? 0 : 18, 20, rail ? 0 : 16, 16),
                            child: Align(
                              alignment: rail ? Alignment.center : Alignment.centerLeft,
                              child: AppLogo(size: 28, showName: !rail),
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.symmetric(horizontal: rail ? 10 : 12),
                            child: _ProjectSwitcher(current: p, iconOnly: rail),
                          ),
                          const SizedBox(height: 14),
                          Expanded(
                            child: ListView(
                              padding: EdgeInsets.zero,
                              children: [
                                for (var i = 0; i < _items.length; i++)
                                  Padding(
                                    padding: EdgeInsets.symmetric(horizontal: rail ? 10 : 12, vertical: 2),
                                    child: _SideNavTile(
                                      item: _items[i],
                                      selected: i == _index,
                                      collapsed: rail,
                                      onTap: () => _go(i),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.fromLTRB(rail ? 10 : 12, 4, rail ? 10 : 12, 2),
                            child: _SideNavTile(
                              item: const _NavItem(
                                'account',
                                'Account',
                                Icons.account_circle_outlined,
                                Icons.account_circle,
                              ),
                              selected: false,
                              collapsed: rail,
                              onTap: () => context.push('/account'),
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.fromLTRB(rail ? 10 : 12, 2, rail ? 10 : 12, 12),
                            child: _SideNavTile(
                              item: collapsed
                                  ? const _NavItem(
                                      'expand',
                                      'Expand sidebar',
                                      Icons.keyboard_double_arrow_right,
                                      Icons.keyboard_double_arrow_right,
                                    )
                                  : const _NavItem(
                                      'collapse',
                                      'Collapse sidebar',
                                      Icons.keyboard_double_arrow_left,
                                      Icons.keyboard_double_arrow_left,
                                    ),
                              selected: false,
                              collapsed: rail,
                              muted: true,
                              onTap: () => ref.read(sidebarCollapsedProvider.notifier).set(!collapsed),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
            Expanded(child: widget.child),
          ],
        ),
      ),
    );
  }

  Widget _narrow(Project p) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 8,
        flexibleSpace: const GlassPanel(radius: 0, shadow: false, strength: 0.8, child: SizedBox.expand()),
        title: _ProjectSwitcher(current: p, compact: true),
        actions: [
          IconButton(
            tooltip: 'Account',
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: () => context.push('/account'),
          ),
        ],
      ),
      body: widget.child,
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: GlassPanel(
          radius: 26,
          strength: 1.2,
          child: NavigationBar(
            selectedIndex: _index < _phoneTabs ? _index : _phoneTabs,
            onDestinationSelected: (i) => i < _phoneTabs ? _go(i) : _showMore(),
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            destinations: [
              for (final item in _items.take(_phoneTabs))
                NavigationDestination(icon: Icon(item.icon), selectedIcon: Icon(item.selectedIcon), label: item.label),
              const NavigationDestination(icon: Icon(Icons.more_horiz), label: 'More'),
            ],
          ),
        ),
      ),
    );
  }
}

class _SideNavTile extends StatelessWidget {
  const _SideNavTile({
    required this.item,
    required this.selected,
    required this.onTap,
    this.collapsed = false,
    this.muted = false,
  });

  final _NavItem item;
  final bool selected;
  final bool collapsed;
  final bool muted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final iconColor = selected ? scheme.primary : (muted ? scheme.outline : scheme.onSurfaceVariant);
    final icon = Icon(selected ? item.selectedIcon : item.icon, size: 20, color: iconColor);
    final tile = Material(
      color: selected ? scheme.primary.withValues(alpha: 0.14) : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: collapsed ? 0 : 12, vertical: 10),
          child: collapsed
              ? Center(child: icon)
              : Row(
                  children: [
                    icon,
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        item.label,
                        maxLines: 1,
                        overflow: TextOverflow.fade,
                        softWrap: false,
                        style: TextStyle(
                          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                          color: selected ? scheme.primary : (muted ? scheme.outline : scheme.onSurface),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
    return collapsed ? Tooltip(message: item.label, preferBelow: false, child: tile) : tile;
  }
}

class _ProjectSwitcher extends ConsumerWidget {
  const _ProjectSwitcher({required this.current, this.compact = false, this.iconOnly = false});

  final Project current;
  final bool compact;

  /// Collapsed sidebar: just the project's initial.
  final bool iconOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = ref.watch(myProjectsProvider).value ?? const <Project>[];
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<String>(
      tooltip: 'Switch project',
      position: PopupMenuPosition.under,
      onSelected: (v) {
        if (v == '_new') {
          createProjectFlow(context, ref);
        } else if (v == '_all') {
          context.go('/projects');
        } else {
          ref.read(lastProjectProvider.notifier).set(v);
          context.go('/p/$v/overview');
        }
      },
      itemBuilder: (_) => [
        for (final p in projects)
          PopupMenuItem(
            value: p.id,
            child: Row(
              children: [
                Icon(p.id == current.id ? Icons.check : null, size: 18),
                const SizedBox(width: 8),
                Flexible(child: Text(p.name, overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(value: '_new', child: Text('New project…')),
        const PopupMenuItem(value: '_all', child: Text('All projects')),
      ],
      child: iconOnly
          ? Tooltip(
              message: current.name,
              child: Container(
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  current.name.characters.first.toUpperCase(),
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17, color: scheme.primary),
                ),
              ),
            )
          : Container(
              padding: EdgeInsets.symmetric(horizontal: 10, vertical: compact ? 6 : 9),
              decoration: BoxDecoration(
                color: compact ? null : scheme.surface.withValues(alpha: 0.35),
                border: compact ? null : Border.all(color: scheme.outlineVariant),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
                children: [
                  Icon(Icons.folder_outlined, size: 18, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      current.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.unfold_more, size: 18, color: scheme.onSurfaceVariant),
                ],
              ),
            ),
    );
  }
}

class _NoAccess extends StatelessWidget {
  const _NoAccess({this.error});

  final Object? error;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.lock_outline,
      title: 'Project not available',
      message: error == null ? 'This project doesn’t exist, or you’re no longer a member.' : friendlyError(error!),
      action: FilledButton(onPressed: () => context.go('/projects'), child: const Text('Go to projects')),
    );
  }
}
