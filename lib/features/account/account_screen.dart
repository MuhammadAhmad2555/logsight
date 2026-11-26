import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/time_format.dart';
import '../../core/glass.dart';
import '../../core/ui.dart';
import '../../data/auth_repository.dart';
import '../../state/providers.dart';

class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(userProvider).value;
    final mode = ref.watch(themeModeProvider);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              GlassCard(
                child: ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.person_outline)),
                  title: Text(user?.email ?? ''),
                  subtitle: Text((user?.emailVerified ?? false) ? 'Email verified' : 'Email not verified'),
                ),
              ),
              const SizedBox(height: 20),
              Text('Appearance', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(value: ThemeMode.system, label: Text('System'), icon: Icon(Icons.brightness_auto)),
                  ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode_outlined)),
                  ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode_outlined)),
                ],
                selected: {mode},
                onSelectionChanged: (s) => ref.read(themeModeProvider.notifier).set(s.first),
              ),
              const SizedBox(height: 12),
              SegmentedButton<ClockFormat>(
                segments: [
                  for (final f in ClockFormat.values)
                    ButtonSegment(
                      value: f,
                      label: Text(f.label),
                      icon: Icon(f == ClockFormat.system ? Icons.schedule_rounded : Icons.access_time_rounded),
                    ),
                ],
                selected: {ref.watch(clockFormatProvider)},
                onSelectionChanged: (s) => ref.read(clockFormatProvider.notifier).set(s.first),
              ),
              const SizedBox(height: 4),
              Text(
                'How times are shown, e.g. ${timeFormatFor(false).format(DateTime(2026, 1, 1, 14, 30))} or '
                '${timeFormatFor(true).format(DateTime(2026, 1, 1, 14, 30))}. System follows this device.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              Text('Security', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              GlassCard(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.password),
                      title: const Text('Change password'),
                      subtitle: const Text('We’ll email you a link to set a new password'),
                      onTap: () async {
                        final email = user?.email;
                        if (email == null) return;
                        try {
                          await ref.read(authRepositoryProvider).sendPasswordReset(email);
                          if (context.mounted) showMessage(context, 'Password reset link sent to $email');
                        } catch (e) {
                          if (context.mounted) showMessage(context, friendlyAuthError(e), error: true);
                        }
                      },
                    ),
                    const Divider(),
                    ListTile(
                      leading: Icon(Icons.logout, color: theme.colorScheme.error),
                      title: Text('Sign out', style: TextStyle(color: theme.colorScheme.error)),
                      onTap: () => ref.read(authRepositoryProvider).signOut(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
