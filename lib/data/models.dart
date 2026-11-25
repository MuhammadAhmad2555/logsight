import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/patterns.dart';
import '../core/severity.dart';

enum ProjectRole {
  owner,
  admin,
  viewer;

  static ProjectRole parse(String? v) =>
      ProjectRole.values.firstWhere((r) => r.name == v, orElse: () => ProjectRole.viewer);

  bool get canManageKeys => this == owner || this == admin;
  bool get canDeleteLogs => this == owner || this == admin;
  bool get canManageMembers => this == owner;

  String get label => switch (this) {
    owner => 'Owner',
    admin => 'Admin',
    viewer => 'Viewer',
  };
}

class Project {
  const Project({
    required this.id,
    required this.name,
    required this.ownerId,
    required this.members,
    required this.memberEmails,
    this.createdAt,
  });

  final String id;
  final String name;
  final String ownerId;
  final Map<String, ProjectRole> members;
  final Map<String, String> memberEmails;
  final DateTime? createdAt;

  ProjectRole? roleOf(String uid) => members[uid];

  factory Project.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    final rawMembers = (d['members'] as Map?)?.cast<String, dynamic>() ?? {};
    final rawEmails = (d['memberEmails'] as Map?)?.cast<String, dynamic>() ?? {};
    return Project(
      id: doc.id,
      name: d['name'] as String? ?? 'Untitled',
      ownerId: d['ownerId'] as String? ?? '',
      members: rawMembers.map((k, v) => MapEntry(k, ProjectRole.parse(v as String?))),
      memberEmails: rawEmails.map((k, v) => MapEntry(k, '$v')),
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}

class IngestKey {
  const IngestKey({required this.key, required this.name, required this.active, this.createdAt});

  final String key;
  final String name;
  final bool active;
  final DateTime? createdAt;

  String get masked => '${key.substring(0, 8)}…${key.substring(key.length - 4)}';

  factory IngestKey.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return IngestKey(
      key: doc.id,
      name: d['name'] as String? ?? 'Key',
      active: d['active'] as bool? ?? false,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}

/// An app or service that sends logs (its `service.name`), e.g. keyo_ios.
class ServiceInfo {
  const ServiceInfo({required this.name, this.lastSeen});

  final String name;
  final DateTime? lastSeen;

  factory ServiceInfo.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) =>
      ServiceInfo(name: doc.id, lastSeen: (doc.data()?['lastSeen'] as Timestamp?)?.toDate());
}

class Invite {
  const Invite({
    required this.id,
    required this.projectId,
    required this.projectName,
    required this.email,
    required this.role,
    required this.invitedByEmail,
  });

  final String id;
  final String projectId;
  final String projectName;
  final String email;
  final ProjectRole role;
  final String invitedByEmail;

  factory Invite.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return Invite(
      id: doc.id,
      projectId: d['projectId'] as String? ?? '',
      projectName: d['projectName'] as String? ?? '',
      email: d['email'] as String? ?? '',
      role: ProjectRole.parse(d['role'] as String?),
      invitedByEmail: d['invitedByEmail'] as String? ?? '',
    );
  }
}

class LogEntry {
  const LogEntry({
    required this.id,
    required this.timestamp,
    required this.severity,
    required this.message,
    required this.service,
    required this.attributes,
    required this.tokens,
    this.receivedAt,
    this.traceId,
    this.sessionId,
    this.userId,
  });

  final String id;
  final DateTime timestamp;
  final DateTime? receivedAt;
  final Severity severity;
  final String message;
  final String service;
  final Map<String, dynamic> attributes;
  final Set<String> tokens;
  final String? traceId;
  final String? sessionId;
  final String? userId;

  factory LogEntry.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return LogEntry(
      id: doc.id,
      timestamp: (d['ts'] as Timestamp?)?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0),
      receivedAt: (d['receivedAt'] as Timestamp?)?.toDate(),
      severity: Severity.parse(d['severity'] as String?),
      message: d['message'] as String? ?? '',
      service: d['service'] as String? ?? '',
      attributes: (d['attributes'] as Map?)?.cast<String, dynamic>() ?? const {},
      tokens: ((d['tokens'] as List?) ?? const []).map((e) => '$e').toSet(),
      traceId: d['traceId'] as String?,
      sessionId: d['sessionId'] as String?,
      userId: d['userId'] as String?,
    );
  }

  static final Expando<String> _patterns = Expando('pattern');

  /// The message with variable parts replaced, e.g. `Payment failed for order <num>`.
  String get pattern => _patterns[this] ??= patternOf(message);

  /// Groups errors into issues: service + exception type + pattern.
  String get fingerprint => issueFingerprint(service, message, exceptionType: attributes['exception.type']?.toString());

  /// Looks up a field by name: built-in fields first, then attributes
  /// (dot paths such as `device.model` are supported).
  Object? field(String key) {
    switch (key) {
      case 'service':
      case 'service.name':
      case 'service_name':
        return service;
      case 'severity':
        return severity.id;
      case 'pattern':
        return pattern;
      case 'message':
        return message;
      case 'traceId':
        return traceId;
      case 'sessionId':
        return sessionId;
      case 'userId':
        return userId;
    }
    if (attributes.containsKey(key)) return attributes[key];
    Object? cur = attributes;
    for (final part in key.split('.')) {
      if (cur is Map && cur.containsKey(part)) {
        cur = cur[part];
      } else {
        return null;
      }
    }
    return cur;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'timestamp': timestamp.toUtc().toIso8601String(),
    if (receivedAt != null) 'receivedAt': receivedAt!.toUtc().toIso8601String(),
    'severity': severity.id,
    'service': service,
    'message': message,
    if (traceId != null) 'traceId': traceId,
    if (sessionId != null) 'sessionId': sessionId,
    if (userId != null) 'userId': userId,
    'attributes': _jsonSafe(attributes),
  };

  static Object? _jsonSafe(Object? v) {
    if (v is Timestamp) return v.toDate().toUtc().toIso8601String();
    if (v is GeoPoint) return {'lat': v.latitude, 'lng': v.longitude};
    if (v is DocumentReference) return v.path;
    if (v is Map) return v.map((k, e) => MapEntry('$k', _jsonSafe(e)));
    if (v is List) return v.map(_jsonSafe).toList();
    return v;
  }
}

/// A named, shareable set of Logs filters (the URL query string).
class SavedView {
  const SavedView({required this.id, required this.name, required this.query, required this.createdBy, this.createdAt});

  final String id;
  final String name;

  /// URL query string of the Logs page, e.g. `range=24h&service=keyo_ios&sev=error`.
  final String query;
  final String createdBy;
  final DateTime? createdAt;

  factory SavedView.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return SavedView(
      id: doc.id,
      name: d['name'] as String? ?? 'View',
      query: d['query'] as String? ?? '',
      createdBy: d['createdBy'] as String? ?? '',
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}

enum IssueStatus {
  open('Open'),
  resolved('Resolved'),
  ignored('Ignored');

  const IssueStatus(this.label);
  final String label;

  static IssueStatus parse(String? v) => IssueStatus.values.firstWhere((s) => s.name == v, orElse: () => open);
}

/// What the team decided about an error group. Counts and samples come from
/// the logs themselves; this only stores status, assignee and timestamps.
class IssueState {
  const IssueState({
    required this.id,
    required this.status,
    this.assigneeUid,
    this.assigneeEmail,
    this.resolvedAt,
    this.updatedAt,
  });

  final String id;
  final IssueStatus status;
  final String? assigneeUid;
  final String? assigneeEmail;
  final DateTime? resolvedAt;
  final DateTime? updatedAt;

  factory IssueState.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return IssueState(
      id: doc.id,
      status: IssueStatus.parse(d['status'] as String?),
      assigneeUid: d['assigneeUid'] as String?,
      assigneeEmail: d['assigneeEmail'] as String?,
      resolvedAt: (d['resolvedAt'] as Timestamp?)?.toDate(),
      updatedAt: (d['updatedAt'] as Timestamp?)?.toDate(),
    );
  }
}

enum AlertType {
  errorSpike('error_spike', 'Error spike', 'Errors (error + fatal) in the window reach the threshold'),
  logVolume('log_volume', 'Log volume', 'Logs of any level in the window reach the threshold'),
  serviceSilent('service_silent', 'Service went quiet', 'No logs at all from the service during the window');

  const AlertType(this.id, this.label, this.description);
  final String id;
  final String label;
  final String description;

  static AlertType parse(String? v) => AlertType.values.firstWhere((t) => t.id == v, orElse: () => errorSpike);
}

class AlertRule {
  const AlertRule({
    required this.id,
    required this.name,
    required this.type,
    required this.threshold,
    required this.windowMinutes,
    required this.enabled,
    this.service,
    this.webhookUrl,
    this.firing = false,
    this.lastCheckedAt,
    this.lastTriggeredAt,
    this.lastValue,
  });

  final String id;
  final String name;
  final AlertType type;
  final String? service;
  final int threshold;
  final int windowMinutes;
  final bool enabled;
  final String? webhookUrl;

  /// Written by the alerts Cloud Function.
  final bool firing;
  final DateTime? lastCheckedAt;
  final DateTime? lastTriggeredAt;
  final int? lastValue;

  factory AlertRule.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return AlertRule(
      id: doc.id,
      name: d['name'] as String? ?? 'Alert',
      type: AlertType.parse(d['type'] as String?),
      service: d['service'] as String?,
      threshold: (d['threshold'] as num?)?.toInt() ?? 10,
      windowMinutes: (d['windowMinutes'] as num?)?.toInt() ?? 15,
      enabled: d['enabled'] as bool? ?? true,
      webhookUrl: d['webhookUrl'] as String?,
      firing: d['firing'] as bool? ?? false,
      lastCheckedAt: (d['lastCheckedAt'] as Timestamp?)?.toDate(),
      lastTriggeredAt: (d['lastTriggeredAt'] as Timestamp?)?.toDate(),
      lastValue: (d['lastValue'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toMap() => {
    'name': name,
    'type': type.id,
    'service': service,
    'threshold': threshold,
    'windowMinutes': windowMinutes,
    'enabled': enabled,
    'webhookUrl': webhookUrl,
  };
}

/// One firing or recovery of an alert (written by the Cloud Function).
class AlertEvent {
  const AlertEvent({
    required this.id,
    required this.alertId,
    required this.alertName,
    required this.state,
    required this.value,
    required this.at,
    this.webhookStatus,
  });

  final String id;
  final String alertId;
  final String alertName;

  /// `firing` or `resolved`.
  final String state;
  final int value;
  final DateTime at;
  final String? webhookStatus;

  factory AlertEvent.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return AlertEvent(
      id: doc.id,
      alertId: d['alertId'] as String? ?? '',
      alertName: d['alertName'] as String? ?? '',
      state: d['state'] as String? ?? 'firing',
      value: (d['value'] as num?)?.toInt() ?? 0,
      at: (d['at'] as Timestamp?)?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0),
      webhookStatus: d['webhookStatus'] as String?,
    );
  }
}
