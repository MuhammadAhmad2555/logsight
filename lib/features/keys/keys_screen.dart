import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import 'setup_snippets.dart';

class KeysScreen extends ConsumerStatefulWidget {
  const KeysScreen({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<KeysScreen> createState() => _KeysScreenState();
}

class _KeysScreenState extends ConsumerState<KeysScreen> {
  String? _selectedKey;

  Future<void> _create() async {
    final name = await promptText(
      context,
      title: 'New ingest key',
      label: 'Name (e.g. iOS production)',
      action: 'Create key',
      validator: (v) => v.length > 60 ? 'Keep it under 60 characters' : null,
    );
    if (name == null) return;
    final uid = ref.read(userProvider).value?.uid;
    if (uid == null) return;
    try {
      final key = await ref.read(projectRepositoryProvider).createKey(widget.projectId, uid, name);
      setState(() => _selectedKey = key);
      if (mounted) showMessage(context, 'Key created');
    } catch (e) {
      if (mounted) showMessage(context, friendlyError(e), error: true);
    }
  }

  Future<void> _delete(IngestKey k) async {
    final ok = await confirm(
      context,
      title: 'Delete “${k.name}”?',
      message: 'Apps using this key will stop sending logs right away. Logs already sent are kept.',
      action: 'Delete key',
      destructive: true,
    );
    if (!ok) return;
    try {
      await ref.read(projectRepositoryProvider).deleteKey(widget.projectId, k.key);
    } catch (e) {
      if (mounted) showMessage(context, friendlyError(e), error: true);
    }
  }

  Future<void> _sendTest(IngestKey k) async {
    try {
      await ref
          .read(projectRepositoryProvider)
          .sendTestLog(widget.projectId, k.key, userEmail: ref.read(userProvider).value?.email);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: const Text('Test log sent'),
          action: SnackBarAction(
            label: 'View logs',
            onPressed: () => context.go('/p/${widget.projectId}/logs?range=15m'),
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        showMessage(
          context,
          k.active ? friendlyError(e) : 'This key is disabled. Enable it to send logs.',
          error: true,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final role = ref.watch(myRoleProvider(widget.projectId));
    final theme = Theme.of(context);
    if (role != null && !role.canManageKeys) {
      return const EmptyState(
        icon: Icons.lock_outline,
        title: 'Admins only',
        message: 'Ask a project owner or admin for an ingest key.',
      );
    }
    final keys = ref.watch(ingestKeysProvider(widget.projectId));
    return keys.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorView(e, onRetry: () => ref.invalidate(ingestKeysProvider(widget.projectId))),
      data: (list) {
        final selected =
            list.where((k) => k.key == _selectedKey).firstOrNull ??
            list.where((k) => k.active).firstOrNull ??
            list.firstOrNull;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
          children: [
            Row(
              children: [
                Expanded(child: Text('Ingest keys', style: theme.textTheme.titleLarge)),
                FilledButton.icon(onPressed: _create, icon: const Icon(Icons.add), label: const Text('New key')),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Apps include a key when they send logs. A key can only write logs, so it’s safe to ship inside an app. '
              'Disable or delete a key to stop an app from sending logs.',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            if (list.isEmpty)
              const GlassCard(
                child: EmptyState(
                  icon: Icons.key_off_outlined,
                  title: 'No keys',
                  message: 'Create a key to start sending logs.',
                ),
              )
            else
              GlassCard(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    for (var i = 0; i < list.length; i++) ...[
                      if (i > 0) const Divider(),
                      _KeyTile(
                        k: list[i],
                        selected: list[i].key == selected?.key,
                        onSelect: () => setState(() => _selectedKey = list[i].key),
                        onToggle: (v) => ref
                            .read(projectRepositoryProvider)
                            .setKeyActive(widget.projectId, list[i].key, v)
                            .catchError((Object e) {
                              if (context.mounted) showMessage(context, friendlyError(e), error: true);
                            }),
                        onTest: () => _sendTest(list[i]),
                        onDelete: () => _delete(list[i]),
                      ),
                    ],
                  ],
                ),
              ),
            if (selected != null) ...[
              const SizedBox(height: 28),
              _SetupGuide(projectId: widget.projectId, k: selected),
            ],
          ],
        );
      },
    );
  }
}

class _KeyTile extends StatelessWidget {
  const _KeyTile({
    required this.k,
    required this.selected,
    required this.onSelect,
    required this.onToggle,
    required this.onTest,
    required this.onDelete,
  });

  final IngestKey k;
  final bool selected;
  final VoidCallback onSelect;
  final ValueChanged<bool> onToggle;
  final VoidCallback onTest;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final created = k.createdAt == null ? '' : ' · created ${DateFormat.yMMMd().format(k.createdAt!)}';
    return ListTile(
      selected: selected,
      selectedTileColor: theme.colorScheme.secondaryContainer.withValues(alpha: 0.35),
      onTap: onSelect,
      leading: Icon(k.active ? Icons.key : Icons.key_off, color: k.active ? null : theme.colorScheme.outline),
      title: Text(k.name, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text('${k.masked}${k.active ? '' : ' · disabled'}$created', style: monoStyle.copyWith(fontSize: 12)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Copy key',
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () => copyToClipboard(context, k.key, what: 'Key copied'),
          ),
          Tooltip(
            message: k.active ? 'Disable key' : 'Enable key',
            child: Switch(value: k.active, onChanged: onToggle),
          ),
          PopupMenuButton<String>(
            onSelected: (v) => v == 'test' ? onTest() : onDelete(),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'test', child: Text('Send test log')),
              PopupMenuItem(value: 'delete', child: Text('Delete key')),
            ],
          ),
        ],
      ),
    );
  }
}

class _SetupGuide extends StatefulWidget {
  const _SetupGuide({required this.projectId, required this.k});

  final String projectId;
  final IngestKey k;

  @override
  State<_SetupGuide> createState() => _SetupGuideState();
}

class _SetupGuideState extends State<_SetupGuide> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snippets = SetupSnippets(
      firebaseProjectId: Firebase.app().options.projectId,
      projectId: widget.projectId,
      ingestKey: widget.k.key,
    );
    final tabs = [
      ('Flutter / Dart', snippets.dart),
      ('Swift', snippets.swift),
      ('curl / HTTP', snippets.curl),
      ('Log format', snippets.schema),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Send logs with “${widget.k.name}”', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Pick your platform and paste the code into your app. The values are already filled in.',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _IdChip(label: 'Project ID', value: widget.projectId),
            _IdChip(label: 'Firebase project', value: snippets.firebaseProjectId),
          ],
        ),
        const SizedBox(height: 12),
        SegmentedButton<int>(
          showSelectedIcon: false,
          segments: [for (var i = 0; i < tabs.length; i++) ButtonSegment(value: i, label: Text(tabs[i].$1))],
          selected: {_tab},
          onSelectionChanged: (s) => setState(() => _tab = s.first),
        ),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          decoration: BoxDecoration(color: const Color(0xFF1E1F24), borderRadius: BorderRadius.circular(10)),
          child: Stack(
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 16, 56, 16),
                child: SelectableText(
                  tabs[_tab].$2,
                  style: monoStyle.copyWith(fontSize: 12.5, color: const Color(0xFFE4E6EB), height: 1.45),
                ),
              ),
              Positioned(
                top: 6,
                right: 6,
                child: IconButton(
                  tooltip: 'Copy code',
                  color: const Color(0xFFE4E6EB),
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () => copyToClipboard(context, tabs[_tab].$2, what: 'Code copied'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _IdChip extends StatelessWidget {
  const _IdChip({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => ActionChip(
    avatar: const Icon(Icons.copy, size: 14),
    label: Text('$label: $value', style: monoStyle.copyWith(fontSize: 12)),
    onPressed: () => copyToClipboard(context, value, what: '$label copied'),
  );
}
