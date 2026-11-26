import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'activity.dart';
import 'log_query.dart';

enum TileSource {
  logs('Logs'),
  events('Events');

  const TileSource(this.label);
  final String label;
}

enum TileViz {
  number('Number'),
  bars('Bar chart');

  const TileViz(this.label);
  final String label;
}

/// One tile: a count or a volume chart of a saved log or event query.
/// [query] is the query string of a Logs or Activity view
/// (e.g. `service=keyo_ios&sev=error`); its time range is ignored, the
/// dashboard's range is used instead.
@immutable
class DashboardTile {
  const DashboardTile({
    required this.id,
    required this.title,
    required this.source,
    required this.viz,
    this.query = '',
  });

  final String id;
  final String title;
  final TileSource source;
  final TileViz viz;
  final String query;

  static String newId() {
    final r = Random();
    return List.generate(10, (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[r.nextInt(36)]).join();
  }

  Uri get _uri => Uri(query: query);

  LogQuery logQuery(TimeRange range) => LogQuery.fromUri(_uri).copyWith(range: range);

  ActivityQuery activityQuery(TimeRange range) => ActivityQuery.fromUri(_uri).copyWith(range: range);

  Map<String, Object> toMap() => {'id': id, 'title': title, 'source': source.name, 'viz': viz.name, 'query': query};

  static DashboardTile? fromMap(Object? m) {
    if (m is! Map) return null;
    final source = TileSource.values.where((s) => s.name == m['source']).firstOrNull;
    final viz = TileViz.values.where((v) => v.name == m['viz']).firstOrNull;
    if (source == null || viz == null) return null;
    return DashboardTile(
      id: '${m['id'] ?? newId()}',
      title: '${m['title'] ?? ''}',
      source: source,
      viz: viz,
      query: '${m['query'] ?? ''}',
    );
  }

  /// A query string without the time range, for storing in a tile.
  static String queryWithoutRange(Map<String, dynamic> params) {
    final p = Map.of(params)..remove('range')..remove('from')..remove('to');
    return Uri(queryParameters: p.isEmpty ? null : p).query;
  }
}

@immutable
class Dashboard {
  const Dashboard({
    required this.id,
    required this.name,
    this.description = '',
    this.tiles = const [],
    this.range = RelativePreset.h24,
    this.createdBy,
    this.updatedAt,
  });

  final String id;
  final String name;
  final String description;
  final List<DashboardTile> tiles;
  final RelativePreset range;
  final String? createdBy;
  final DateTime? updatedAt;

  static const maxTiles = 30;

  factory Dashboard.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return Dashboard(
      id: doc.id,
      name: d['name'] as String? ?? 'Untitled',
      description: d['description'] as String? ?? '',
      tiles: ((d['tiles'] as List?) ?? const []).map(DashboardTile.fromMap).whereType<DashboardTile>().toList(),
      range: RelativePreset.tryParse(d['range'] as String?) ?? RelativePreset.h24,
      createdBy: d['createdBy'] as String?,
      updatedAt: (d['updatedAt'] as Timestamp?)?.toDate(),
    );
  }
}

class DashboardsRepository {
  DashboardsRepository(this._db);

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> _col(String pid) =>
      _db.collection('projects').doc(pid).collection('dashboards');

  Stream<List<Dashboard>> watchAll(String pid) => _col(pid).snapshots().map(
    (s) => s.docs.map(Dashboard.fromDoc).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())),
  );

  Stream<Dashboard?> watch(String pid, String id) =>
      _col(pid).doc(id).snapshots().map((d) => d.exists ? Dashboard.fromDoc(d) : null);

  Future<String> create(String pid, String name, {required String uid, List<DashboardTile> tiles = const []}) async {
    final ref = await _col(pid).add({
      'name': name.trim(),
      'description': '',
      'tiles': [for (final t in tiles) t.toMap()],
      'range': RelativePreset.h24.id,
      'createdBy': uid,
      'updatedAt': FieldValue.serverTimestamp(),
    });
    return ref.id;
  }

  Future<void> update(
    String pid,
    String id, {
    String? name,
    String? description,
    List<DashboardTile>? tiles,
    RelativePreset? range,
  }) => _col(pid).doc(id).update({
    if (name != null) 'name': name.trim(),
    if (description != null) 'description': description.trim(),
    if (tiles != null) 'tiles': [for (final t in tiles.take(Dashboard.maxTiles)) t.toMap()],
    if (range != null) 'range': range.id,
    'updatedAt': FieldValue.serverTimestamp(),
  });

  Future<void> addTile(String pid, String id, DashboardTile tile) => _col(pid).doc(id).update({
    'tiles': FieldValue.arrayUnion([tile.toMap()]),
    'updatedAt': FieldValue.serverTimestamp(),
  });

  Future<void> delete(String pid, String id) => _col(pid).doc(id).delete();
}
