import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_menu.dart';
import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../data/flags.dart';
import '../../data/log_query.dart';
import '../../state/providers.dart';
import '../help/help_screen.dart' show HelpLink;

/// Feature flags: turn features on or off in your apps without a release,
/// roll them out to a percentage of people, or target people by property.
class FlagsScreen extends ConsumerWidget {
  const FlagsScreen({super.key, required this.projectId});

  final String projectId;

  Future<void> _edit(BuildContext context, WidgetRef ref, [FeatureFlag? flag]) async {
    final result = await showDialog<FeatureFlag>(
      context: context,
      builder: (_) => _FlagDialog(flag: flag),
    );
    if (result == null) return;
    final uid = ref.read(userProvider).value?.uid;
    if (uid == null) return;
    try {
      final repo = ref.read(flagsRepositoryProvider);
      if (flag == null && await repo.exists(projectId, result.key)) {
        if (context.mounted) showMessage(context, 'A flag called “${result.key}” already exists.', error: true);
        return;
      }
      await repo.save(projectId, result, uid: uid);
      if (context.mounted) showMessage(context, flag == null ? 'Flag created' : 'Flag saved');
    } catch (e) {
      if (context.mounted) showMessage(context, friendlyError(e), error: true);
    }
  }

  Future<void> _toggle(BuildContext context, WidgetRef ref, FeatureFlag f, bool on) async {
    final uid = ref.read(userProvider).value?.uid;
    if (uid == null) return;
    try {
      await ref.read(flagsRepositoryProvider).save(projectId, f.copyWith(enabled: on), uid: uid);
    } catch (e) {
      if (context.mounted) showMessage(context, friendlyError(e), error: true);
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, FeatureFlag f) async {
    final ok = await confirm(
      context,
      title: 'Delete “${f.key}”?',
      message: 'Apps asking for this flag will get their fallback value (usually off).',
      action: 'Delete',
      destructive: true,
    );
    if (ok) await ref.read(flagsRepositoryProvider).delete(projectId, f.key);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final flags = ref.watch(flagsProvider(projectId));
    final canEdit = ref.watch(myRoleProvider(projectId))?.canManageKeys ?? false;
    final list = flags.value ?? const <FeatureFlag>[];
    final on = list.where((f) => f.enabled).length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
      children: [
        Row(
          children: [
            Expanded(child: Text('Feature flags', style: theme.textTheme.headlineSmall)),
            HelpLink(projectId: projectId, topic: 'flags'),
            if (canEdit)
              FilledButton.icon(
                onPressed: () => _edit(context, ref),
                icon: const Icon(Icons.add_rounded),
                label: const Text('New flag'),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Turn features on or off in your apps without a release. Roll out to a share of people, '
          'or only to people with certain properties.',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        if (list.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('$on of ${list.length} on', style: theme.textTheme.labelLarge),
        ],
        const SizedBox(height: 12),
        flags.when(
          loading: () => const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => ErrorView(e),
          data: (flags) => flags.isEmpty
              ? GlassCard(
                  child: EmptyState(
                    icon: Icons.toggle_on_outlined,
                    title: 'No feature flags yet',
                    message: 'Example: “new-checkout” on for 20% of people, or only for plan = pro.',
                    action: canEdit
                        ? FilledButton.icon(
                            onPressed: () => _edit(context, ref),
                            icon: const Icon(Icons.add_rounded),
                            label: const Text('Create flag'),
                          )
                        : null,
                  ),
                )
              : Column(
                  children: [
                    for (final f in flags)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _FlagCard(
                          flag: f,
                          canEdit: canEdit,
                          onEdit: () => _edit(context, ref, f),
                          onToggle: (v) => _toggle(context, ref, f, v),
                          onDelete: () => _delete(context, ref, f),
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 20),
        const SectionLabel('Use in your app'),
        GlassCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'With the AppTrack logger (Flutter/Dart). Flags are loaded once and cached; '
                  'call reloadFeatureFlags() to refresh, e.g. when the app resumes.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 10),
                const CodeBlock(
                  '''await appTrack.reloadFeatureFlags();

if (appTrack.isFeatureEnabled('new-checkout')) {
  showNewCheckout();
}''',
                ),
                const SizedBox(height: 10),
                Text(
                  'Conditions are checked against the properties you pass to identify() and '
                  'setPersonProperties(). Flags are readable by your apps without signing in '
                  '(like PostHog’s public flag API), so don’t put secrets in them.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _FlagCard extends StatelessWidget {
  const _FlagCard({
    required this.flag,
    required this.canEdit,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
  });

  final FeatureFlag flag;
  final bool canEdit;
  final VoidCallback onEdit;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final f = flag;
    final n = f.conditions.length;
    final reach = !f.enabled
        ? 'Off for everyone'
        : n == 0
        ? '${f.rollout}% of everyone'
        : '${f.rollout}% of people matching $n condition${n == 1 ? '' : 's'}';
    return GlassCard(
      child: InkWell(
        onTap: canEdit ? onEdit : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: f.enabled ? const Color(0xFF22C55E) : scheme.outline,
                      boxShadow: f.enabled
                          ? [BoxShadow(color: const Color(0xFF22C55E).withValues(alpha: 0.5), blurRadius: 8)]
                          : null,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          f.key,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w700,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (f.name.trim().isNotEmpty || f.description.trim().isNotEmpty)
                          Text(
                            [f.name.trim(), f.description.trim()].where((s) => s.isNotEmpty).join(' · '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ),
                  Switch(value: f.enabled, onChanged: canEdit ? onToggle : null),
                  AppMenuAnchor<String>(
                    tooltip: 'More',
                    searchable: false,
                    minWidth: 180,
                    entries: () => [
                      const MenuEntry('copy', 'Copy key', icon: Icons.copy_rounded),
                      if (canEdit) const MenuEntry('edit', 'Edit', icon: Icons.edit_outlined),
                      if (canEdit) const MenuEntry('delete', 'Delete', icon: Icons.delete_outline, destructive: true),
                    ],
                    onSelected: (v) {
                      switch (v) {
                        case 'copy':
                          copyToClipboard(context, f.key, what: 'Flag key copied');
                        case 'edit':
                          onEdit();
                        default:
                          onDelete();
                      }
                    },
                    builder: (context, open) => const Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(Icons.more_vert_rounded, size: 20),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: f.enabled ? f.rollout / 100 : 0,
                    minHeight: 6,
                    backgroundColor: scheme.onSurface.withValues(alpha: 0.08),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(reach, style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
              if (f.conditions.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final c in f.conditions)
                      Chip(
                        label: Text(c.label, style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
              ],
              if (f.updatedAt != null) ...[
                const SizedBox(height: 6),
                Text(
                  'Updated ${timeAgo(f.updatedAt)}',
                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A copyable code sample.
class CodeBlock extends StatelessWidget {
  const CodeBlock(this.code, {super.key});
  final String code;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SelectableText(code, style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.45)),
          ),
          IconButton(
            tooltip: 'Copy',
            visualDensity: VisualDensity.compact,
            onPressed: () => copyToClipboard(context, code),
            icon: const Icon(Icons.copy_rounded, size: 18),
          ),
        ],
      ),
    );
  }
}

/// Create or edit a flag.
class _FlagDialog extends StatefulWidget {
  const _FlagDialog({this.flag});

  final FeatureFlag? flag;

  @override
  State<_FlagDialog> createState() => _FlagDialogState();
}

class _FlagDialogState extends State<_FlagDialog> {
  late final _key = TextEditingController(text: widget.flag?.key ?? '');
  late final _name = TextEditingController(text: widget.flag?.name ?? '');
  late final _desc = TextEditingController(text: widget.flag?.description ?? '');
  late bool _enabled = widget.flag?.enabled ?? true;
  late double _rollout = (widget.flag?.rollout ?? 100).toDouble();
  late final List<_CondRow> _conds = [
    for (final c in widget.flag?.conditions ?? const <FlagCondition>[]) _CondRow.from(c),
  ];
  final _testId = TextEditingController();
  final _testProps = TextEditingController();
  String? _keyError;

  bool get _isNew => widget.flag == null;

  @override
  void dispose() {
    for (final c in [_key, _name, _desc, _testId, _testProps]) {
      c.dispose();
    }
    for (final r in _conds) {
      r.dispose();
    }
    super.dispose();
  }

  FeatureFlag _build() => FeatureFlag(
    key: _key.text.trim(),
    name: _name.text,
    description: _desc.text,
    enabled: _enabled,
    rollout: _rollout.round(),
    conditions: [
      for (final r in _conds)
        if (r.property.text.trim().isNotEmpty) FlagCondition(r.property.text.trim(), r.op, r.value.text.trim()),
    ],
  );

  void _submit() {
    final key = _key.text.trim();
    if (!FeatureFlag.keyPattern.hasMatch(key)) {
      setState(() => _keyError = 'Lowercase letters, numbers, - and _ (max 64), e.g. new-checkout');
      return;
    }
    Navigator.pop(context, _build());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final flag = _build();
    final testId = _testId.text.trim();
    final bucket = testId.isEmpty || flag.key.isEmpty ? null : rolloutBucket(flag.key, testId);
    final testOn = testId.isEmpty ? null : flag.isEnabledFor(testId, parseTestProperties(_testProps.text));

    final form = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _key,
          enabled: _isNew,
          autofocus: _isNew && !isMobileLayout(context),
          style: const TextStyle(fontFamily: 'monospace'),
          decoration: InputDecoration(
            labelText: 'Key',
            hintText: 'new-checkout',
            errorText: _keyError,
            helperText: _isNew ? 'What your app asks for. Can’t be changed later.' : null,
          ),
          onChanged: (_) => setState(() => _keyError = null),
        ),
        const SizedBox(height: 12),
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name (optional)')),
        const SizedBox(height: 12),
        TextField(
          controller: _desc,
          maxLines: 2,
          decoration: const InputDecoration(labelText: 'Description (optional)'),
        ),
        const SizedBox(height: 12),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Enabled'),
          subtitle: const Text('Off means off for everyone'),
          value: _enabled,
          onChanged: (v) => setState(() => _enabled = v),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text('Rollout', style: theme.textTheme.titleSmall),
            const Spacer(),
            Text('${_rollout.round()}%', style: theme.textTheme.titleSmall?.copyWith(color: scheme.primary)),
          ],
        ),
        Slider(
          value: _rollout,
          max: 100,
          divisions: 20,
          label: '${_rollout.round()}%',
          onChanged: (v) => setState(() => _rollout = v),
        ),
        Text(
          _conds.isEmpty ? 'Share of everyone who gets the flag.' : 'Share of matching people who get the flag.',
          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Text('Conditions', style: theme.textTheme.titleSmall),
            const Spacer(),
            TextButton.icon(
              onPressed: _conds.length >= 10 ? null : () => setState(() => _conds.add(_CondRow())),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add'),
            ),
          ],
        ),
        if (_conds.isEmpty)
          Text(
            'None: everyone can get the flag. Add one to target e.g. plan = pro or app_version > 2.',
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        for (var i = 0; i < _conds.length; i++)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _CondEditor(
              key: ObjectKey(_conds[i]),
              row: _conds[i],
              onChanged: () => setState(() {}),
              onRemove: () => setState(() => _conds.removeAt(i).dispose()),
            ),
          ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: scheme.primary.withValues(alpha: 0.06),
            border: Border.all(color: scheme.primary.withValues(alpha: 0.25)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Test a person', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              TextField(
                controller: _testId,
                decoration: const InputDecoration(labelText: 'Distinct ID or user ID', isDense: true),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _testProps,
                decoration: const InputDecoration(
                  labelText: 'Properties (optional)',
                  hintText: 'plan=pro, country=PK',
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
              if (testOn != null) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(
                      testOn ? Icons.check_circle_rounded : Icons.cancel_rounded,
                      color: testOn ? const Color(0xFF22C55E) : scheme.error,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${testOn ? 'On' : 'Off'} for this person'
                        '${bucket == null ? '' : ' (rollout bucket $bucket of 100)'}',
                        style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );

    final title = Text(_isNew ? 'New feature flag' : 'Edit ${widget.flag!.key}');
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
                child: FilledButton(onPressed: _submit, child: Text(_isNew ? 'Create' : 'Save')),
              ),
            ],
          ),
          body: SafeArea(
            child: ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 24), children: [form]),
          ),
        ),
      );
    }
    return AlertDialog(
      title: title,
      content: SizedBox(width: 480, child: SingleChildScrollView(child: form)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: Text(_isNew ? 'Create flag' : 'Save')),
      ],
    );
  }
}

/// "plan=pro, country=PK" → {plan: pro, country: PK}; numbers and
/// true/false are converted.
Map<String, Object?> parseTestProperties(String s) {
  final out = <String, Object?>{};
  for (final part in s.split(RegExp(r'[,\n]'))) {
    final i = part.indexOf('=');
    if (i <= 0) continue;
    final k = part.substring(0, i).trim();
    final v = part.substring(i + 1).trim();
    if (k.isEmpty) continue;
    out[k] = num.tryParse(v) ?? (v == 'true' ? true : (v == 'false' ? false : v));
  }
  return out;
}

class _CondRow {
  _CondRow() : property = TextEditingController(), value = TextEditingController();

  _CondRow.from(FlagCondition c)
    : property = TextEditingController(text: c.property),
      value = TextEditingController(text: c.value),
      op = c.op;

  final TextEditingController property;
  final TextEditingController value;
  FilterOp op = FilterOp.equals;

  void dispose() {
    property.dispose();
    value.dispose();
  }
}

class _CondEditor extends StatelessWidget {
  const _CondEditor({super.key, required this.row, required this.onChanged, required this.onRemove});

  final _CondRow row;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 520;
    final prop = TextField(
      controller: row.property,
      style: const TextStyle(fontFamily: 'monospace'),
      decoration: const InputDecoration(labelText: 'Property', hintText: 'plan', isDense: true),
      onChanged: (_) => onChanged(),
    );
    final op = AppSelectField<FilterOp>(
      label: 'Operator',
      value: row.op,
      entries: [for (final o in FlagCondition.ops) MenuEntry(o, o.label)],
      onChanged: (v) {
        row.op = v;
        onChanged();
      },
    );
    final value = TextField(
      controller: row.value,
      enabled: row.op.needsValue,
      decoration: const InputDecoration(labelText: 'Value', hintText: 'pro', isDense: true),
      onChanged: (_) => onChanged(),
    );
    final remove = IconButton(
      tooltip: 'Remove condition',
      onPressed: onRemove,
      icon: const Icon(Icons.remove_circle_outline_rounded),
    );
    if (narrow) {
      return Container(
        padding: const EdgeInsets.fromLTRB(10, 10, 4, 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(children: [prop, const SizedBox(height: 8), op, const SizedBox(height: 8), value]),
            ),
            remove,
          ],
        ),
      );
    }
    return Row(
      children: [
        Expanded(flex: 4, child: prop),
        const SizedBox(width: 8),
        Expanded(flex: 4, child: op),
        const SizedBox(width: 8),
        Expanded(flex: 4, child: value),
        remove,
      ],
    );
  }
}
