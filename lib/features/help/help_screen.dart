import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/glass.dart';
import '../../core/severity.dart';
import '../../core/theme.dart';
import '../flags/flags_screen.dart' show CodeBlock;
import 'help_content_app.dart';
import 'help_content_sdk.dart';
import 'help_model.dart';

/// Every help topic, in display order.
final List<HelpTopic> helpTopics = [
  for (final c in HelpCategory.values) ...[...sdkTopics, ...appTopics].where((t) => t.category == c),
];

HelpTopic? helpTopic(String? id) => helpTopics.where((t) => t.id == id).firstOrNull;

String helpPath(String pid, [String? topic]) =>
    Uri(path: '/p/$pid/help', queryParameters: topic == null ? null : {'topic': topic}).toString();

/// A small "?" button that opens a help topic.
class HelpLink extends StatelessWidget {
  const HelpLink({super.key, required this.projectId, required this.topic});

  final String projectId;
  final String topic;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Help: ${helpTopic(topic)?.title ?? 'Help'}',
    onPressed: () => context.go(helpPath(projectId, topic)),
    icon: const Icon(Icons.help_outline_rounded),
  );
}

/// Help & docs: how to use every page and every SDK feature.
class HelpScreen extends StatefulWidget {
  const HelpScreen({super.key, required this.projectId, this.topicId});

  final String projectId;
  final String? topicId;

  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  final _search = TextEditingController();
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(HelpScreen old) {
    super.didUpdateWidget(old);
    if (old.topicId != widget.topicId && _scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _open(HelpTopic t) => context.go(helpPath(widget.projectId, t.id));

  String get _firebaseProjectId {
    try {
      return Firebase.app().options.projectId;
    } catch (_) {
      return 'YOUR_FIREBASE_PROJECT_ID';
    }
  }

  /// Fills in this project's IDs.
  String _fill(String s) =>
      s.replaceAll('{{PROJECT_ID}}', widget.projectId).replaceAll('{{FIREBASE_PROJECT_ID}}', _firebaseProjectId);

  @override
  Widget build(BuildContext context) {
    final topic = helpTopic(widget.topicId);
    if (isWide(context)) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 310,
            child: _TopicList(
              search: _search,
              selected: topic?.id ?? 'start',
              onOpen: _open,
              onSearch: () => setState(() {}),
              compactHeader: true,
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: _TopicView(
              topic: topic ?? helpTopic('start')!,
              fill: _fill,
              scroll: _scroll,
              onOpen: _open,
            ),
          ),
        ],
      );
    }
    if (topic == null) {
      return _TopicList(
        search: _search,
        selected: null,
        onOpen: _open,
        onSearch: () => setState(() {}),
      );
    }
    return _TopicView(
      topic: topic,
      fill: _fill,
      scroll: _scroll,
      onOpen: _open,
      onBack: () => context.go(helpPath(widget.projectId)),
    );
  }
}

class _TopicList extends StatelessWidget {
  const _TopicList({
    required this.search,
    required this.selected,
    required this.onOpen,
    required this.onSearch,
    this.compactHeader = false,
  });

  final TextEditingController search;
  final String? selected;
  final ValueChanged<HelpTopic> onOpen;
  final VoidCallback onSearch;
  final bool compactHeader;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = search.text.trim();
    final results = q.isEmpty
        ? null
        : (helpTopics.map((t) => (t, t.score(q))).where((r) => r.$2 > 0).toList()
            ..sort((a, b) => b.$2.compareTo(a.$2)));
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
      children: [
        Text('Help', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          compactHeader
              ? 'How every page works and what your apps can send.'
              : 'How every page works, what your apps can send (with every field and limit), and copy-ready examples.',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: search,
          onChanged: (_) => onSearch(),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search_rounded),
            hintText: 'Search help, e.g. reason, stack trace, rollout',
            isDense: true,
            suffixIcon: q.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear',
                    onPressed: () {
                      search.clear();
                      onSearch();
                    },
                    icon: const Icon(Icons.close_rounded),
                  ),
          ),
        ),
        const SizedBox(height: 16),
        if (results != null) ...[
          if (results.isEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text('Nothing found for “$q”.', style: TextStyle(color: theme.colorScheme.outline)),
            ),
          for (final r in results) _TopicTile(topic: r.$1, selected: r.$1.id == selected, onTap: () => onOpen(r.$1)),
        ] else
          for (final c in HelpCategory.values) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 10, 6, 6),
              child: Text(
                c.label.toUpperCase(),
                style: theme.textTheme.labelSmall?.copyWith(
                  letterSpacing: 1,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
            for (final t in helpTopics.where((t) => t.category == c))
              _TopicTile(topic: t, selected: t.id == selected, onTap: () => onOpen(t)),
          ],
      ],
    );
  }
}

class _TopicTile extends StatelessWidget {
  const _TopicTile({required this.topic, required this.selected, required this.onTap});

  final HelpTopic topic;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected ? scheme.primary.withValues(alpha: 0.12) : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: selected ? 0.22 : 0.12),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(topic.icon, size: 19, color: scheme.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        topic.title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: selected ? scheme.primary : null,
                        ),
                      ),
                      Text(
                        topic.summary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: scheme.outline),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TopicView extends StatelessWidget {
  const _TopicView({required this.topic, required this.fill, required this.scroll, required this.onOpen, this.onBack});

  final HelpTopic topic;
  final String Function(String) fill;
  final ScrollController scroll;
  final ValueChanged<HelpTopic> onOpen;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final related = topic.related.map(helpTopic).whereType<HelpTopic>().toList();
    return ListView(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (onBack != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: onBack,
                      icon: const Icon(Icons.arrow_back_rounded, size: 18),
                      label: const Text('All help'),
                    ),
                  ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        gradient: Brand.accent(theme.brightness),
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: Icon(topic.icon, color: Colors.white),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            topic.category.label.toUpperCase(),
                            style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1, color: scheme.outline),
                          ),
                          Text(topic.title, style: theme.textTheme.headlineSmall),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(topic.summary, style: theme.textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 18),
                for (final b in topic.blocks) ...[_Block(block: b, fill: fill), const SizedBox(height: 14)],
                if (related.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('Related', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final r in related)
                        ActionChip(
                          avatar: Icon(r.icon, size: 16),
                          label: Text(r.title),
                          onPressed: () => onOpen(r),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({required this.block, required this.fill});

  final HelpBlock block;
  final String Function(String) fill;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final body = theme.textTheme.bodyMedium?.copyWith(height: 1.5);
    switch (block) {
      case HHeading(:final text):
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(fill(text), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        );
      case HText(:final text):
        return RichHelpText(fill(text), style: body);
      case HBullets(:final items):
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final i in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 8, right: 10, left: 2),
                      child: Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
                      ),
                    ),
                    Expanded(child: RichHelpText(fill(i), style: body)),
                  ],
                ),
              ),
          ],
        );
      case HSteps(:final items):
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < items.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 24,
                      height: 24,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(gradient: Brand.accent(theme.brightness), shape: BoxShape.circle),
                      child: Text(
                        '${i + 1}',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: RichHelpText(fill(items[i]), style: body)),
                  ],
                ),
              ),
          ],
        );
      case HCode(:final code, :final title):
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6, left: 2),
                child: Text(title, style: theme.textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
              ),
            CodeBlock(fill(code)),
          ],
        );
      case HTip(:final text, :final kind):
        final c = kind == TipKind.warning ? Severity.warn.color : scheme.primary;
        return Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
          decoration: BoxDecoration(
            color: c.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.withValues(alpha: 0.35)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                kind == TipKind.warning ? Icons.warning_amber_rounded : Icons.lightbulb_outline_rounded,
                size: 20,
                color: c,
              ),
              const SizedBox(width: 10),
              Expanded(child: RichHelpText(fill(text), style: body)),
            ],
          ),
        );
      case HFields(:final fields, :final title):
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8, left: 2),
                child: Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              ),
            GlassCard(
              child: Column(
                children: [
                  for (var i = 0; i < fields.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    _FieldRow(field: fields[i], fill: fill),
                  ],
                ],
              ),
            ),
          ],
        );
    }
  }
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.field, required this.fill});

  final HField field;
  final String Function(String) fill;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final f = field;
    Widget badge(String text, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(6)),
      child: Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SelectableText(
                f.name,
                style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w700, fontSize: 13.5),
              ),
              Text(f.type, style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: scheme.primary)),
              if (f.required) badge('required', Severity.error.color),
              if (f.defaultValue != null) badge('default ${f.defaultValue}', scheme.onSurfaceVariant),
              if (f.limit != null) badge('max ${f.limit}', Severity.warn.color),
            ],
          ),
          const SizedBox(height: 4),
          RichHelpText(fill(f.description), style: theme.textTheme.bodySmall?.copyWith(height: 1.45)),
        ],
      ),
    );
  }
}

/// Text with **bold** and `code` spans.
class RichHelpText extends StatelessWidget {
  const RichHelpText(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  static final _token = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _token.allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      if (m.group(1) != null) {
        spans.add(TextSpan(text: m.group(1), style: const TextStyle(fontWeight: FontWeight.w700)));
      } else {
        spans.add(
          TextSpan(
            text: m.group(2),
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: (style?.fontSize ?? 14) * 0.92,
              color: scheme.primary,
              backgroundColor: scheme.primary.withValues(alpha: 0.08),
            ),
          ),
        );
      }
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return Text.rich(TextSpan(children: spans), style: style);
  }
}
