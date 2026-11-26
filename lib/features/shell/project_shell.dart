import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_menu.dart';
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

/// Sidebar section headings, keyed by the index of their first item.
const _sectionStarts = {0: 'Analyze', 6: 'Configure'};

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
                width: collapsed ? 72 : 240,
                child: GlassPanel(
                  radius: 24,
                  child: LayoutBuilder(
                    builder: (context, c) {
                      // Switch to icons as soon as the animating width gets tight,
                      // so labels never overflow mid-animation.
                      final rail = c.maxWidth < 170;
                      final hPad = rail ? 12.0 : 12.0;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Logo + collapse toggle.
                          SizedBox(
                            height: 64,
                            child: Padding(
                              padding: EdgeInsets.symmetric(horizontal: rail ? 0 : 16),
                              child: rail
                                  ? Center(
                                      child: _IconToggle(
                                        tooltip: 'Expand sidebar',
                                        icon: Icons.keyboard_double_arrow_right_rounded,
                                        onTap: () => ref.read(sidebarCollapsedProvider.notifier).set(false),
                                        child: const AppLogo(size: 26, showName: false),
                                      ),
                                    )
                                  : Row(
                                      children: [
                                        const AppLogo(size: 26),
                                        const Spacer(),
                                        _IconToggle(
                                          tooltip: 'Collapse sidebar',
                                          icon: Icons.keyboard_double_arrow_left_rounded,
                                          onTap: () => ref.read(sidebarCollapsedProvider.notifier).set(true),
                                        ),
                                      ],
                                    ),
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.symmetric(horizontal: hPad),
                            child: _ProjectSwitcher(current: p, iconOnly: rail),
                          ),
                          const SizedBox(height: 8),
                          Expanded(
                            child: ListView(
                              padding: const EdgeInsets.only(bottom: 8),
                              children: [
                                for (var i = 0; i < _items.length; i++) ...[
                                  if (_sectionStarts.containsKey(i))
                                    _NavSection(_sectionStarts[i]!, collapsed: rail, first: i == 0),
                                  Padding(
                                    padding: EdgeInsets.symmetric(horizontal: hPad, vertical: 1),
                                    child: _SideNavTile(
                                      item: _items[i],
                                      selected: i == _index,
                                      collapsed: rail,
                                      onTap: () => _go(i),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          Divider(height: 1, indent: hPad, endIndent: hPad),
                          Padding(
                            padding: EdgeInsets.fromLTRB(hPad, 8, hPad, 10),
                            child: _AccountTile(collapsed: rail),
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

class _SideNavTile extends StatefulWidget {
  const _SideNavTile({required this.item, required this.selected, required this.onTap, this.collapsed = false});

  final _NavItem item;
  final bool selected;
  final bool collapsed;
  final VoidCallback onTap;

  @override
  State<_SideNavTile> createState() => _SideNavTileState();
}

class _SideNavTileState extends State<_SideNavTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final selected = widget.selected;
    final hover = _hover && !selected;
    final fg = selected ? scheme.primary : (hover ? scheme.onSurface : scheme.onSurfaceVariant);
    // Active: tinted fill + accent bar. Hover: a faint neutral wash only.
    final bg = selected
        ? scheme.primary.withValues(alpha: dark ? 0.16 : 0.10)
        : (hover ? scheme.onSurface.withValues(alpha: dark ? 0.05 : 0.04) : Colors.transparent);
    final icon = Icon(selected ? widget.item.selectedIcon : widget.item.icon, size: 18, color: fg);

    final tile = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          setState(() => _hover = false);
          widget.onTap();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          height: 36,
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              if (selected)
                Positioned(
                  left: 0,
                  top: 9,
                  bottom: 9,
                  width: 3,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: Brand.accent(theme.brightness),
                      borderRadius: const BorderRadius.horizontal(right: Radius.circular(3)),
                    ),
                  ),
                ),
              Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: widget.collapsed ? 0 : 12),
                  child: widget.collapsed
                      ? Center(child: icon)
                      : Row(
                          children: [
                            icon,
                            const SizedBox(width: 11),
                            Expanded(
                              child: Text(
                                widget.item.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                softWrap: false,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontSize: 13.5,
                                  height: 1.2,
                                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                                  color: selected
                                      ? scheme.primary
                                      : (hover ? scheme.onSurface : scheme.onSurface.withValues(alpha: 0.82)),
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return widget.collapsed ? Tooltip(message: widget.item.label, preferBelow: false, child: tile) : tile;
  }
}

/// Small square icon button (sidebar collapse/expand). With [child], shows
/// the child and swaps to the icon on hover.
class _IconToggle extends StatefulWidget {
  const _IconToggle({required this.tooltip, required this.icon, required this.onTap, this.child});

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final Widget? child;

  @override
  State<_IconToggle> createState() => _IconToggleState();
}

class _IconToggleState extends State<_IconToggle> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hover ? scheme.onSurface.withValues(alpha: 0.06) : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
            ),
            child: widget.child != null && !_hover
                ? widget.child
                : Icon(widget.icon, size: 18, color: scheme.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}

/// Signed-in user at the bottom of the sidebar; opens Account.
class _AccountTile extends ConsumerStatefulWidget {
  const _AccountTile({required this.collapsed});

  final bool collapsed;

  @override
  ConsumerState<_AccountTile> createState() => _AccountTileState();
}

class _AccountTileState extends ConsumerState<_AccountTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final user = ref.watch(userProvider).value;
    final email = user?.email ?? '';
    final name = (user?.displayName?.trim().isNotEmpty ?? false) ? user!.displayName!.trim() : email.split('@').first;
    final initial = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    final avatar = Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: scheme.primary.withValues(alpha: 0.14),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.25)),
      ),
      child: Text(
        initial,
        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: scheme.primary),
      ),
    );
    final tile = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => context.push('/account'),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 46,
          padding: EdgeInsets.symmetric(horizontal: widget.collapsed ? 0 : 8),
          decoration: BoxDecoration(
            color: _hover ? scheme.onSurface.withValues(alpha: 0.05) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: widget.collapsed
              ? Center(child: avatar)
              : Row(
                  children: [
                    avatar,
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name.isEmpty ? 'Account' : name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
                          ),
                          if (email.isNotEmpty)
                            Text(
                              email,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(fontSize: 11.5),
                            ),
                        ],
                      ),
                    ),
                    Icon(Icons.settings_outlined, size: 16, color: scheme.outline),
                  ],
                ),
        ),
      ),
    );
    return widget.collapsed ? Tooltip(message: email.isEmpty ? 'Account' : email, child: tile) : tile;
  }
}

class _NavSection extends StatelessWidget {
  const _NavSection(this.label, {required this.collapsed, required this.first});

  final String label;
  final bool collapsed;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (collapsed) {
      return first
          ? const SizedBox(height: 4)
          : const Padding(padding: EdgeInsets.symmetric(horizontal: 18, vertical: 10), child: Divider());
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(24, first ? 6 : 18, 16, 6),
      child: Text(
        label.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          fontSize: 10.5,
          letterSpacing: 1.0,
          fontWeight: FontWeight.w700,
          color: theme.colorScheme.outline,
        ),
      ),
    );
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
    return AppMenuAnchor<String>(
      tooltip: 'Switch project',
      selected: {current.id},
      searchHint: 'Search projects',
      searchable: projects.length > 6,
      minWidth: 240,
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
      entries: () => [
        for (final p in projects)
          MenuEntry(p.id, p.name, leading: _ProjectAvatar(p.name, size: 20), section: 'Projects'),
        const MenuEntry('_new', 'New project…', icon: Icons.add_rounded),
        const MenuEntry('_all', 'All projects', icon: Icons.grid_view_rounded),
      ],
      builder: (context, open) => _switcherBody(context, scheme, open),
    );
  }

  Widget _switcherBody(BuildContext context, ColorScheme scheme, bool open) {
    return iconOnly
        ? SizedBox(height: 44, child: Center(child: _ProjectAvatar(current.name, size: 36)))
        : Container(
            padding: EdgeInsets.fromLTRB(compact ? 4 : 8, compact ? 4 : 8, 8, compact ? 4 : 8),
            decoration: BoxDecoration(
              color: compact
                  ? null
                  : (open ? scheme.primary.withValues(alpha: 0.08) : scheme.surface.withValues(alpha: 0.30)),
              border: compact
                  ? null
                  : Border.all(color: open ? scheme.primary.withValues(alpha: 0.35) : scheme.outlineVariant),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
              children: [
                _ProjectAvatar(current.name, size: compact ? 26 : 30),
                const SizedBox(width: 10),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (!compact)
                        Text(
                          'Project',
                          style: Theme.of(
                            context,
                          ).textTheme.labelSmall?.copyWith(color: scheme.outline, fontSize: 10.5),
                        ),
                      Text(
                        current.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14, letterSpacing: -0.2),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.unfold_more_rounded, size: 18, color: scheme.outline),
              ],
            ),
          );
  }
}

/// Rounded-square avatar with the project's initial on the brand gradient.
class _ProjectAvatar extends StatelessWidget {
  const _ProjectAvatar(this.name, {required this.size});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final initial = name.trim().isEmpty ? '?' : name.trim().characters.first.toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: Brand.accent(Brightness.light),
        borderRadius: BorderRadius.circular(size * 0.3),
        boxShadow: [BoxShadow(color: Brand.indigo.withValues(alpha: 0.35), blurRadius: 10, offset: const Offset(0, 3))],
      ),
      child: Text(
        initial,
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: size * 0.45),
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
