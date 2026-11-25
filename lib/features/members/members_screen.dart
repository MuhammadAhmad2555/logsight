import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/glass.dart';
import '../../core/ui.dart';
import '../../data/models.dart';
import '../../state/providers.dart';

class MembersScreen extends ConsumerWidget {
  const MembersScreen({super.key, required this.projectId});

  final String projectId;

  Future<void> _invite(BuildContext context, WidgetRef ref, Project p) async {
    final result = await showDialog<(String, ProjectRole)>(context: context, builder: (_) => const _InviteDialog());
    if (result == null) return;
    final (email, role) = result;
    final user = ref.read(userProvider).value!;
    if (p.memberEmails.values.contains(email.toLowerCase())) {
      if (context.mounted) showMessage(context, '$email is already a member');
      return;
    }
    try {
      await ref.read(projectRepositoryProvider).invite(p, user, email, role);
      if (context.mounted) {
        showMessage(context, 'Invitation created. $email will see it after signing in to LogSight.');
      }
    } catch (e) {
      if (context.mounted) showMessage(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final project = ref.watch(projectProvider(projectId)).value;
    final uid = ref.watch(userProvider).value?.uid;
    if (project == null || uid == null) return const Center(child: CircularProgressIndicator());
    final myRole = project.roleOf(uid);
    final isOwner = myRole == ProjectRole.owner;
    final invites = isOwner ? ref.watch(projectInvitesProvider(projectId)).value ?? const <Invite>[] : const <Invite>[];
    final theme = Theme.of(context);
    final repo = ref.read(projectRepositoryProvider);

    final members = project.members.entries.toList()
      ..sort(
        (a, b) => a.value.index != b.value.index
            ? a.value.index.compareTo(b.value.index)
            : (project.memberEmails[a.key] ?? '').compareTo(project.memberEmails[b.key] ?? ''),
      );

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
      children: [
        Row(
          children: [
            Expanded(child: Text('Members', style: theme.textTheme.titleLarge)),
            if (isOwner)
              FilledButton.icon(
                onPressed: () => _invite(context, ref, project),
                icon: const Icon(Icons.person_add_alt),
                label: const Text('Invite'),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Admins manage ingest keys and can delete logs. Viewers can search logs. Only the owner manages members.',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        GlassCard(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var i = 0; i < members.length; i++) ...[
                if (i > 0) const Divider(),
                ListTile(
                  leading: CircleAvatar(
                    child: Text((project.memberEmails[members[i].key] ?? '?').characters.first.toUpperCase()),
                  ),
                  title: Text(project.memberEmails[members[i].key] ?? members[i].key),
                  subtitle: Text(members[i].key == uid ? '${members[i].value.label} · you' : members[i].value.label),
                  trailing: _memberActions(context, ref, project, members[i].key, members[i].value, uid),
                ),
              ],
            ],
          ),
        ),
        if (invites.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text('Pending invitations', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          GlassCard(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < invites.length; i++) ...[
                  if (i > 0) const Divider(),
                  ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.mail_outline, size: 18)),
                    title: Text(invites[i].email),
                    subtitle: Text('Invited as ${invites[i].role.label}'),
                    trailing: TextButton(
                      onPressed: () => repo.cancelInvite(invites[i].id),
                      child: const Text('Cancel'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
        if (!isOwner) ...[
          const SizedBox(height: 24),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
            icon: const Icon(Icons.logout),
            label: const Text('Leave project'),
            onPressed: () async {
              final ok = await confirm(
                context,
                title: 'Leave ${project.name}?',
                message: 'You’ll lose access until someone invites you again.',
                action: 'Leave',
                destructive: true,
              );
              if (!ok) return;
              try {
                await repo.leaveProject(project, uid);
                if (context.mounted) context.go('/projects');
              } catch (e) {
                if (context.mounted) showMessage(context, friendlyError(e), error: true);
              }
            },
          ),
        ],
      ],
    );
  }

  Widget? _memberActions(
    BuildContext context,
    WidgetRef ref,
    Project p,
    String memberUid,
    ProjectRole role,
    String myUid,
  ) {
    if (p.roleOf(myUid) != ProjectRole.owner || role == ProjectRole.owner) return null;
    final repo = ref.read(projectRepositoryProvider);
    return PopupMenuButton<String>(
      onSelected: (v) async {
        try {
          switch (v) {
            case 'admin':
              await repo.setMemberRole(p, memberUid, ProjectRole.admin);
            case 'viewer':
              await repo.setMemberRole(p, memberUid, ProjectRole.viewer);
            case 'remove':
              final ok = await confirm(
                context,
                title: 'Remove member?',
                message: '${p.memberEmails[memberUid] ?? 'This member'} will lose access to ${p.name}.',
                action: 'Remove',
                destructive: true,
              );
              if (ok) await repo.removeMember(p, memberUid);
          }
        } catch (e) {
          if (context.mounted) showMessage(context, friendlyError(e), error: true);
        }
      },
      itemBuilder: (_) => [
        CheckedPopupMenuItem(value: 'admin', checked: role == ProjectRole.admin, child: const Text('Admin')),
        CheckedPopupMenuItem(value: 'viewer', checked: role == ProjectRole.viewer, child: const Text('Viewer')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'remove', child: Text('Remove from project')),
      ],
    );
  }
}

class _InviteDialog extends StatefulWidget {
  const _InviteDialog();

  @override
  State<_InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends State<_InviteDialog> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  ProjectRole _role = ProjectRole.viewer;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState!.validate()) Navigator.pop(context, (_email.text.trim().toLowerCase(), _role));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Invite a teammate'),
      content: SizedBox(
        width: 400,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _email,
                autofocus: true,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email'),
                validator: (v) =>
                    RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch((v ?? '').trim()) ? null : 'Enter a valid email',
                onFieldSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 16),
              SegmentedButton<ProjectRole>(
                segments: const [
                  ButtonSegment(value: ProjectRole.viewer, label: Text('Viewer')),
                  ButtonSegment(value: ProjectRole.admin, label: Text('Admin')),
                ],
                selected: {_role},
                onSelectionChanged: (s) => setState(() => _role = s.first),
              ),
              const SizedBox(height: 10),
              Text(
                'They’ll see the invitation on their Projects page after signing in with this email.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Send invite')),
      ],
    );
  }
}
