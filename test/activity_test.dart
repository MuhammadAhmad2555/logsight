import 'package:flutter_test/flutter_test.dart';
import 'package:trackapp/data/activity.dart';
import 'package:trackapp/data/log_query.dart';

ActivityEvent _e(String id, String event, {String who = 'u1', String? session, int minute = 0, Map<String, dynamic> props = const {}}) =>
    ActivityEvent(
      id: id,
      event: event,
      distinctId: who,
      timestamp: DateTime.utc(2026, 11, 26, 10, minute),
      properties: props,
      sessionId: session,
      service: 'keyo_ios',
    );

void main() {
  test('ActivityQuery survives the URL round trip', () {
    final q = ActivityQuery(
      range: TimeRange.absolute(DateTime.utc(2026, 11, 1), DateTime.utc(2026, 11, 2)),
      events: const ['purchase_completed', r'$screen'],
      distinctIds: const ['user_1', 'anon_x'],
      sessionId: 's1',
      services: const ['keyo_ios'],
      filters: const [AttrFilter('plan', FilterOp.equals, 'pro')],
    );
    final uri = Uri.parse(Uri(path: '/p/x/activity', queryParameters: q.toQueryParameters()).toString());
    expect(ActivityQuery.fromUri(uri), q);
  });

  test('matches events, person IDs, sessions and nested properties', () {
    final e = _e('1', 'purchase_completed', session: 's1', props: {'plan': 'pro', 'cart': {'items': 3}});
    expect(const ActivityQuery(events: ['purchase_completed']).matches(e), isTrue);
    expect(const ActivityQuery(events: ['signed_up']).matches(e), isFalse);
    expect(const ActivityQuery(distinctIds: ['anon', 'u1']).matches(e), isTrue);
    expect(const ActivityQuery(sessionId: 's2').matches(e), isFalse);
    expect(const ActivityQuery(filters: [AttrFilter('cart.items', FilterOp.equals, '3')]).matches(e), isTrue);
    expect(const ActivityQuery(filters: [AttrFilter('plan', FilterOp.notEquals, 'pro')]).matches(e), isFalse);
  });

  test('event labels for built-in events', () {
    expect(_e('1', r'$screen', props: {r'$screen_name': 'Settings'}).label, 'Screen: Settings');
    expect(_e('2', r'$identify').label, 'Identify');
    expect(_e('3', 'signed_up').label, 'signed_up');
  });

  test('Person display name, IDs, anonymity and search', () {
    const p = Person(id: 'user_1', properties: {'email': 'a@x.com', 'plan': 'pro'}, aliases: ['anon_9']);
    expect(p.displayName, 'a@x.com');
    expect(p.allIds, ['user_1', 'anon_9']);
    expect(p.isAnonymous, isFalse);
    expect(p.matchesSearch('anon_9'), isTrue);
    expect(p.matchesSearch('PRO'), isTrue);
    expect(p.matchesSearch('zzz'), isFalse);
    expect(const Person(id: 'anon_abc', properties: {}, aliases: []).isAnonymous, isTrue);
  });

  test('groupSessions groups by session, newest first, with duration', () {
    final sessions = groupSessions([
      _e('1', 'a', session: 's1', minute: 1),
      _e('2', 'b', session: 's1', minute: 9),
      _e('3', 'c', session: 's2', minute: 30),
      _e('4', 'd'),
    ]);
    expect(sessions.map((s) => s.id), ['s2', 's1']);
    expect(sessions.last.events, hasLength(2));
    expect(sessions.last.duration, const Duration(minutes: 8));
  });
}
