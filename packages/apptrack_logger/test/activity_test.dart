import 'dart:convert';

import 'package:apptrack_logger/apptrack_logger.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  late List<List<Map<String, dynamic>>> commits;
  late AppTrackLogger t;

  setUp(() {
    commits = [];
    t = AppTrackLogger(
      firebaseProjectId: 'fb',
      projectId: 'p1',
      ingestKey: 'atk_k',
      service: 'keyo_ios',
      client: MockClient((req) async {
        commits.add(((jsonDecode(req.body) as Map)['writes'] as List).cast<Map<String, dynamic>>());
        return http.Response('{}', 200);
      }),
    );
  });

  String name(Map<String, dynamic> w) => w['update']['name'] as String;

  test('starts anonymous; capture writes an event with distinctId and properties', () async {
    expect(t.distinctId, startsWith('anon_'));
    t.capture('purchase_completed', properties: {'plan': 'pro', 'amount': 9.99});
    await t.close();

    final events = commits.expand((c) => c).where((w) => name(w).contains('/events/')).toList();
    expect(events, hasLength(1));
    final f = events.single['update']['fields'] as Map;
    expect(f['event'], {'stringValue': 'purchase_completed'});
    expect(f['distinctId'], {'stringValue': t.distinctId});
    expect(f['service'], {'stringValue': 'keyo_ios'});
    expect(f['properties']['mapValue']['fields']['amount'], {'doubleValue': 9.99});
    expect(f.containsKey('_kind'), isFalse);
    expect(events.single['currentDocument'], {'exists': false});
  });

  test('event definitions are registered once per name, again only for new properties', () async {
    t.capture('signed_up', properties: {'method': 'apple'});
    t.capture('signed_up', properties: {'method': 'email'});
    t.capture('signed_up', properties: {'method': 'email', 'referrer': 'x'});
    await t.close();
    final defs = commits.expand((c) => c).where((w) => name(w).endsWith('/eventDefs/signed_up')).toList();
    expect(defs, hasLength(2));
    List<String> added(Map<String, dynamic> w) => [
      for (final v in (w['updateTransforms'] as List).last['appendMissingElements']['values'] as List) v['stringValue'] as String,
    ];
    expect(added(defs[0]), ['method']);
    expect(added(defs[1]), ['referrer']);
  });

  test('identify links the anonymous ID and sets person properties in a separate request', () async {
    final anon = t.distinctId;
    t.identify('user_42', properties: {'email': 'a@x.com', 'plan': 'pro'});
    t.capture('opened_settings');
    await t.close();

    expect(t.distinctId, 'user_42');
    expect(t.userId, 'user_42');
    // Events/logs and profile updates never share a request.
    for (final c in commits) {
      final hasEvents = c.any((w) => name(w).contains('/events/'));
      final hasPeople = c.any((w) => name(w).contains('/persons/'));
      expect(hasEvents && hasPeople, isFalse);
    }
    final events = commits.expand((c) => c).where((w) => name(w).contains('/events/')).toList();
    expect(events.map((e) => e['update']['fields']['event']['stringValue']), [r'$identify', 'opened_settings']);
    expect(events.first['update']['fields']['properties']['mapValue']['fields'][r'$anon_distinct_id'], {'stringValue': anon});

    final person = commits.expand((c) => c).firstWhere((w) => name(w).endsWith('/persons/user_42'));
    expect(person['updateMask']['fieldPaths'], ['key', 'properties.`email`', 'properties.`plan`']);
    final transforms = person['updateTransforms'] as List;
    expect(transforms.map((x) => x['fieldPath']), ['lastSeen', 'firstSeen', 'aliases']);
    expect(transforms[2]['appendMissingElements']['values'], [{'stringValue': anon}]);
  });

  test('reset starts a new anonymous person', () {
    t.identify('user_42');
    t.reset();
    expect(t.distinctId, startsWith('anon_'));
    expect(t.userId, isNull);
  });

  test('screen() captures \$screen with the screen name', () async {
    t.screen('Settings');
    await t.close();
    final e = commits.expand((c) => c).firstWhere((w) => name(w).contains('/events/'));
    expect(e['update']['fields']['event'], {'stringValue': r'$screen'});
    expect(e['update']['fields']['properties']['mapValue']['fields'][r'$screen_name'], {'stringValue': 'Settings'});
  });
}
