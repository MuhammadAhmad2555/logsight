import 'package:flutter_test/flutter_test.dart';
import 'package:trackapp/features/help/help_model.dart';
import 'package:trackapp/features/help/help_screen.dart';

void main() {
  test('topic IDs are unique and related links point to real topics', () {
    final ids = helpTopics.map((t) => t.id).toList();
    expect(ids.toSet().length, ids.length);
    for (final t in helpTopics) {
      expect(t.blocks, isNotEmpty, reason: t.id);
      for (final r in t.related) {
        expect(ids, contains(r), reason: '${t.id} → $r');
      }
    }
  });

  test('every category has topics and Quick start comes first', () {
    for (final c in HelpCategory.values) {
      expect(helpTopics.where((t) => t.category == c), isNotEmpty, reason: c.name);
    }
    expect(helpTopics.first.id, 'start');
  });

  test('search finds the right topic first', () {
    String best(String q) => (helpTopics.map((t) => (t, t.score(q))).where((r) => r.$2 > 0).toList()
          ..sort((a, b) => b.$2.compareTo(a.$2)))
        .first
        .$1
        .id;
    expect(best('errors'), 'errors');
    expect(best('feature flags'), anyOf('flags-sdk', 'flags'));
    expect(best('endpoints'), anyOf('endpoints', 'endpoints-sdk'));
    expect(helpTopics.where((t) => t.score('reason') > 0).map((t) => t.id), contains('errors'));
    expect(helpTopics.where((t) => t.score('zzzz nothing') > 0), isEmpty);
  });

  test('every page in the app has a help topic', () {
    const pages = [
      'overview', 'activity', 'logs-page', 'issues', 'dashboards', 'endpoints', 'people',
      'alerts', 'flags', 'data', 'keys', 'members', 'settings',
    ];
    for (final p in pages) {
      expect(helpTopic(p), isNotNull, reason: p);
    }
  });
}
