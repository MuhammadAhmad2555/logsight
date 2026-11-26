import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'data/activity.dart';
import 'data/log_query.dart';
import 'features/account/account_screen.dart';
import 'features/activity/activity_screen.dart';
import 'features/funnels/funnels_screen.dart';
import 'features/activity/definitions_screen.dart';
import 'features/alerts/alerts_screen.dart';
import 'features/auth/sign_in_screen.dart';
import 'features/auth/verify_email_screen.dart';
import 'features/dashboards/dashboard_screen.dart';
import 'features/dashboards/dashboards_screen.dart';
import 'features/endpoints/endpoints_screen.dart';
import 'features/flags/flags_screen.dart';
import 'features/help/help_screen.dart';
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

/// Pages inside a project: the new page fades in with a slight rise while the
/// sidebar and header stay put. Filter changes on the same page (same
/// [GoRouterState.pageKey], query ignored) update in place without animating.
class _FadePage<T> extends CustomTransitionPage<T> {
  _FadePage({required super.child, super.key})
    : super(
        transitionDuration: const Duration(milliseconds: 220),
        reverseTransitionDuration: const Duration(milliseconds: 120),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          if (MediaQuery.disableAnimationsOf(context)) return child;
          // Start a little late so the old page has mostly faded out first
          // (pages are see-through over the app background).
          final fade = CurvedAnimation(
            parent: animation,
            curve: const Interval(0.3, 1, curve: Curves.easeOut),
          );
          final rise = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          );
          return FadeTransition(
            opacity: fade,
            child: SlideTransition(
              position: Tween(
                begin: const Offset(0, 0.012),
                end: Offset.zero,
              ).animate(rise),
              child: child,
            ),
          );
        },
      );
}

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
      if (!user.emailVerified)
        return loc == '/verify-email' ? null : '/verify-email';
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
      GoRoute(
        path: '/verify-email',
        builder: (_, _) => const VerifyEmailScreen(),
      ),
      GoRoute(path: '/projects', builder: (_, _) => const ProjectsScreen()),
      GoRoute(path: '/account', builder: (_, _) => const AccountScreen()),
      ShellRoute(
        builder: (context, state, child) => ProjectShell(
          projectId: state.pathParameters['pid']!,
          location: state.matchedLocation,
          child: child,
        ),
        routes: [
          GoRoute(
            path: '/p/:pid/logs',
            pageBuilder: (context, state) => _FadePage(
              key: state.pageKey,

              child: LogsScreen(
                projectId: state.pathParameters['pid']!,
                query: LogQuery.fromUri(state.uri),
              ),
            ),
          ),
          GoRoute(
            path: '/p/:pid/overview',
            pageBuilder: (context, state) => _FadePage(
              key: state.pageKey,
              child: OverviewScreen(projectId: state.pathParameters['pid']!),
            ),
          ),
          GoRoute(
            path: '/p/:pid/activity',
            pageBuilder: (context, state) => _FadePage(
              key: state.pageKey,

              child: ActivityScreen(
                projectId: state.pathParameters['pid']!,
                query: ActivityQuery.fromUri(state.uri),
              ),
            ),
          ),
          GoRoute(
            path: '/p/:pid/funnels',
            pageBuilder: (context, state) => _FadePage(
              key: state.pageKey,
              child: FunnelsScreen(projectId: state.pathParameters['pid']!),
            ),
          ),
          GoRoute(
            path: '/p/:pid/people',
            pageBuilder: (context, state) => _FadePage(
              key: state.pageKey,
              child: PeopleScreen(projectId: state.pathParameters['pid']!),
            ),
          ),
          GoRoute(
            path: '/p/:pid/people/:personId',
            pageBuilder: (context, state) => _FadePage(
              key: state.pageKey,

              child: PersonScreen(
                key: ValueKey(state.pathParameters['personId']),
                projectId: state.pathParameters['pid']!,
                personId: state.pathParameters['personId']!,
              ),
            ),
          ),
          GoRoute(
            path: '/p/:pid/data',
            pageBuilder: (context, state) => _FadePage(
              key: state.pageKey,
              child: DefinitionsScreen(projectId: state.pathParameters['pid']!),
            ),
          ),
          GoRoute(
            path: '/p/:pid/issues',
            pageBuilder: (context, state) => _FadePage(
              key: state.pageKey,
              child: IssuesScreen(projectId: state.pathParameters['pid']!),
            ),
          ),
          GoRoute(
            path: '/p/:pid/dashboards',
            pageBuilder: (context, state) => _FadePage(
              key: state.pageKey,
              child: DashboardsScreen(projectId: state.pathParameters['pid']!),
            ),
          ),
          GoRoute(
            path: '/p/:pid/dashboards/:id',
            pageBuilder: (context, state) => _FadePage(
              key: state.pageKey,

              child: DashboardScreen(
                key: ValueKey(state.pathParameters['id']),
                projectId: state.pathParameters['pid']!,
                dashboardId: state.pathParameters['id']!,
              ),
            ),
          ),
          GoRoute(
            path: '/p/:pid/endpoints',
            pageBuilder: (context, state) => _FadePage(
              key: state.pageKey,
              child: EndpointsScreen(projectId: state.pathParameters['pid']!),
            ),
          ),
          GoRoute(
            path: '/p/:pid/help',
            pageBuilder: (context, state) => _FadePage(
              key: state.pageKey,

              child: HelpScreen(
                projectId: state.pathParameters['pid']!,
                topicId: state.uri.queryParameters['topic'],
              ),
            ),
          ),
          GoRoute(
            path: '/p/:pid/flags',
            pageBuilder: (context, state) => _FadePage(
              key: state.pageKey,
              child: FlagsScreen(projectId: state.pathParameters['pid']!),
            ),
          ),
          GoRoute(
            path: '/p/:pid/alerts',
            pageBuilder: (context, state) => _FadePage(
              key: state.pageKey,
              child: AlertsScreen(projectId: state.pathParameters['pid']!),
            ),
          ),
          GoRoute(
            path: '/p/:pid/keys',
            pageBuilder: (context, state) => _FadePage(
              key: state.pageKey,
              child: KeysScreen(projectId: state.pathParameters['pid']!),
            ),
          ),
          GoRoute(
            path: '/p/:pid/members',
            pageBuilder: (context, state) => _FadePage(
              key: state.pageKey,
              child: MembersScreen(projectId: state.pathParameters['pid']!),
            ),
          ),
          GoRoute(
            path: '/p/:pid/settings',
            pageBuilder: (context, state) => _FadePage(
              key: state.pageKey,
              child: ProjectSettingsScreen(
                projectId: state.pathParameters['pid']!,
              ),
            ),
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
            FilledButton(
              onPressed: () => context.go('/projects'),
              child: const Text('Go to projects'),
            ),
          ],
        ),
      ),
    ),
  );
});

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}
