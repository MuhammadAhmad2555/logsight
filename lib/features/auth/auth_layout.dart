import 'package:flutter/material.dart';

import '../../core/glass.dart';

class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 28, this.showName = true});

  final double size;

  /// False shows only the mark (collapsed sidebar).
  final bool showName;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset(
          'assets/branding/logo_256.png',
          width: size,
          height: size,
          filterQuality: FilterQuality.medium,
          semanticLabel: 'LogSight logo',
          errorBuilder: (_, _, _) => Icon(Icons.visibility, size: size),
        ),
        if (showName) ...[
          SizedBox(width: size * 0.35),
          Text(
            'LogSight',
            style: TextStyle(fontSize: size * 0.68, fontWeight: FontWeight.w700, letterSpacing: -0.3),
          ),
        ],
      ],
    );
  }
}

/// Centered card used by the sign-in and verify-email screens.
class AuthLayout extends StatelessWidget {
  const AuthLayout({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(child: AppLogo(size: 34)),
                  const SizedBox(height: 28),
                  GlassCard(
                    child: Padding(padding: const EdgeInsets.all(24), child: child),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
