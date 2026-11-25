import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'data/activity.dart';
import 'data/log_query.dart';
import 'features/account/account_screen.dart';
import 'features/activity/activity_screen.dart';
import 'features/activity/definitions_screen.dart';
import 'features/alerts/alerts_screen.dart';
import 'features/auth/sign_in_screen.dart';
import 'features/auth/verify_email_screen.dart';
import 'features/issues/issues_screen.dart';
import 'features/keys/keys_screen.dart';
import 'features/logs/logs_screen.dart';
import 'features/members/members_screen.dart';
import 'features/overview/overview_screen.dart';
import 'features/people/people_screen.dart';
import 'features/projects/project_settings_screen.dart';
import 'features/projects/projects_screen.dart';
import 'features/shell/project_shell.dart';
import 'state/providers.dart';

/// Re-runs router redirects when auth state changes.
class _AuthListenable extends ChangeNotifier {
  void notify() => notifyListeners();
}

final routerProvider = Provider<GoRouter>((ref) {
  final listenable = _AuthListenable();
  ref.listen(userProvider, (_, _) => listenable.notify());
  ref.onDispose(listenable.dispose);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: listenable,
    redirect: (context, state) {
      final auth = ref.read(userProvider);
      if (auth.isLoading && !auth.hasValue) return null;
      final User? user = auth.value;
      final loc = state.matchedLocation;
      final onAuthPage = loc == '/sign-in';
      if (user == null) return onAuthPage ? null : '/sign-in';
      if (!user.emailVerified) return loc == '/verify-email' ? null : '/verify-email';
      if (onAuthPage || loc == '/verify-email') return '/';
      if (loc == '/') {
        final last = ref.read(lastProjectProvider);
        return last != null ? '/p/$last/overview' : '/projects';
      }
      return null;
    },
    routes: [
      GoRoute(path: '/', builder: (_, _) => const _Splash()),
      GoRoute(path: '/sign-in', builder: (_, _) => const SignInScreen()),
      GoRoute(path: '/verify-email', builder: (_, _) => const VerifyEmailScreen()),
      GoRoute(path: '/projects', builder: (_, _) => const ProjectsScreen()),
      GoRoute(path: '/account', builder: (_, _) => const AccountScreen()),
      ShellRoute(
        builder: (context, state, child) =>
            ProjectShell(projectId: state.pathParameters['pid']!, location: state.matchedLocation, child: child),
        routes: [
          GoRoute(
            path: '/p/:pid/logs',
            pageBuilder: (context, state) => NoTransitionPage(
              child: LogsScreen(projectId: state.pathParameters['pid']!, query: LogQuery.fromUri(state.uri)),
            ),
          ),
          GoRoute(
            path: '/p/:pid/overview',
            pageBuilder: (context, state) =>
                NoTransitionPage(child: OverviewScreen(projectId: state.pathParameters['pid']!)),
          ),
          GoRoute(
            path: '/p/:pid/activity',
            pageBuilder: (context, state) => NoTransitionPage(
              child: ActivityScreen(projectId: state.pathParameters['pid']!, query: ActivityQuery.fromUri(state.uri)),
            ),
          ),
          GoRoute(
            path: '/p/:pid/people',
            pageBuilder: (context, state) =>
                NoTransitionPage(child: PeopleScreen(projectId: state.pathParameters['pid']!)),
          ),
          GoRoute(
            path: '/p/:pid/people/:personId',
            pageBuilder: (context, state) => NoTransitionPage(
              child: PersonScreen(
                key: ValueKey(state.pathParameters['personId']),
                projectId: state.pathParameters['pid']!,
                personId: state.pathParameters['personId']!,
              ),
            ),
          ),
          GoRoute(
            path: '/p/:pid/data',
            pageBuilder: (context, state) =>
                NoTransitionPage(child: DefinitionsScreen(projectId: state.pathParameters['pid']!)),
          ),
          GoRoute(
            path: '/p/:pid/issues',
            pageBuilder: (context, state) =>
                NoTransitionPage(child: IssuesScreen(projectId: state.pathParameters['pid']!)),
          ),
          GoRoute(
            path: '/p/:pid/alerts',
            pageBuilder: (context, state) =>
                NoTransitionPage(child: AlertsScreen(projectId: state.pathParameters['pid']!)),
          ),
          GoRoute(
            path: '/p/:pid/keys',
            pageBuilder: (context, state) =>
                NoTransitionPage(child: KeysScreen(projectId: state.pathParameters['pid']!)),
          ),
          GoRoute(
            path: '/p/:pid/members',
            pageBuilder: (context, state) =>
                NoTransitionPage(child: MembersScreen(projectId: state.pathParameters['pid']!)),
          ),
          GoRoute(
            path: '/p/:pid/settings',
            pageBuilder: (context, state) =>
                NoTransitionPage(child: ProjectSettingsScreen(projectId: state.pathParameters['pid']!)),
          ),
        ],
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Page not found'),
            const SizedBox(height: 12),
            FilledButton(onPressed: () => context.go('/projects'), child: const Text('Go to projects')),
          ],
        ),
      ),
    ),
  );
});

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: CircularProgressIndicator()));
}
