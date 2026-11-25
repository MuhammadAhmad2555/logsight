import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/glass.dart';
import '../../core/ui.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../auth/auth_layout.dart';

Future<void> createProjectFlow(BuildContext context, WidgetRef ref) async {
  final name = await promptText(
    context,
    title: 'New project',
    label: 'Project name (e.g. Keyo iOS)',
    action: 'Create',
    validator: (v) => v.length > 80 ? 'Keep it under 80 characters' : null,
  );
  if (name == null) return;
  final user = ref.read(userProvider).value;
  if (user == null) return;
  try {
    final pid = await ref.read(projectRepositoryProvider).createProject(user, name);
    ref.read(lastProjectProvider.notifier).set(pid);
    if (context.mounted) context.go('/p/$pid/keys');
  } catch (e) {
    if (context.mounted) showMessage(context, friendlyError(e), error: true);
  }
}

class ProjectsScreen extends ConsumerWidget {
  const ProjectsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = ref.watch(myProjectsProvider);
    final invites = ref.watch(myInvitesProvider).value ?? const <Invite>[];
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const AppLogo(size: 24),
        actions: [
          IconButton(
            tooltip: 'Account',
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: () => context.push('/account'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => createProjectFlow(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('New project'),
      ),
      body: projects.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(e, onRetry: () => ref.invalidate(myProjectsProvider)),
        data: (list) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 96),
              children: [
                if (invites.isNotEmpty) ...[
                  Text('Invitations', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  for (final inv in invites) _InviteCard(invite: inv),
                  const SizedBox(height: 24),
                ],
                Text('Your projects', style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  'A project collects logs from one or more apps or services.',
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                if (list.isEmpty)
                  GlassCard(
                    child: EmptyState(
                      icon: Icons.folder_open_outlined,
                      title: 'No projects yet',
                      message: 'Create a project to get an ingest key, then send logs from your apps.',
                      action: FilledButton.icon(
                        onPressed: () => createProjectFlow(context, ref),
                        icon: const Icon(Icons.add),
                        label: const Text('Create project'),
                      ),
                    ),
                  )
                else
                  for (final p in list) _ProjectTile(project: p),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProjectTile extends ConsumerWidget {
  const _ProjectTile({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uid = ref.watch(userProvider).value?.uid ?? '';
    final role = project.roleOf(uid) ?? ProjectRole.viewer;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          leading: CircleAvatar(child: Text(project.name.characters.first.toUpperCase())),
          title: Text(project.name, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text('${role.label} · ${project.members.length} member${project.members.length == 1 ? '' : 's'}'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            ref.read(lastProjectProvider.notifier).set(project.id);
            context.go('/p/${project.id}/overview');
          },
        ),
      ),
    );
  }
}

class _InviteCard extends ConsumerStatefulWidget {
  const _InviteCard({required this.invite});

  final Invite invite;

  @override
  ConsumerState<_InviteCard> createState() => _InviteCardState();
}

class _InviteCardState extends ConsumerState<_InviteCard> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action, String done) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) showMessage(context, done);
    } catch (e) {
      if (mounted) showMessage(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inv = widget.invite;
    final repo = ref.read(projectRepositoryProvider);
    final user = ref.read(userProvider).value!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(inv.projectName, style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text('${inv.invitedByEmail} invited you as ${inv.role.label}'),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: _busy ? null : () => _run(() => repo.cancelInvite(inv.id), 'Invitation declined'),
                    child: const Text('Decline'),
                  ),
                  const SizedBox(width: 6),
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() => repo.acceptInvite(inv, user), 'You joined ${inv.projectName}'),
                    child: const Text('Accept'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
