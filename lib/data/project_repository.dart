import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../core/tokenizer.dart';
import 'models.dart';

/// Projects, members, invites and ingest keys.
class ProjectRepository {
  ProjectRepository(this._db);

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> get _projects => _db.collection('projects');
  CollectionReference<Map<String, dynamic>> get _invites => _db.collection('invites');

  Stream<List<Project>> watchMyProjects(String uid) => _projects
      .where('memberIds', arrayContains: uid)
      .snapshots()
      .map(
        (s) =>
            s.docs.map(Project.fromDoc).toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())),
      );

  Stream<Project?> watchProject(String pid) =>
      _projects.doc(pid).snapshots().map((d) => d.exists ? Project.fromDoc(d) : null);

  /// Creates a project with a first ingest key. Returns the project ID.
  Future<String> createProject(User user, String name) async {
    final ref = _projects.doc();
    await ref.set({
      'name': name.trim(),
      'ownerId': user.uid,
      'members': {user.uid: 'owner'},
      'memberIds': [user.uid],
      'memberEmails': {user.uid: (user.email ?? '').toLowerCase()},
      'createdAt': FieldValue.serverTimestamp(),
    });
    await createKey(ref.id, user.uid, 'Default key');
    return ref.id;
  }

  Future<void> renameProject(String pid, String name) => _projects.doc(pid).update({'name': name.trim()});

  /// Deletes a project and its data. Logs and keys go first, because the
  /// security rules check project membership.
  Future<void> deleteProject(String pid, {void Function(int deleted)? onProgress}) async {
    var total = 0;
    total += await _deleteAll(_projects.doc(pid).collection('logs').limit(400), (n) {
      onProgress?.call(total + n);
    });
    await _deleteAll(_projects.doc(pid).collection('ingestKeys').limit(400), null);
    final invites = await _invites.where('projectId', isEqualTo: pid).get();
    for (final d in invites.docs) {
      await d.reference.delete();
    }
    await _projects.doc(pid).delete();
  }

  /// Deletes logs older than [cutoff]. Returns how many were removed.
  Future<int> deleteLogsBefore(String pid, DateTime cutoff, {void Function(int deleted)? onProgress}) => _deleteAll(
    _projects.doc(pid).collection('logs').where('ts', isLessThan: Timestamp.fromDate(cutoff)).limit(400),
    onProgress,
  );

  Future<int> _deleteAll(Query<Map<String, dynamic>> query, void Function(int deleted)? onProgress) async {
    var deleted = 0;
    while (true) {
      final snap = await query.get();
      if (snap.docs.isEmpty) return deleted;
      final batch = _db.batch();
      for (final d in snap.docs) {
        batch.delete(d.reference);
      }
      await batch.commit();
      deleted += snap.docs.length;
      onProgress?.call(deleted);
    }
  }

  // ------------------------------------------------------------------ members

  Future<void> setMemberRole(Project p, String uid, ProjectRole role) =>
      _projects.doc(p.id).update({'members.$uid': role.name});

  Future<void> removeMember(Project p, String uid) => _projects.doc(p.id).update({
    'members.$uid': FieldValue.delete(),
    'memberEmails.$uid': FieldValue.delete(),
    'memberIds': FieldValue.arrayRemove([uid]),
  });

  Future<void> leaveProject(Project p, String uid) => removeMember(p, uid);

  // ------------------------------------------------------------------ invites

  Stream<List<Invite>> watchInvitesFor(String email) => _invites
      .where('email', isEqualTo: email.toLowerCase())
      .snapshots()
      .map((s) => s.docs.map(Invite.fromDoc).toList());

  Stream<List<Invite>> watchProjectInvites(String pid) =>
      _invites.where('projectId', isEqualTo: pid).snapshots().map((s) => s.docs.map(Invite.fromDoc).toList());

  Future<void> invite(Project p, User inviter, String email, ProjectRole role) {
    final e = email.trim().toLowerCase();
    return _invites.doc('${p.id}_$e').set({
      'projectId': p.id,
      'projectName': p.name,
      'email': e,
      'role': role.name,
      'invitedBy': inviter.uid,
      'invitedByEmail': (inviter.email ?? '').toLowerCase(),
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> cancelInvite(String inviteId) => _invites.doc(inviteId).delete();

  /// Joins the project with the invited role, then removes the invite.
  Future<void> acceptInvite(Invite invite, User user) async {
    await _projects.doc(invite.projectId).update({
      'members.${user.uid}': invite.role.name,
      'memberIds': FieldValue.arrayUnion([user.uid]),
      'memberEmails.${user.uid}': (user.email ?? '').toLowerCase(),
    });
    await _invites.doc(invite.id).delete();
  }

  // ------------------------------------------------------------------- services

  Stream<List<ServiceInfo>> watchServices(String pid) => _projects
      .doc(pid)
      .collection('services')
      .snapshots()
      .map(
        (s) =>
            s.docs.map(ServiceInfo.fromDoc).toList()
              ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())),
      );

  /// Adds a service seen in logs to the project's service list.
  Future<void> registerService(String pid, String name) {
    if (!isValidServiceId(name)) return Future.value();
    return _projects.doc(pid).collection('services').doc(name).set({
      'lastSeen': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> deleteService(String pid, String name) => _projects.doc(pid).collection('services').doc(name).delete();

  // ----------------------------------------------------------------- ingest keys

  Stream<List<IngestKey>> watchKeys(String pid) => _projects
      .doc(pid)
      .collection('ingestKeys')
      .snapshots()
      .map(
        (s) =>
            s.docs.map(IngestKey.fromDoc).toList()
              ..sort((a, b) => (b.createdAt ?? DateTime(3000)).compareTo(a.createdAt ?? DateTime(3000))),
      );

  Future<String> createKey(String pid, String uid, String name) async {
    final key = generateIngestKey();
    await _projects.doc(pid).collection('ingestKeys').doc(key).set({
      'name': name.trim(),
      'active': true,
      'createdAt': FieldValue.serverTimestamp(),
      'createdBy': uid,
    });
    return key;
  }

  Future<void> setKeyActive(String pid, String key, bool active) =>
      _projects.doc(pid).collection('ingestKeys').doc(key).update({'active': active});

  Future<void> deleteKey(String pid, String key) => _projects.doc(pid).collection('ingestKeys').doc(key).delete();

  /// Writes one log through the same path (and rules) that apps use.
  Future<void> sendTestLog(String pid, String key, {String? userEmail}) {
    const message = 'Test log from the LogSight dashboard';
    return _projects.doc(pid).collection('logs').add({
      'ts': Timestamp.now(),
      'receivedAt': FieldValue.serverTimestamp(),
      'severity': 'info',
      'message': message,
      'service': 'logsight_dashboard',
      'key': key,
      'tokens': tokenize(message),
      'attributes': {'source': 'test', 'sent_by': ?userEmail},
    });
  }
}

/// Service names that can be a Firestore document ID (same rule as the SDK).
bool isValidServiceId(String s) =>
    s.isNotEmpty && s.length <= 100 && RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(s) && s != '.' && s != '..';

/// A random 40-character key, e.g. `atk_3Fh…`. Uses a secure RNG.
String generateIngestKey() {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  final rnd = Random.secure();
  return 'atk_${List.generate(40, (_) => chars[rnd.nextInt(chars.length)]).join()}';
}
