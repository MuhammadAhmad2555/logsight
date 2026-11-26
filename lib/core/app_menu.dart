import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// One row in an [showAppMenu] list.
class MenuEntry<T> {
  const MenuEntry(
    this.value,
    this.label, {
    this.icon,
    this.leading,
    this.trailing,
    this.section,
    this.mono = false,
    this.enabled = true,
    this.destructive = false,
    this.action,
  });

  final T value;
  final String label;
  final IconData? icon;

  /// Custom leading widget (e.g. a colour dot); wins over [icon].
  final Widget? leading;

  /// Small muted text on the right (e.g. a count).
  final String? trailing;

  /// Rows with the same section are grouped under this heading.
  final String? section;
  final bool mono;
  final bool enabled;
  final bool destructive;

  /// Optional small icon button at the end of the row (e.g. delete).
  final MenuRowAction? action;
}

class MenuRowAction {
  const MenuRowAction(this.icon, this.tooltip, this.onPressed);
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
}

/// Opens LogSight's dropdown below the widget that owns [context]:
/// compact rows, optional search, sections, checkmarks, its own scrolling,
/// keyboard navigation (↑ ↓ Enter Esc) and an opaque glass surface.
///
/// - Single select: returns the picked value (null if dismissed).
/// - [multi]: stays open; each tap calls [onToggle]. Returns null.
/// - [onCustom]: when searching, offers "Use “query”" and returns
///   `onCustom(query)`.
Future<T?> showAppMenu<T>(
  BuildContext context, {
  required List<MenuEntry<T>> entries,
  Set<T> selected = const {},
  bool? searchable,
  String searchHint = 'Search',
  double? width,
  double minWidth = 200,
  double maxHeight = 380,
  bool multi = false,
  ValueChanged<T>? onToggle,
  T Function(String query)? onCustom,
  String customLabel = 'Use',
  bool showChecks = true,
}) {
  final box = context.findRenderObject() as RenderBox;
  final overlay = Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
  final anchor = Rect.fromPoints(
    box.localToGlobal(Offset.zero, ancestor: overlay),
    box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
  );
  return Navigator.of(context).push<T>(
    _AppMenuRoute<T>(
      anchor: anchor,
      width: width ?? math.max(minWidth, anchor.width),
      maxHeight: maxHeight,
      capturedThemes: InheritedTheme.capture(from: context, to: Navigator.of(context).context),
      panel: _AppMenuPanel<T>(
        entries: entries,
        selected: selected,
        searchable: searchable ?? entries.length > 8,
        searchHint: searchHint,
        multi: multi,
        onToggle: onToggle,
        onCustom: onCustom,
        customLabel: customLabel,
        showChecks: showChecks,
      ),
    ),
  );
}

class _AppMenuRoute<T> extends PopupRoute<T> {
  _AppMenuRoute({
    required this.anchor,
    required this.width,
    required this.maxHeight,
    required this.panel,
    required this.capturedThemes,
  });

  final Rect anchor;
  final double width;
  final double maxHeight;
  final Widget panel;
  final CapturedThemes capturedThemes;

  @override
  Color? get barrierColor => Colors.transparent;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Dismiss menu';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 140);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 90);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    return capturedThemes.wrap(
      LayoutBuilder(
        builder: (context, c) {
          final pad = MediaQuery.paddingOf(context);
          const gap = 6.0;
          const margin = 8.0;
          final below = c.maxHeight - anchor.bottom - pad.bottom - margin - gap;
          final above = anchor.top - pad.top - margin - gap;
          final openUp = below < 220 && above > below;
          final h = math.min(maxHeight, math.max(120.0, openUp ? above : below));
          final w = math.min(width, c.maxWidth - margin * 2);
          final left = anchor.left.clamp(margin, math.max(margin, c.maxWidth - w - margin)).toDouble();
          return Stack(
            children: [
              Positioned(
                left: left,
                width: w,
                top: openUp ? null : anchor.bottom + gap,
                bottom: openUp ? c.maxHeight - anchor.top + gap : null,
                child: FadeTransition(
                  opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
                  child: ScaleTransition(
                    alignment: openUp ? Alignment.bottomCenter : Alignment.topCenter,
                    scale: Tween(
                      begin: 0.97,
                      end: 1.0,
                    ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: h),
                      child: panel,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The menu surface: opaque frosted glass with a hairline border.
class MenuSurface extends StatelessWidget {
  const MenuSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final r = BorderRadius.circular(14);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.55 : 0.16),
            blurRadius: 32,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            decoration: BoxDecoration(
              color: dark ? const Color(0xF01A1C36) : const Color(0xF5FFFFFF),
              borderRadius: r,
              border: Border.all(
                color: dark ? Colors.white.withValues(alpha: 0.12) : const Color(0xFF151833).withValues(alpha: 0.10),
              ),
            ),
            child: Material(type: MaterialType.transparency, child: child),
          ),
        ),
      ),
    );
  }
}

class _AppMenuPanel<T> extends StatefulWidget {
  const _AppMenuPanel({
    required this.entries,
    required this.selected,
    required this.searchable,
    required this.searchHint,
    required this.multi,
    required this.onToggle,
    required this.onCustom,
    required this.customLabel,
    required this.showChecks,
  });

  final List<MenuEntry<T>> entries;
  final Set<T> selected;
  final bool searchable;
  final String searchHint;
  final bool multi;
  final ValueChanged<T>? onToggle;
  final T Function(String query)? onCustom;
  final String customLabel;
  final bool showChecks;

  @override
  State<_AppMenuPanel<T>> createState() => _AppMenuPanelState<T>();
}

class _AppMenuPanelState<T> extends State<_AppMenuPanel<T>> {
  final _query = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  late final Set<T> _selected = {...widget.selected};
  int _highlight = -1;

  static const _rowHeight = 34.0;

  @override
  void initState() {
    super.initState();
    // Start on the selected row so Enter keeps the current choice.
    final i = widget.entries.indexWhere((e) => _selected.contains(e.value));
    _highlight = i;
  }

  @override
  void dispose() {
    _query.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<MenuEntry<T>> get _visible {
    final q = _query.text.trim().toLowerCase();
    if (q.isEmpty) return widget.entries;
    return widget.entries.where((e) => e.label.toLowerCase().contains(q)).toList();
  }

  bool get _showCustom {
    final q = _query.text.trim();
    return widget.onCustom != null && q.isNotEmpty && !widget.entries.any((e) => e.label == q);
  }

  void _pick(MenuEntry<T> e) {
    if (!e.enabled) return;
    if (widget.multi) {
      setState(() => _selected.contains(e.value) ? _selected.remove(e.value) : _selected.add(e.value));
      widget.onToggle?.call(e.value);
      return;
    }
    Navigator.of(context).pop(e.value);
  }

  void _pickCustom() => Navigator.of(context).pop(widget.onCustom!(_query.text.trim()));

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final rows = _visible;
    final count = rows.length + (_showCustom ? 1 : 0);
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() => _highlight = count == 0 ? -1 : (_highlight + 1) % count);
      _reveal();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() => _highlight = count == 0 ? -1 : (_highlight - 1 + count) % count);
      _reveal();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (_highlight >= 0 && _highlight < rows.length) {
        _pick(rows[_highlight]);
      } else if (_showCustom) {
        _pickCustom();
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _reveal() {
    if (!_scroll.hasClients || _highlight < 0) return;
    // Approximate: rows are fixed height; section headers add a little.
    final target = _highlight * _rowHeight;
    final pos = _scroll.position;
    if (target < pos.pixels) {
      _scroll.jumpTo(target);
    } else if (target + _rowHeight > pos.pixels + pos.viewportDimension) {
      _scroll.jumpTo(math.min(pos.maxScrollExtent, target + _rowHeight - pos.viewportDimension + 8));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rows = _visible;

    final children = <Widget>[];
    String? section;
    for (var i = 0; i < rows.length; i++) {
      final e = rows[i];
      if (e.section != section) {
        section = e.section;
        if (section != null) {
          children.add(_SectionHeader(section, first: children.isEmpty));
        } else if (children.isNotEmpty) {
          children.add(const _MenuDivider());
        }
      }
      children.add(
        _MenuRow<T>(
          entry: e,
          checked: _selected.contains(e.value),
          showCheck: widget.showChecks,
          highlighted: i == _highlight,
          onHover: () => setState(() => _highlight = i),
          onTap: () => _pick(e),
        ),
      );
    }
    if (_showCustom) {
      final i = rows.length;
      children.add(
        _MenuRow<T>(
          entry: MenuEntry<T>(
            widget.onCustom!(_query.text.trim()),
            '${widget.customLabel} “${_query.text.trim()}”',
            icon: Icons.keyboard_return_rounded,
          ),
          checked: false,
          showCheck: widget.showChecks,
          highlighted: i == _highlight,
          onHover: () => setState(() => _highlight = i),
          onTap: _pickCustom,
        ),
      );
    }

    return Focus(
      autofocus: !widget.searchable,
      onKeyEvent: _onKey,
      child: MenuSurface(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.searchable)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                child: SizedBox(
                  height: 34,
                  child: TextField(
                    controller: _query,
                    focusNode: _focus,
                    autofocus: true,
                    style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13.5),
                    onChanged: (_) => setState(() => _highlight = 0),
                    decoration: InputDecoration(
                      hintText: widget.searchHint,
                      prefixIcon: const Icon(Icons.search_rounded, size: 17),
                      prefixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(9),
                        borderSide: BorderSide(color: scheme.outlineVariant),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(9),
                        borderSide: BorderSide(color: scheme.outlineVariant),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(9),
                        borderSide: BorderSide(color: scheme.primary.withValues(alpha: 0.7)),
                      ),
                    ),
                  ),
                ),
              ),
            Flexible(
              child: children.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('No matches', textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
                    )
                  : Scrollbar(
                      controller: _scroll,
                      child: ListView(
                        controller: _scroll,
                        shrinkWrap: true,
                        padding: const EdgeInsets.all(5),
                        children: children,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label, {required this.first});

  final String label;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(10, first ? 6 : 12, 10, 4),
      child: Text(
        label.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          fontSize: 10.5,
          letterSpacing: 0.9,
          fontWeight: FontWeight.w700,
          color: theme.colorScheme.outline,
        ),
      ),
    );
  }
}

class _MenuDivider extends StatelessWidget {
  const _MenuDivider();

  @override
  Widget build(BuildContext context) =>
      const Padding(padding: EdgeInsets.symmetric(horizontal: 6, vertical: 5), child: Divider(height: 1));
}

class _MenuRow<T> extends StatelessWidget {
  const _MenuRow({
    required this.entry,
    required this.checked,
    required this.showCheck,
    required this.highlighted,
    required this.onHover,
    required this.onTap,
  });

  final MenuEntry<T> entry;
  final bool checked;
  final bool showCheck;
  final bool highlighted;
  final VoidCallback onHover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final e = entry;
    final fg = !e.enabled
        ? scheme.onSurface.withValues(alpha: 0.38)
        : e.destructive
        ? scheme.error
        : (checked ? scheme.primary : scheme.onSurface);
    final style = (e.mono ? monoStyle.copyWith(fontSize: 12.5) : theme.textTheme.bodyMedium?.copyWith(fontSize: 13.5))
        ?.copyWith(color: fg, fontWeight: checked ? FontWeight.w600 : FontWeight.w500);
    final leading = e.leading ?? (e.icon == null ? null : Icon(e.icon, size: 16, color: fg));
    return MouseRegion(
      cursor: e.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => onHover(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: e.enabled ? onTap : null,
        child: Container(
          height: _AppMenuPanelState._rowHeight,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: highlighted && e.enabled
                ? scheme.primary.withValues(alpha: theme.brightness == Brightness.dark ? 0.16 : 0.09)
                : null,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              if (showCheck)
                SizedBox(width: 22, child: checked ? Icon(Icons.check_rounded, size: 16, color: scheme.primary) : null),
              if (leading != null) ...[leading, const SizedBox(width: 9)],
              Expanded(
                child: Text(e.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
              ),
              if (e.trailing != null) ...[
                const SizedBox(width: 8),
                Text(e.trailing!, style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline)),
              ],
              if (e.action != null)
                Tooltip(
                  message: e.action!.tooltip,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: e.action!.onPressed,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(e.action!.icon, size: 15, color: scheme.outline),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Any widget that opens an [showAppMenu] when tapped. [builder] gets
/// whether the menu is open (for a pressed look).
class AppMenuAnchor<T> extends StatefulWidget {
  const AppMenuAnchor({
    super.key,
    required this.entries,
    required this.builder,
    this.onSelected,
    this.selected = const {},
    this.searchable,
    this.searchHint = 'Search',
    this.width,
    this.minWidth = 200,
    this.maxHeight = 380,
    this.multi = false,
    this.onToggle,
    this.onCustom,
    this.customLabel = 'Use',
    this.showChecks = true,
    this.tooltip,
  });

  /// Built lazily so menus always show fresh data.
  final List<MenuEntry<T>> Function() entries;
  final Widget Function(BuildContext context, bool open) builder;
  final ValueChanged<T>? onSelected;
  final Set<T> selected;
  final bool? searchable;
  final String searchHint;
  final double? width;
  final double minWidth;
  final double maxHeight;
  final bool multi;
  final ValueChanged<T>? onToggle;
  final T Function(String query)? onCustom;
  final String customLabel;
  final bool showChecks;
  final String? tooltip;

  @override
  State<AppMenuAnchor<T>> createState() => _AppMenuAnchorState<T>();
}

class _AppMenuAnchorState<T> extends State<AppMenuAnchor<T>> {
  bool _open = false;

  Future<void> _show() async {
    // Keep the callback: if the page rebuilds this button while the menu is
    // open (e.g. the keyboard changes the layout), the choice still counts.
    final onSelected = widget.onSelected;
    setState(() => _open = true);
    final v = await showAppMenu<T>(
      context,
      entries: widget.entries(),
      selected: widget.selected,
      searchable: widget.searchable,
      searchHint: widget.searchHint,
      width: widget.width,
      minWidth: widget.minWidth,
      maxHeight: widget.maxHeight,
      multi: widget.multi,
      onToggle: widget.onToggle,
      onCustom: widget.onCustom,
      customLabel: widget.customLabel,
      showChecks: widget.showChecks,
    );
    if (mounted) setState(() => _open = false);
    if (v == null) return;
    if (mounted) {
      widget.onSelected?.call(v);
    } else {
      // Most callbacks only update the page's state, which still exists. One
      // that needs this button's own context (gone now) can't run; skip it.
      try {
        onSelected?.call(v);
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final child = MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: _show, child: widget.builder(context, _open)),
    );
    return widget.tooltip == null || _open ? child : Tooltip(message: widget.tooltip, child: child);
  }
}

/// A toolbar pill that opens a menu: icon, label, chevron.
class MenuPill extends StatefulWidget {
  const MenuPill({
    super.key,
    required this.label,
    this.icon,
    this.leading,
    this.active = false,
    this.open = false,
    this.mono = false,
    this.maxLabelWidth = 220,
  });

  final String label;
  final IconData? icon;
  final Widget? leading;

  /// A non-default value is chosen (tinted).
  final bool active;
  final bool open;
  final bool mono;
  final double maxLabelWidth;

  @override
  State<MenuPill> createState() => _MenuPillState();
}

class _MenuPillState extends State<MenuPill> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final tint = widget.active || widget.open;
    final bg = tint
        ? scheme.primary.withValues(alpha: dark ? 0.16 : 0.09)
        : (dark
              ? Colors.white.withValues(alpha: _hover ? 0.08 : 0.05)
              : Colors.white.withValues(alpha: _hover ? 0.95 : 0.72));
    final border = tint
        ? scheme.primary.withValues(alpha: dark ? 0.40 : 0.30)
        : (_hover
              ? (dark ? Colors.white.withValues(alpha: 0.18) : const Color(0xFF151833).withValues(alpha: 0.18))
              : scheme.outlineVariant);
    final fg = tint ? scheme.primary : scheme.onSurface;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: 36,
        padding: const EdgeInsets.only(left: 10, right: 6),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.leading != null) ...[widget.leading!, const SizedBox(width: 7)],
            if (widget.leading == null && widget.icon != null) ...[
              Icon(widget.icon, size: 16, color: tint ? scheme.primary : scheme.onSurfaceVariant),
              const SizedBox(width: 7),
            ],
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: widget.maxLabelWidth),
              child: Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    (widget.mono
                            ? monoStyle.copyWith(fontSize: 12.5)
                            : theme.textTheme.labelLarge?.copyWith(fontSize: 13))
                        ?.copyWith(color: fg, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 2),
            AnimatedRotation(
              turns: widget.open ? 0.5 : 0,
              duration: const Duration(milliseconds: 150),
              child: Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: tint ? scheme.primary : scheme.outline),
            ),
          ],
        ),
      ),
    );
  }
}

/// A form field (with label) that opens an [showAppMenu]: replaces
/// DropdownButtonFormField, whose menu broke over glass dialogs.
class AppSelectField<T> extends StatelessWidget {
  const AppSelectField({
    super.key,
    required this.label,
    required this.value,
    required this.entries,
    required this.onChanged,
    this.searchable,
  });

  final String label;
  final T value;
  final List<MenuEntry<T>> entries;
  final ValueChanged<T> onChanged;
  final bool? searchable;

  @override
  Widget build(BuildContext context) {
    final current = entries.where((e) => e.value == value).firstOrNull;
    return AppMenuAnchor<T>(
      entries: () => entries,
      selected: {value},
      searchable: searchable,
      onSelected: onChanged,
      builder: (context, open) => InputDecorator(
        isFocused: open,
        isEmpty: false,
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: AnimatedRotation(
            turns: open ? 0.5 : 0,
            duration: const Duration(milliseconds: 150),
            child: const Icon(Icons.keyboard_arrow_down_rounded, size: 20),
          ),
        ),
        child: Row(
          children: [
            if (current?.leading != null) ...[current!.leading!, const SizedBox(width: 8)],
            Expanded(
              child: Text(
                current?.label ?? '$value',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
