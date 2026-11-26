import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_menu.dart';
import '../../core/glass.dart';
import '../../core/ui.dart';
import '../../data/models.dart';
import '../../state/providers.dart';

class ProjectSettingsScreen extends ConsumerStatefulWidget {
  const ProjectSettingsScreen({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<ProjectSettingsScreen> createState() => _ProjectSettingsScreenState();
}

class _ProjectSettingsScreenState extends ConsumerState<ProjectSettingsScreen> {
  int _retentionDays = 30;
  bool _busy = false;
  String? _progress;

  Future<void> _rename(Project p) async {
    final name = await promptText(
      context,
      title: 'Rename project',
      label: 'Project name',
      initial: p.name,
      validator: (v) => v.length > 80 ? 'Keep it under 80 characters' : null,
    );
    if (name == null || name == p.name) return;
    try {
      await ref.read(projectRepositoryProvider).renameProject(p.id, name);
    } catch (e) {
      if (mounted) showMessage(context, friendlyError(e), error: true);
    }
  }

  Future<void> _purge() async {
    final ok = await confirm(
      context,
      title: 'Delete old logs?',
      message: 'Every log older than $_retentionDays days will be permanently deleted.',
      action: 'Delete logs',
      destructive: true,
    );
    if (!ok) return;
    setState(() {
      _busy = true;
      _progress = 'Deleting…';
    });
    try {
      final n = await ref
          .read(projectRepositoryProvider)
          .deleteLogsBefore(
            widget.projectId,
            DateTime.now().subtract(Duration(days: _retentionDays)),
            onProgress: (n) {
              if (mounted) setState(() => _progress = 'Deleted $n logs…');
            },
          );
      if (mounted) showMessage(context, n == 0 ? 'No logs older than $_retentionDays days' : 'Deleted $n logs');
    } catch (e) {
      if (mounted) showMessage(context, friendlyError(e), error: true);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _deleteProject(Project p) async {
    final typed = await promptText(
      context,
      title: 'Delete ${p.name}?',
      label: 'Type the project name to confirm',
      action: 'Delete forever',
      validator: (v) => v == p.name ? null : 'The name doesn’t match',
    );
    if (typed == null) return;
    setState(() {
      _busy = true;
      _progress = 'Deleting project…';
    });
    try {
      await ref
          .read(projectRepositoryProvider)
          .deleteProject(
            p.id,
            onProgress: (n) {
              if (mounted) setState(() => _progress = 'Deleted $n logs…');
            },
          );
      if (mounted) context.go('/projects');
    } catch (e) {
      if (mounted) {
        showMessage(context, friendlyError(e), error: true);
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final project = ref.watch(projectProvider(widget.projectId)).value;
    final role = ref.watch(myRoleProvider(widget.projectId));
    final theme = Theme.of(context);
    if (project == null || role == null) return const Center(child: CircularProgressIndicator());

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
      children: [
        Text('Project settings', style: theme.textTheme.titleLarge),
        const SizedBox(height: 16),
        GlassCard(
          child: Column(
            children: [
              ListTile(
                title: const Text('Name'),
                subtitle: Text(project.name),
                trailing: role == ProjectRole.owner
                    ? TextButton(onPressed: () => _rename(project), child: const Text('Rename'))
                    : null,
              ),
              const Divider(),
              ListTile(
                title: const Text('Project ID'),
                subtitle: Text(project.id),
                trailing: IconButton(
                  tooltip: 'Copy',
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () => copyToClipboard(context, project.id, what: 'Project ID copied'),
                ),
              ),
              const Divider(),
              ListTile(title: const Text('Your role'), subtitle: Text(role.label)),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Text('Text logs', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        _TextLogsCard(projectId: widget.projectId),
        if (role.canDeleteLogs) ...[
          const SizedBox(height: 24),
          Text('Data retention', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Delete logs you no longer need to keep storage costs down.'),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text('Delete logs older than'),
                      IgnorePointer(
                        ignoring: _busy,
                        child: AppMenuAnchor<int>(
                          selected: {_retentionDays},
                          searchable: false,
                          minWidth: 160,
                          entries: () => [
                            for (final d in const [7, 14, 30, 60, 90]) MenuEntry(d, '$d days'),
                          ],
                          onSelected: (v) => setState(() => _retentionDays = v),
                          builder: (context, open) =>
                              MenuPill(icon: Icons.history_rounded, label: '$_retentionDays days', open: open),
                        ),
                      ),
                      FilledButton.tonal(onPressed: _busy ? null : _purge, child: const Text('Delete now')),
                    ],
                  ),
                  if (_progress != null) ...[
                    const SizedBox(height: 8),
                    Text(_progress!, style: theme.textTheme.bodySmall),
                  ],
                ],
              ),
            ),
          ),
        ],
        if (role == ProjectRole.owner) ...[
          const SizedBox(height: 24),
          Text('Danger zone', style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.error)),
          const SizedBox(height: 8),
          GlassCard(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: theme.colorScheme.error.withValues(alpha: 0.5)),
            ),
            child: ListTile(
              title: const Text('Delete project'),
              subtitle: const Text('Permanently deletes the project, its keys and all its logs.'),
              trailing: OutlinedButton(
                style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
                onPressed: _busy ? null : () => _deleteProject(project),
                child: const Text('Delete'),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Auto-save switch and where LogSight keeps this project's .txt files.
class _TextLogsCard extends ConsumerWidget {
  const _TextLogsCard({required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(textLogStoreProvider(projectId));
    final autoSave = ref.watch(autoSaveProvider);
    final theme = Theme.of(context);
    if (!store.canAutoSave) {
      return const GlassCard(
        child: ListTile(
          leading: Icon(Icons.description_outlined),
          title: Text('Saving to files isn’t available in the browser'),
          subtitle: Text('Use “Save as .txt” on the Logs page to download logs, or use the desktop or mobile app.'),
        ),
      );
    }
    return GlassCard(
      child: Column(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.save_outlined),
            title: const Text('Auto-save logs as text'),
            subtitle: const Text(
              'Every log you load or receive live is saved once to all.txt and to a file per service.name.',
            ),
            value: autoSave,
            onChanged: (v) => ref.read(autoSaveProvider.notifier).set(v),
          ),
          const Divider(),
          FutureBuilder<String?>(
            future: store.folderPath(),
            builder: (context, snap) {
              final path = snap.data;
              return ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: const Text('Saved in'),
                subtitle: SelectableText(
                  path ?? 'Loading…',
                  style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                ),
                trailing: path == null
                    ? null
                    : IconButton(
                        tooltip: 'Copy path',
                        icon: const Icon(Icons.copy, size: 18),
                        onPressed: () => copyToClipboard(context, path, what: 'Path copied'),
                      ),
              );
            },
          ),
        ],
      ),
    );
  }
}
