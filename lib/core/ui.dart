import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'severity.dart';

void showMessage(BuildContext context, String message, {bool error = false}) {
  final scheme = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              error ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
              size: 18,
              color: error ? scheme.onError : scheme.onInverseSurface,
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: error ? scheme.error : null,
        behavior: SnackBarBehavior.floating,
      ),
    );
}

Future<void> copyToClipboard(BuildContext context, String text, {String what = 'Copied'}) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) showMessage(context, '$what to clipboard');
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  String action = 'Confirm',
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(
          style: destructive ? FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error) : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Asks for one line of text. Returns null if cancelled.
Future<String?> promptText(
  BuildContext context, {
  required String title,
  String label = '',
  String initial = '',
  String action = 'Save',
  String? Function(String)? validator,
}) {
  final controller = TextEditingController(text: initial);
  final formKey = GlobalKey<FormState>();
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      void submit() {
        if (formKey.currentState!.validate()) Navigator.pop(ctx, controller.text.trim());
      }

      return AlertDialog(
        title: Text(title),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(labelText: label),
            validator: (v) {
              if ((v ?? '').trim().isEmpty) return 'Required';
              return validator?.call(v!.trim());
            },
            onFieldSubmitted: (_) => submit(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: submit, child: Text(action)),
        ],
      );
    },
  );
}

class SeverityBadge extends StatelessWidget {
  const SeverityBadge(this.severity, {super.key, this.compact = false});

  final Severity severity;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final c = severity.color;
    return Container(
      width: compact ? 62 : 70,
      height: compact ? 20 : 22,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: c.withValues(alpha: dark ? 0.16 : 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.withValues(alpha: dark ? 0.30 : 0.22)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: c,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: c.withValues(alpha: 0.6), blurRadius: 4)],
            ),
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              severity.label,
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: TextStyle(
                color: c,
                fontSize: compact ? 9.5 : 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      scheme.primary.withValues(alpha: dark ? 0.24 : 0.14),
                      scheme.secondary.withValues(alpha: dark ? 0.14 : 0.08),
                    ],
                  ),
                  border: Border.all(color: scheme.primary.withValues(alpha: dark ? 0.25 : 0.16)),
                ),
                child: Icon(icon, size: 26, color: scheme.primary),
              ),
              const SizedBox(height: 16),
              Text(title, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
              if (message != null) ...[
                const SizedBox(height: 6),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
              if (action != null) ...[const SizedBox(height: 20), action!],
            ],
          ),
        ),
      ),
    );
  }
}

class ErrorView extends StatelessWidget {
  const ErrorView(this.error, {super.key, this.onRetry});

  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.error_outline,
      title: 'Couldn’t load this',
      message: friendlyError(error),
      action: onRetry == null
          ? null
          : OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Retry')),
    );
  }
}

String friendlyError(Object e) {
  final s = e.toString();
  if (s.contains('permission-denied')) {
    return 'You don’t have access to this, or your email isn’t verified yet.';
  }
  if (s.contains('failed-precondition') && s.contains('index')) {
    return 'A Firestore index is still building. Try again in a few minutes.';
  }
  if (s.contains('unavailable')) return 'Can’t reach the server. Check your connection.';
  return s.replaceFirst(RegExp(r'^\[[^\]]+\]\s*'), '');
}

/// "just now", "5m ago", "3h ago", "2d ago".
String timeAgo(DateTime? t) {
  if (t == null) return 'never';
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 45) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 30) return '${d.inDays}d ago';
  return '${(d.inDays / 30).floor()}mo ago';
}

/// Uppercase section label used across screens.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                letterSpacing: 0.9,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// A service name (`service.name`) as a small chip in a colour of its own,
/// the same on every screen, so logs from several apps are easy to tell apart.
class ServiceChip extends StatelessWidget {
  const ServiceChip(this.service, {super.key});

  final String service;

  /// A stable hue per service name, readable in light and dark themes.
  static Color colorOf(String service, Brightness brightness) {
    var h = 0;
    for (final unit in service.codeUnits) {
      h = (h * 31 + unit) & 0x7fffffff;
    }
    final hue = (h % 360).toDouble();
    return HSLColor.fromAHSL(1, hue, 0.55, brightness == Brightness.dark ? 0.72 : 0.38).toColor();
  }

  @override
  Widget build(BuildContext context) {
    final c = colorOf(service, Theme.of(context).brightness);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 6, height: 6, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              service,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c),
            ),
          ),
        ],
      ),
    );
  }
}
