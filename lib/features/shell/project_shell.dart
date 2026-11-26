import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_menu.dart';
import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../state/quick_access.dart';
import '../auth/auth_layout.dart';
import '../projects/projects_screen.dart';

class _NavItem {
  const _NavItem(this.segment, this.label, this.icon, this.selectedIcon, {this.short});
  final String segment;
  final String label;
  final IconData icon;
  final IconData selectedIcon;

  /// Shorter label for the phone dock's pill.
  final String? short;
}

/// Sidebar section headings, keyed by the index of their first item.
const _sectionStarts = {0: 'Analyze', 8: 'Release', 9: 'Configure'};

/// How many items fit in the phone tab bar; the rest go under "More".
const _phoneTabs = 4;

const _items = [
  _NavItem(
    'overview',
    'Overview',
    Icons.space_dashboard_outlined,
    Icons.space_dashboard,
  ),
  _NavItem('activity', 'Activity', Icons.bolt_outlined, Icons.bolt),
  _NavItem('logs', 'Logs', Icons.receipt_long_outlined, Icons.receipt_long),
  _NavItem('issues', 'Issues', Icons.bug_report_outlined, Icons.bug_report),
  _NavItem('dashboards', 'Dashboards', Icons.dashboard_customize_outlined, Icons.dashboard_customize),
  _NavItem('endpoints', 'Endpoints', Icons.alt_route_outlined, Icons.alt_route),
  _NavItem('people', 'People', Icons.people_outline, Icons.people),
  _NavItem(
    'alerts',
    'Alerts',
    Icons.notifications_outlined,
    Icons.notifications,
  ),
  _NavItem('flags', 'Feature flags', Icons.toggle_off_outlined, Icons.toggle_on, short: 'Flags'),
  _NavItem('data', 'Data management', Icons.dataset_outlined, Icons.dataset, short: 'Data'),
  _NavItem('keys', 'Ingest keys', Icons.key_outlined, Icons.key),
  _NavItem('members', 'Members', Icons.group_outlined, Icons.group),
  _NavItem('settings', 'Settings', Icons.settings_outlined, Icons.settings),
];

/// Navigation around a project's pages: a sidebar on wide screens and a
/// bottom bar on phones.
class ProjectShell extends ConsumerStatefulWidget {
  const ProjectShell({
    super.key,
    required this.projectId,
    required this.location,
    required this.child,
  });

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
      _recordVisit();
    });
  }

  @override
  void didUpdateWidget(ProjectShell old) {
    super.didUpdateWidget(old);
    if (old.projectId != widget.projectId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted)
          ref.read(lastProjectProvider.notifier).set(widget.projectId);
      });
    }
    if (old.location != widget.location || old.projectId != widget.projectId) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _recordVisit());
    }
  }

  QuickAccessController get _quick => ref.read(quickAccessProvider(widget.projectId).notifier);

  /// The page's own path (no query), e.g. /p/x/logs.
  bool get _isSectionPage => widget.location.split('/').where((s) => s.isNotEmpty).length == 3;

  QuickLink _linkFor(int i) =>
      QuickLink(path: '/p/${widget.projectId}/${_items[i].segment}', title: _items[i].label, kind: 'Page');

  /// Adds section pages to Recents. Detail pages (a dashboard) add
  /// themselves with their own name.
  void _recordVisit() {
    if (!mounted || !_isSectionPage) return;
    final seg = widget.location.split('/').elementAtOrNull(3);
    final i = _items.indexWhere((e) => e.segment == seg);
    if (i >= 0) _quick.visit(_linkFor(i));
  }

  void _openLink(QuickLink l) => context.go(l.path);

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
      isScrollControlled: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final tiles = <(String, IconData, bool, VoidCallback)>[
          for (var i = _phoneTabs; i < _items.length; i++)
            (
              _items[i].label,
              i == _index ? _items[i].selectedIcon : _items[i].icon,
              i == _index,
              () {
                Navigator.pop(ctx);
                _go(i);
              },
            ),
          (
            'Account',
            Icons.account_circle_outlined,
            false,
            () {
              Navigator.pop(ctx);
              context.push('/account');
            },
          ),
        ];
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.85),
            child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Consumer(
                  builder: (ctx, ref, _) {
                    final quick = ref.watch(quickAccessProvider(widget.projectId));
                    final recents = quick.recents.where((r) => r.path != widget.location).take(4).toList();
                    void open(QuickLink l) {
                      Navigator.pop(ctx);
                      _openLink(l);
                    }

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (recents.isNotEmpty) ...[
                          const _SheetLabel('Recents'),
                          for (final l in recents) _QuickLinkRow(link: l, showTime: true, onTap: () => open(l)),
                          const SizedBox(height: 10),
                        ],
                        if (quick.starred.isNotEmpty) ...[
                          const _SheetLabel('Starred'),
                          for (final l in quick.starred)
                            _QuickLinkRow(
                              link: l,
                              onTap: () => open(l),
                              onUnstar: () => ref.read(quickAccessProvider(widget.projectId).notifier).toggleStar(l),
                            ),
                          const SizedBox(height: 10),
                        ],
                      ],
                    );
                  },
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 14),
                  child: Text('More', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                ),
                GridView.count(
                  crossAxisCount: 3,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.05,
                  children: [
                    for (final t in tiles) _MoreTile(label: t.$1, icon: t.$2, selected: t.$3, onTap: t.$4),
                  ],
                ),
              ],
            ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final project = ref.watch(projectProvider(widget.projectId));
    return project.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(body: _NoAccess(error: e)),
      data: (p) {
        if (p == null) return const Scaffold(body: _NoAccess());
        return isWide(context) ? _wide(p) : _narrow(p);
      },
    );
  }

  Widget _wide(Project p) {
    // The user's choice wins; otherwise collapse automatically in narrow windows.
    final quick = ref.watch(quickAccessProvider(widget.projectId));
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
                              padding: EdgeInsets.symmetric(
                                horizontal: rail ? 0 : 16,
                              ),
                              child: rail
                                  ? Center(
                                      child: _IconToggle(
                                        tooltip: 'Expand sidebar',
                                        icon: Icons
                                            .keyboard_double_arrow_right_rounded,
                                        onTap: () => ref
                                            .read(
                                              sidebarCollapsedProvider.notifier,
                                            )
                                            .set(false),
                                        child: const AppLogo(
                                          size: 26,
                                          showName: false,
                                        ),
                                      ),
                                    )
                                  : Row(
                                      children: [
                                        const AppLogo(size: 26),
                                        const Spacer(),
                                        _IconToggle(
                                          tooltip: 'Collapse sidebar',
                                          icon: Icons
                                              .keyboard_double_arrow_left_rounded,
                                          onTap: () => ref
                                              .read(
                                                sidebarCollapsedProvider
                                                    .notifier,
                                              )
                                              .set(true),
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
                                if (quick.starred.isNotEmpty) ...[
                                  _NavSection('Starred', collapsed: rail, first: true),
                                  for (final l in quick.starred)
                                    Padding(
                                      padding: EdgeInsets.symmetric(horizontal: hPad, vertical: 1),
                                      child: _SideNavTile(
                                        item: _NavItem('', l.title, _iconForLink(l), _iconForLink(l)),
                                        selected: false,
                                        collapsed: rail,
                                        starred: true,
                                        caption: l.kind == 'Page' ? null : l.kind,
                                        onStar: () => _quick.toggleStar(l),
                                        onTap: () => _openLink(l),
                                      ),
                                    ),
                                ],
                                for (var i = 0; i < _items.length; i++) ...[
                                  if (_sectionStarts.containsKey(i))
                                    _NavSection(
                                      _sectionStarts[i]!,
                                      collapsed: rail,
                                      first: i == 0 && quick.starred.isEmpty,
                                    ),
                                  Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: hPad,
                                      vertical: 1,
                                    ),
                                    child: _SideNavTile(
                                      item: _items[i],
                                      selected: i == _index,
                                      collapsed: rail,
                                      starred: quick.isStarred(_linkFor(i).path),
                                      onStar: () => _quick.toggleStar(_linkFor(i)),
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
        titleSpacing: 16,
        toolbarHeight: 64,
        flexibleSpace: const GlassPanel(
          radius: 0,
          shadow: false,
          strength: 1,
          child: SizedBox.expand(),
        ),
        title: _ProjectSwitcher(current: p, compact: true),
        actions: [
          if (_isSectionPage)
            Builder(
              builder: (context) {
                final link = _linkFor(_index);
                final starred = ref.watch(quickAccessProvider(widget.projectId)).isStarred(link.path);
                return IconButton(
                  tooltip: starred ? 'Unstar ${link.title}' : 'Star ${link.title}',
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    _quick.toggleStar(link);
                  },
                  icon: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                    child: Icon(
                      starred ? Icons.star_rounded : Icons.star_outline_rounded,
                      key: ValueKey(starred),
                      color: starred ? const Color(0xFFF5B301) : null,
                    ),
                  ),
                );
              },
            ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: IconButton.filledTonal(
              tooltip: 'Account',
              icon: const Icon(Icons.person_outline_rounded),
              onPressed: () => context.push('/account'),
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(
            height: 1,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
      body: widget.child,
      bottomNavigationBar: _FloatingDock(
        selected: _index < _phoneTabs ? _index : _phoneTabs,
        moreLabel: _index >= _phoneTabs ? (_items[_index].short ?? _items[_index].label) : 'More',
        moreIcon: _index >= _phoneTabs ? _items[_index].selectedIcon : Icons.grid_view_rounded,
        onSelect: (i) => i < _phoneTabs ? _go(i) : _showMore(),
      ),
    );
  }
}

/// Phone navigation: a floating frosted capsule. The current tab grows into a
/// gradient pill with its label; the others are icons only. When a page from
/// "More" is open, the last slot shows that page.
class _FloatingDock extends StatelessWidget {
  const _FloatingDock({
    required this.selected,
    required this.moreLabel,
    required this.moreIcon,
    required this.onSelect,
  });

  final int selected;
  final String moreLabel;
  final IconData moreIcon;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final slots = [
      for (var i = 0; i < _phoneTabs; i++) (_items[i].label, _items[i].icon, _items[i].selectedIcon),
      (moreLabel, selected == _phoneTabs ? moreIcon : Icons.grid_view_rounded, moreIcon),
    ];
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(32),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? 0.45 : 0.12),
              blurRadius: 28,
              offset: const Offset(0, 10),
            ),
            BoxShadow(
              color: theme.colorScheme.primary.withValues(alpha: dark ? 0.10 : 0.06),
              blurRadius: 40,
              spreadRadius: -6,
            ),
          ],
        ),
        child: GlassPanel(
          radius: 32,
          blur: 28,
          strength: dark ? 1.4 : 1.05,
          shadow: false,
          child: SizedBox(
            height: 64,
            child: Padding(
              padding: const EdgeInsets.all(7),
              child: LayoutBuilder(
                builder: (context, c) {
                  // The selected slot gets extra room for its label.
                  final n = slots.length;
                  final wide = (c.maxWidth * 0.42).clamp(96.0, 170.0);
                  final narrow = (c.maxWidth - wide) / (n - 1);
                  return Row(
                    children: [
                      for (var i = 0; i < n; i++)
                        _DockItem(
                          width: i == selected ? wide : narrow,
                          label: slots[i].$1,
                          icon: slots[i].$2,
                          selectedIcon: slots[i].$3,
                          selected: i == selected,
                          onTap: () {
                            HapticFeedback.selectionClick();
                            onSelect(i);
                          },
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DockItem extends StatefulWidget {
  const _DockItem({
    required this.width,
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.selected,
    required this.onTap,
  });

  final double width;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_DockItem> createState() => _DockItemState();
}

class _DockItemState extends State<_DockItem> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sel = widget.selected;
    const curve = Curves.easeOutCubic;
    const duration = Duration(milliseconds: 320);
    return Semantics(
      button: true,
      selected: sel,
      label: widget.label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.92 : 1,
          duration: const Duration(milliseconds: 120),
          child: AnimatedContainer(
            duration: duration,
            curve: curve,
            width: widget.width,
            height: 50,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(25),
              gradient: sel ? Brand.accent(theme.brightness) : null,
              boxShadow: sel
                  ? [
                      BoxShadow(
                        color: scheme.primary.withValues(alpha: 0.45),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                        spreadRadius: -4,
                      ),
                    ]
                  : const [],
            ),
            clipBehavior: Clip.antiAlias,
            child: Center(
              child: SingleChildScrollView(
                // Keeps the row from overflowing while the width animates.
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      transitionBuilder: (child, a) => ScaleTransition(scale: a, child: child),
                      child: Icon(
                        sel ? widget.selectedIcon : widget.icon,
                        key: ValueKey(sel),
                        size: 22,
                        color: sel ? Colors.white : scheme.onSurfaceVariant,
                      ),
                    ),
                    AnimatedSize(
                      duration: duration,
                      curve: curve,
                      child: sel
                          ? Padding(
                              padding: const EdgeInsets.only(left: 7),
                              child: ConstrainedBox(
                                constraints: BoxConstraints(maxWidth: widget.width - 52),
                                child: Text(
                                  widget.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelLarge?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13.5,
                                    letterSpacing: -0.1,
                                  ),
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Icon for a recent or starred link, from its path.
IconData _iconForLink(QuickLink l) {
  final parts = l.path.split('?').first.split('/').where((s) => s.isNotEmpty).toList();
  final seg = parts.length > 2 ? parts[2] : '';
  if (seg == 'dashboards' && parts.length > 3) return Icons.dashboard_customize_outlined;
  return _items.where((e) => e.segment == seg).firstOrNull?.icon ?? Icons.link_rounded;
}

class _SheetLabel extends StatelessWidget {
  const _SheetLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 2, 6, 6),
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          letterSpacing: 1.0,
          fontWeight: FontWeight.w700,
          color: theme.colorScheme.outline,
        ),
      ),
    );
  }
}

/// A Recents / Starred row: icon, title, kind and (for recents) when.
class _QuickLinkRow extends StatelessWidget {
  const _QuickLinkRow({required this.link, required this.onTap, this.showTime = false, this.onUnstar});

  final QuickLink link;
  final VoidCallback onTap;
  final bool showTime;
  final VoidCallback? onUnstar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(_iconForLink(link), size: 18, color: scheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        link.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(link.kind, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              if (showTime && link.at != null)
                Padding(
                  padding: const EdgeInsets.only(left: 8, right: 4),
                  child: Text(timeAgo(link.at), style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline)),
                ),
              if (onUnstar != null)
                IconButton(
                  tooltip: 'Unstar',
                  visualDensity: VisualDensity.compact,
                  onPressed: onUnstar,
                  icon: const Icon(Icons.star_rounded, color: Color(0xFFF5B301), size: 20),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tile in the "More" sheet: a tinted icon square above its label.
class _MoreTile extends StatelessWidget {
  const _MoreTile({required this.label, required this.icon, required this.selected, required this.onTap});

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: dark ? 0.16 : 0.10)
          : (dark ? Colors.white.withValues(alpha: 0.04) : Colors.black.withValues(alpha: 0.03)),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: selected
              ? scheme.primary.withValues(alpha: 0.5)
              : (dark ? Colors.white.withValues(alpha: 0.07) : Colors.black.withValues(alpha: 0.06)),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  gradient: selected ? Brand.accent(theme.brightness) : null,
                  color: selected ? null : scheme.primary.withValues(alpha: dark ? 0.14 : 0.09),
                ),
                child: Icon(icon, size: 22, color: selected ? Colors.white : scheme.primary),
              ),
              const SizedBox(height: 9),
              Text(
                label,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                  color: selected ? scheme.primary : scheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SideNavTile extends StatefulWidget {
  const _SideNavTile({
    required this.item,
    required this.selected,
    required this.onTap,
    this.collapsed = false,
    this.starred = false,
    this.onStar,
    this.caption,
  });

  final _NavItem item;
  final bool selected;
  final bool collapsed;
  final VoidCallback onTap;

  /// With [onStar], a star shows on hover (always when [starred]).
  final bool starred;
  final VoidCallback? onStar;

  /// Small grey text after the label (e.g. "Dashboard").
  final String? caption;

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
    final fg = selected
        ? scheme.primary
        : (hover ? scheme.onSurface : scheme.onSurfaceVariant);
    // Active: tinted fill + accent bar. Hover: a faint neutral wash only.
    final bg = selected
        ? scheme.primary.withValues(alpha: dark ? 0.16 : 0.10)
        : (hover
              ? scheme.onSurface.withValues(alpha: dark ? 0.05 : 0.04)
              : Colors.transparent);
    final icon = Icon(
      selected ? widget.item.selectedIcon : widget.item.icon,
      size: 18,
      color: fg,
    );

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
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
          ),
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
                      borderRadius: const BorderRadius.horizontal(
                        right: Radius.circular(3),
                      ),
                    ),
                  ),
                ),
              Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: widget.collapsed ? 0 : 12,
                  ),
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
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                  color: selected
                                      ? scheme.primary
                                      : (hover
                                            ? scheme.onSurface
                                            : scheme.onSurface.withValues(
                                                alpha: 0.82,
                                              )),
                                ),
                              ),
                            ),
                            if (widget.caption != null && !_hover)
                              Text(
                                widget.caption!,
                                style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
                              ),
                            if (widget.onStar != null && (_hover || widget.starred))
                              InkResponse(
                                radius: 14,
                                onTap: widget.onStar,
                                child: Tooltip(
                                  message: widget.starred ? 'Unstar' : 'Star',
                                  child: Icon(
                                    widget.starred ? Icons.star_rounded : Icons.star_outline_rounded,
                                    size: 16,
                                    color: widget.starred ? const Color(0xFFF5B301) : scheme.outline,
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
    return widget.collapsed
        ? Tooltip(message: widget.item.label, preferBelow: false, child: tile)
        : tile;
  }
}

/// Small square icon button (sidebar collapse/expand). With [child], shows
/// the child and swaps to the icon on hover.
class _IconToggle extends StatefulWidget {
  const _IconToggle({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.child,
  });

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
              color: _hover
                  ? scheme.onSurface.withValues(alpha: 0.06)
                  : Colors.transparent,
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
    final name = (user?.displayName?.trim().isNotEmpty ?? false)
        ? user!.displayName!.trim()
        : email.split('@').first;
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
        style: TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 13,
          color: scheme.primary,
        ),
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
            color: _hover
                ? scheme.onSurface.withValues(alpha: 0.05)
                : Colors.transparent,
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
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (email.isNotEmpty)
                            Text(
                              email,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontSize: 11.5,
                              ),
                            ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.settings_outlined,
                      size: 16,
                      color: scheme.outline,
                    ),
                  ],
                ),
        ),
      ),
    );
    return widget.collapsed
        ? Tooltip(message: email.isEmpty ? 'Account' : email, child: tile)
        : tile;
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
          : const Padding(
              padding: EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              child: Divider(),
            );
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
  const _ProjectSwitcher({
    required this.current,
    this.compact = false,
    this.iconOnly = false,
  });

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
          MenuEntry(
            p.id,
            p.name,
            leading: _ProjectAvatar(p.name, size: 20),
            section: 'Projects',
          ),
        const MenuEntry('_new', 'New project…', icon: Icons.add_rounded),
        const MenuEntry('_all', 'All projects', icon: Icons.grid_view_rounded),
      ],
      builder: (context, open) => _switcherBody(context, scheme, open),
    );
  }

  Widget _switcherBody(BuildContext context, ColorScheme scheme, bool open) {
    return iconOnly
        ? SizedBox(
            height: 44,
            child: Center(child: _ProjectAvatar(current.name, size: 36)),
          )
        : Container(
            padding: EdgeInsets.fromLTRB(
              compact ? 4 : 8,
              compact ? 4 : 8,
              8,
              compact ? 4 : 8,
            ),
            decoration: BoxDecoration(
              color: compact
                  ? scheme.surface.withValues(alpha: 0.54)
                  : (open
                        ? scheme.primary.withValues(alpha: 0.08)
                        : scheme.surface.withValues(alpha: 0.30)),
              border: compact
                  ? Border.all(color: scheme.outlineVariant)
                  : Border.all(
                      color: open
                          ? scheme.primary.withValues(alpha: 0.35)
                          : scheme.outlineVariant,
                    ),
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
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: scheme.outline, fontSize: 10.5),
                        ),
                      Text(
                        current.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.unfold_more_rounded,
                  size: 18,
                  color: scheme.outline,
                ),
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
    final initial = name.trim().isEmpty
        ? '?'
        : name.trim().characters.first.toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: Brand.accent(Brightness.light),
        borderRadius: BorderRadius.circular(size * 0.3),
        boxShadow: [
          BoxShadow(
            color: Brand.indigo.withValues(alpha: 0.35),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Text(
        initial,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.45,
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
      message: error == null
          ? 'This project doesn’t exist, or you’re no longer a member.'
          : friendlyError(error!),
      action: FilledButton(
        onPressed: () => context.go('/projects'),
        child: const Text('Go to projects'),
      ),
    );
  }
}
