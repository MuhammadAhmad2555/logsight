import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

// The page fade (router.dart) relies on GoRouterState.pageKey staying the
// same when only the query changes (filters on the Logs page) and changing
// between pages.
void main() {
  testWidgets('pageKey ignores the query but not the path', (tester) async {
    final keys = <String, ValueKey<String>>{};
    final router = GoRouter(
      initialLocation: '/p/1/logs',
      routes: [
        for (final page in ['logs', 'issues'])
          GoRoute(
            path: '/p/:pid/$page',
            builder: (context, state) {
              keys[state.uri.toString()] = state.pageKey;
              return const SizedBox();
            },
          ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    router.go('/p/1/logs?sev=error');
    await tester.pumpAndSettle();
    router.go('/p/1/issues');
    await tester.pumpAndSettle();
    expect(keys['/p/1/logs?sev=error'], keys['/p/1/logs']);
    expect(keys['/p/1/issues'], isNot(keys['/p/1/logs']));
  });
}
