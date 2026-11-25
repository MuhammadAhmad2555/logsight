import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/auth_repository.dart';
import '../../state/providers.dart';
import 'auth_layout.dart';

class VerifyEmailScreen extends ConsumerStatefulWidget {
  const VerifyEmailScreen({super.key});

  @override
  ConsumerState<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends ConsumerState<VerifyEmailScreen> {
  bool _busy = false;

  Future<void> _check() async {
    setState(() => _busy = true);
    try {
      final ok = await ref.read(authRepositoryProvider).refreshVerification();
      if (!ok && mounted) {
        showMessage(context, 'Not verified yet. Open the link in the email, then try again.');
      }
    } catch (e) {
      if (mounted) showMessage(context, friendlyAuthError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    try {
      await ref.read(authRepositoryProvider).resendVerification();
      if (mounted) showMessage(context, 'Verification email sent.');
    } catch (e) {
      if (mounted) showMessage(context, friendlyAuthError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final email = ref.watch(userProvider).value?.email ?? 'your email';
    return AuthLayout(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.mark_email_unread_outlined, size: 40, color: theme.colorScheme.primary),
          const SizedBox(height: 12),
          Text(
            'Verify your email',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            'We sent a link to $email. Open it to finish setting up your account. '
            'Verification protects project invites from going to the wrong person.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 22),
          FilledButton(
            onPressed: _busy ? null : _check,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
            child: _busy
                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('I’ve verified my email'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: _resend, child: const Text('Resend email')),
          TextButton(
            onPressed: () => ref.read(authRepositoryProvider).signOut(),
            child: const Text('Use a different account'),
          ),
        ],
      ),
    );
  }
}
