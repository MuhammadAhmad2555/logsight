import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'log_query.dart';

/// A product event (PostHog-style): `$screen`, `$identify`, `purchase_completed`…
class ActivityEvent {
  const ActivityEvent({
    required this.id,
    required this.event,
    required this.distinctId,
    required this.timestamp,
    required this.properties,
    this.receivedAt,
    this.sessionId,
    this.service,
  });

  final String id;
  final String event;
  final String distinctId;
  final DateTime timestamp;
  final DateTime? receivedAt;
  final String? sessionId;
  final String? service;
  final Map<String, dynamic> properties;

  factory ActivityEvent.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return ActivityEvent(
      id: doc.id,
      event: d['event'] as String? ?? '',
      distinctId: d['distinctId'] as String? ?? '',
      timestamp: (d['ts'] as Timestamp?)?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0),
      receivedAt: (d['receivedAt'] as Timestamp?)?.toDate(),
      sessionId: d['sessionId'] as String?,
      service: d['service'] as String?,
      properties: (d['properties'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }

  /// Friendly name for built-in events.
  String get label => switch (event) {
    r'$screen' => 'Screen: ${properties[r'$screen_name'] ?? ''}'.trim(),
    r'$pageview' => 'Pageview',
    r'$identify' => 'Identify',
    _ => event,
  };

  /// A built-in field or property (dot paths into nested maps allowed).
  Object? field(String key) {
    switch (key) {
      case 'event':
        return event;
      case 'distinctId':
      case 'person':
        return distinctId;
      case 'sessionId':
        return sessionId;
      case 'service':
      case 'service.name':
        return service;
    }
    if (properties.containsKey(key)) return properties[key];
    Object? cur = properties;
    for (final part in key.split('.')) {
      if (cur is Map && cur.containsKey(part)) {
        cur = cur[part];
      } else {
        return null;
      }
    }
    return cur;
  }
}

/// A person (PostHog-style): one doc per distinct ID, with merged properties.
class Person {
  const Person({required this.id, required this.properties, required this.aliases, this.firstSeen, this.lastSeen});

  final String id;
  final Map<String, dynamic> properties;

  /// Other distinct IDs that belong to this person (e.g. the anonymous ID
  /// used before sign-in).
  final List<String> aliases;
  final DateTime? firstSeen;
  final DateTime? lastSeen;

  /// All IDs whose events belong to this person.
  List<String> get allIds => {id, ...aliases}.toList();

  bool get isAnonymous => id.startsWith('anon_') && properties.isEmpty;

  /// Best human label: email, then name, then the ID.
  String get displayName {
    for (final k in const ['email', r'$email', 'name', r'$name', 'username']) {
      final v = properties[k];
      if (v is String && v.trim().isNotEmpty) return v;
    }
    return id;
  }

  factory Person.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    final first = d['firstSeen'];
    return Person(
      id: doc.id,
      properties: (d['properties'] as Map?)?.cast<String, dynamic>() ?? const {},
      aliases: ((d['aliases'] as List?) ?? const []).map((e) => '$e').toList(),
      firstSeen: first is num
          ? DateTime.fromMillisecondsSinceEpoch(first.toInt())
          : (first is Timestamp ? first.toDate() : null),
      lastSeen: (d['lastSeen'] as Timestamp?)?.toDate(),
    );
  }

  bool matchesSearch(String q) {
    final s = q.trim().toLowerCase();
    if (s.isEmpty) return true;
    if (id.toLowerCase().contains(s)) return true;
    if (aliases.any((a) => a.toLowerCase().contains(s))) return true;
    return properties.values.any((v) => v is String && v.toLowerCase().contains(s));
  }
}

/// An event name seen in the project, with team-written description.
class EventDefinition {
  const EventDefinition({
    required this.name,
    required this.properties,
    this.description,
    this.verified = false,
    this.lastSeen,
  });

  final String name;
  final List<String> properties;
  final String? description;
  final bool verified;
  final DateTime? lastSeen;

  factory EventDefinition.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return EventDefinition(
      name: doc.id,
      properties: ((d['properties'] as List?) ?? const []).map((e) => '$e').toList()..sort(),
      description: d['description'] as String?,
      verified: d['verified'] as bool? ?? false,
      lastSeen: (d['lastSeen'] as Timestamp?)?.toDate(),
    );
  }
}

/// Filters for the Activity explorer. Kept in the URL so views can be shared.
@immutable
class ActivityQuery {
  const ActivityQuery({
    this.range = const TimeRange.relative(RelativePreset.h24),
    this.events = const [],
    this.distinctIds = const [],
    this.sessionId,
    this.services = const [],
    this.filters = const [],
  });

  final TimeRange range;
  final List<String> events;

  /// A person's IDs (their own + aliases).
  final List<String> distinctIds;
  final String? sessionId;
  final List<String> services;

  /// Property filters (reuses the Logs filter model).
  final List<AttrFilter> filters;

  bool get hasFilters =>
      events.isNotEmpty || distinctIds.isNotEmpty || sessionId != null || services.isNotEmpty || filters.isNotEmpty;

  bool matches(ActivityEvent e) {
    if (events.isNotEmpty && !events.contains(e.event)) return false;
    if (distinctIds.isNotEmpty && !distinctIds.contains(e.distinctId)) return false;
    if (sessionId != null && e.sessionId != sessionId) return false;
    if (services.isNotEmpty && !services.contains(e.service)) return false;
    for (final f in filters) {
      if (!f.test(e.field(f.key))) return false;
    }
    return true;
  }

  ActivityQuery copyWith({
    TimeRange? range,
    List<String>? events,
    List<String>? distinctIds,
    String? sessionId,
    bool clearSession = false,
    List<String>? services,
    List<AttrFilter>? filters,
  }) => ActivityQuery(
    range: range ?? this.range,
    events: events ?? this.events,
    distinctIds: distinctIds ?? this.distinctIds,
    sessionId: clearSession ? null : (sessionId ?? this.sessionId),
    services: services ?? this.services,
    filters: filters ?? this.filters,
  );

  Map<String, dynamic> toQueryParameters() {
    final p = <String, dynamic>{};
    if (range.isRelative) {
      p['range'] = range.preset!.id;
    } else {
      p['from'] = range.from!.toUtc().toIso8601String();
      p['to'] = range.to!.toUtc().toIso8601String();
    }
    if (events.isNotEmpty) p['ev'] = events;
    if (distinctIds.isNotEmpty) p['person'] = distinctIds;
    if (sessionId != null) p['session'] = sessionId;
    if (services.isNotEmpty) p['service'] = services;
    if (filters.isNotEmpty) p['f'] = filters.map((f) => f.encode()).toList();
    return p;
  }

  static ActivityQuery fromUri(Uri uri) {
    final base = LogQuery.fromUri(uri); // reuses range + filter parsing
    final all = uri.queryParametersAll;
    return ActivityQuery(
      range: base.range,
      events: (all['ev'] ?? const []).where((s) => s.isNotEmpty).toList(),
      distinctIds: (all['person'] ?? const []).where((s) => s.isNotEmpty).toList(),
      sessionId: uri.queryParameters['session'],
      services: base.services,
      filters: base.filters,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ActivityQuery &&
      other.range == range &&
      listEquals(other.events, events) &&
      listEquals(other.distinctIds, distinctIds) &&
      other.sessionId == sessionId &&
      listEquals(other.services, services) &&
      listEquals(other.filters, filters);

  @override
  int get hashCode => Object.hash(
    range,
    Object.hashAll(events),
    Object.hashAll(distinctIds),
    sessionId,
    Object.hashAll(services),
    Object.hashAll(filters),
  );
}

/// Events grouped into one session.
class SessionSummary {
  SessionSummary(this.id);

  final String id;
  final List<ActivityEvent> events = [];
  DateTime get start => events.map((e) => e.timestamp).reduce((a, b) => a.isBefore(b) ? a : b);
  DateTime get end => events.map((e) => e.timestamp).reduce((a, b) => a.isAfter(b) ? a : b);
  Duration get duration => end.difference(start);
  Set<String> get services => events.map((e) => e.service).whereType<String>().toSet();
}

/// Groups events by session, newest session first. Events without a
/// session ID are left out.
List<SessionSummary> groupSessions(Iterable<ActivityEvent> events) {
  final map = <String, SessionSummary>{};
  for (final e in events) {
    final s = e.sessionId;
    if (s == null || s.isEmpty) continue;
    map.putIfAbsent(s, () => SessionSummary(s)).events.add(e);
  }
  return map.values.toList()..sort((a, b) => b.start.compareTo(a.start));
}
