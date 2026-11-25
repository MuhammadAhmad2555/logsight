import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'models.dart';

/// Saved views, error-issue status and alerts for a project.
class InsightsRepository {
  InsightsRepository(this._db);

  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> _p(String pid) => _db.collection('projects').doc(pid);

  // ------------------------------------------------------------------ views

  Stream<List<SavedView>> watchViews(String pid) => _p(pid)
      .collection('views')
      .snapshots()
      .map(
        (s) =>
            s.docs.map(SavedView.fromDoc).toList()
              ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())),
      );

  Future<void> saveView(String pid, User user, String name, String query) => _p(pid).collection('views').add({
    'name': name.trim(),
    'query': query,
    'createdBy': user.uid,
    'createdAt': FieldValue.serverTimestamp(),
  });

  Future<void> deleteView(String pid, String id) => _p(pid).collection('views').doc(id).delete();

  // ----------------------------------------------------------------- issues

  Stream<Map<String, IssueState>> watchIssues(String pid) =>
      _p(pid).collection('issues').snapshots().map((s) => {for (final d in s.docs) d.id: IssueState.fromDoc(d)});

  Future<void> setIssueStatus(String pid, String fingerprint, IssueStatus status) =>
      _p(pid).collection('issues').doc(fingerprint).set({
        'status': status.name,
        'resolvedAt': status == IssueStatus.resolved ? FieldValue.serverTimestamp() : null,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

  Future<void> assignIssue(String pid, String fingerprint, User? user) =>
      _p(pid).collection('issues').doc(fingerprint).set({
        'assigneeUid': user?.uid,
        'assigneeEmail': user?.email?.toLowerCase(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

  // ----------------------------------------------------------------- alerts

  Stream<List<AlertRule>> watchAlerts(String pid) => _p(pid)
      .collection('alerts')
      .snapshots()
      .map(
        (s) =>
            s.docs.map(AlertRule.fromDoc).toList()
              ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())),
      );

  Future<void> saveAlert(String pid, AlertRule rule, {required String uid}) {
    final col = _p(pid).collection('alerts');
    final data = {...rule.toMap(), 'updatedBy': uid, 'updatedAt': FieldValue.serverTimestamp()};
    return rule.id.isEmpty ? col.add({...data, 'firing': false}) : col.doc(rule.id).update(data);
  }

  Future<void> deleteAlert(String pid, String id) => _p(pid).collection('alerts').doc(id).delete();

  Stream<List<AlertEvent>> watchAlertEvents(String pid, {int limit = 50}) => _p(pid)
      .collection('alertEvents')
      .orderBy('at', descending: true)
      .limit(limit)
      .snapshots()
      .map((s) => s.docs.map(AlertEvent.fromDoc).toList());
}
