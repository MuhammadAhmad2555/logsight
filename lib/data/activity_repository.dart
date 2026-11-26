import 'package:cloud_firestore/cloud_firestore.dart';

import 'activity.dart';
import 'log_repository.dart';

/// One page of events.
class EventPage {
  const EventPage({required this.events, required this.cursor, required this.hasMore, required this.scanned});

  final List<ActivityEvent> events;
  final DocumentSnapshot<Map<String, dynamic>>? cursor;
  final bool hasMore;
  final int scanned;
}

/// Reads events, people and event definitions.
///
/// Like logs, the parts of a query Firestore can run (with the deployed
/// indexes) are sent to Firestore; the rest are applied in the app.
class ActivityRepository {
  ActivityRepository(this._db);

  final FirebaseFirestore _db;

  static const pageSize = 100;

  DocumentReference<Map<String, dynamic>> _p(String pid) => _db.collection('projects').doc(pid);

  /// Indexed combinations: event, distinctId, sessionId, service,
  /// event+service, distinctId+event (each with ts).
  Query<Map<String, dynamic>> serverQuery(String pid, ActivityQuery q, {required DateTime from, DateTime? to}) {
    var query = _p(pid).collection('events').where('ts', isGreaterThanOrEqualTo: Timestamp.fromDate(from));
    if (to != null) query = query.where('ts', isLessThan: Timestamp.fromDate(to));

    final oneEvent = q.events.length == 1 ? q.events.first : null;
    if (q.distinctIds.isNotEmpty && q.distinctIds.length <= 30) {
      query = query.where('distinctId', whereIn: q.distinctIds);
      if (oneEvent != null) query = query.where('event', isEqualTo: oneEvent);
    } else if (q.sessionId != null) {
      query = query.where('sessionId', isEqualTo: q.sessionId);
    } else if (q.events.isNotEmpty && q.events.length <= 30) {
      query = q.events.length == 1
          ? query.where('event', isEqualTo: oneEvent)
          : query.where('event', whereIn: q.events);
      if (q.services.length == 1) query = query.where('service', isEqualTo: q.services.first);
    } else if (q.services.length == 1) {
      query = query.where('service', isEqualTo: q.services.first);
    }
    return query.orderBy('ts', descending: true);
  }

  Future<EventPage> fetchPage(
    String pid,
    ActivityQuery q, {
    DocumentSnapshot<Map<String, dynamic>>? after,
    int want = 50,
    int maxScan = 1000,
    int pageSize = ActivityRepository.pageSize,
  }) async {
    final (from, to) = q.range.resolve();
    final base = serverQuery(pid, q, from: from, to: to);
    final out = <ActivityEvent>[];
    var cursor = after;
    var scanned = 0;
    var hasMore = true;
    while (out.length < want && scanned < maxScan) {
      var page = base.limit(pageSize);
      if (cursor != null) page = page.startAfterDocument(cursor);
      final snap = await page.get();
      scanned += snap.docs.length;
      for (final d in snap.docs) {
        final e = ActivityEvent.fromDoc(d);
        if (q.matches(e)) out.add(e);
      }
      if (snap.docs.isNotEmpty) cursor = snap.docs.last;
      if (snap.docs.length < pageSize) {
        hasMore = false;
        break;
      }
    }
    return EventPage(events: out, cursor: cursor, hasMore: hasMore, scanned: scanned);
  }

  /// Live: matching events that reached the server at or after [since],
  /// re-emitted as more arrive. Follows the server's `receivedAt`, not the
  /// device's `ts` (see [LogRepository.watchArrivals] for why).
  Stream<List<ActivityEvent>> watchArrivals(String pid, ActivityQuery q, {required DateTime since, int limit = 200}) =>
      _p(pid)
          .collection('events')
          .where('receivedAt', isGreaterThanOrEqualTo: Timestamp.fromDate(since))
          .orderBy('receivedAt', descending: true)
          .limit(limit)
          .snapshots()
          .map((s) => s.docs.map(ActivityEvent.fromDoc).where(q.matches).toList());

  Future<List<VolumeBucket>> volume(String pid, ActivityQuery q, {int maxBuckets = 40}) {
    final (from, to) = q.range.resolve();
    return countVolume((f, t) => serverQuery(pid, q, from: f, to: t), from: from, to: to, maxBuckets: maxBuckets);
  }

  Future<int> count(String pid, ActivityQuery q) async {
    final (from, to) = q.range.resolve();
    return (await serverQuery(pid, q, from: from, to: to).count().get()).count ?? 0;
  }

  // ----------------------------------------------------------------- people

  Stream<List<Person>> watchPeople(String pid, {int limit = 500}) => _p(pid)
      .collection('persons')
      .orderBy('lastSeen', descending: true)
      .limit(limit)
      .snapshots()
      .map((s) => s.docs.map(Person.fromDoc).toList());

  Stream<Person?> watchPerson(String pid, String id) =>
      _p(pid).collection('persons').doc(id).snapshots().map((d) => d.exists ? Person.fromDoc(d) : null);

  /// Finds the person whose aliases include [id] (an anonymous ID).
  Future<Person?> personByAlias(String pid, String id) async {
    final s = await _p(pid).collection('persons').where('aliases', arrayContains: id).limit(1).get();
    return s.docs.isEmpty ? null : Person.fromDoc(s.docs.first);
  }

  Future<void> deletePerson(String pid, String id) => _p(pid).collection('persons').doc(id).delete();

  // ------------------------------------------------------------ definitions

  Stream<List<EventDefinition>> watchDefinitions(String pid) => _p(pid)
      .collection('eventDefs')
      .snapshots()
      .map((s) => s.docs.map(EventDefinition.fromDoc).toList()..sort((a, b) => a.name.compareTo(b.name)));

  Future<void> updateDefinition(String pid, String name, String uid, {String? description, bool? verified}) => _p(
    pid,
  ).collection('eventDefs').doc(name).update({'description': ?description, 'verified': ?verified, 'updatedBy': uid});

  /// Adds an event name seen in the explorer that no SDK registered
  /// (e.g. events sent with plain HTTP).
  Future<void> registerDefinition(String pid, String name, Iterable<String> properties) {
    if (name.isEmpty || name.contains('/') || name.length > 200) return Future.value();
    return _p(pid).collection('eventDefs').doc(name).set({
      'lastSeen': FieldValue.serverTimestamp(),
      'properties': FieldValue.arrayUnion(properties.take(300).toList()),
    }, SetOptions(merge: true));
  }
}
