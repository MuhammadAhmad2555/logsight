import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

/// A page you can jump back to: a section (Logs), a dashboard, a saved view.
@immutable
class QuickLink {
  const QuickLink({required this.path, required this.title, required this.kind, this.at});

  /// App path, with query for views (e.g. `/p/x/logs?service=a`).
  final String path;
  final String title;

  /// What it is, shown next to the title (Dashboard, Logs, Feature flags…).
  final String kind;
  final DateTime? at;

  Map<String, Object?> toJson() => {'path': path, 'title': title, 'kind': kind, 'at': at?.millisecondsSinceEpoch};

  static QuickLink? fromJson(Object? m) {
    if (m is! Map || m['path'] is! String || m['title'] is! String) return null;
    final at = m['at'];
    return QuickLink(
      path: m['path'] as String,
      title: m['title'] as String,
      kind: '${m['kind'] ?? ''}',
      at: at is int ? DateTime.fromMillisecondsSinceEpoch(at) : null,
    );
  }
}

@immutable
class QuickAccess {
  const QuickAccess({this.recents = const [], this.starred = const []});

  final List<QuickLink> recents;
  final List<QuickLink> starred;

  bool isStarred(String path) => starred.any((s) => s.path == path);
}

/// Recently opened and starred pages of one project, like PostHog's
/// Recents / Starred. Kept on this device.
class QuickAccessController extends Notifier<QuickAccess> {
  QuickAccessController(this.projectId);

  final String projectId;

  static const maxRecents = 8;
  static const maxStarred = 20;

  String get _key => 'quick_access_$projectId';

  @override
  QuickAccess build() {
    final raw = ref.watch(sharedPreferencesProvider).getString(_key);
    if (raw == null) return const QuickAccess();
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      List<QuickLink> read(String k) =>
          ((m[k] as List?) ?? const []).map(QuickLink.fromJson).whereType<QuickLink>().toList();
      return QuickAccess(recents: read('recents'), starred: read('starred'));
    } catch (_) {
      return const QuickAccess();
    }
  }

  void _save(QuickAccess next) {
    state = next;
    ref.read(sharedPreferencesProvider).setString(
      _key,
      jsonEncode({
        'recents': [for (final r in next.recents) r.toJson()],
        'starred': [for (final s in next.starred) s.toJson()],
      }),
    );
  }

  /// Moves [link] to the top of Recents.
  void visit(QuickLink link) {
    final recents = state.recents;
    if (recents.isNotEmpty && recents.first.path == link.path && recents.first.title == link.title) return;
    final stamped = QuickLink(path: link.path, title: link.title, kind: link.kind, at: DateTime.now());
    _save(
      QuickAccess(
        recents: [stamped, ...recents.where((r) => r.path != link.path)].take(maxRecents).toList(),
        starred: state.starred,
      ),
    );
  }

  void toggleStar(QuickLink link) {
    final starred = state.isStarred(link.path)
        ? state.starred.where((s) => s.path != link.path).toList()
        : [...state.starred, link].take(maxStarred).toList();
    _save(QuickAccess(recents: state.recents, starred: starred));
  }

  /// Keeps a starred or recent item's title current (e.g. a renamed dashboard).
  void rename(String path, String title) {
    QuickLink fix(QuickLink l) => l.path == path ? QuickLink(path: l.path, title: title, kind: l.kind, at: l.at) : l;
    if (!state.recents.any((l) => l.path == path) && !state.starred.any((l) => l.path == path)) return;
    _save(QuickAccess(recents: state.recents.map(fix).toList(), starred: state.starred.map(fix).toList()));
  }

  void remove(String path) => _save(
    QuickAccess(
      recents: state.recents.where((l) => l.path != path).toList(),
      starred: state.starred.where((l) => l.path != path).toList(),
    ),
  );
}

final quickAccessProvider = NotifierProvider.family<QuickAccessController, QuickAccess, String>(
  QuickAccessController.new,
);
