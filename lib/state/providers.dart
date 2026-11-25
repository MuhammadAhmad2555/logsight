import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/activity.dart';
import '../data/activity_repository.dart';
import '../data/auth_repository.dart';
import '../data/insights_repository.dart';
import '../data/log_repository.dart';
import '../data/models.dart';
import '../data/project_repository.dart';
import '../data/text_logs/text_log_store.dart';

final firestoreProvider = Provider<FirebaseFirestore>((ref) => FirebaseFirestore.instance);

final authRepositoryProvider = Provider<AuthRepository>((ref) => AuthRepository(FirebaseAuth.instance));

final projectRepositoryProvider = Provider<ProjectRepository>((ref) => ProjectRepository(ref.watch(firestoreProvider)));

final logRepositoryProvider = Provider<LogRepository>((ref) => LogRepository(ref.watch(firestoreProvider)));

final userProvider = StreamProvider<User?>((ref) => ref.watch(authRepositoryProvider).userChanges());

final myProjectsProvider = StreamProvider<List<Project>>((ref) {
  final user = ref.watch(userProvider).value;
  if (user == null) return Stream.value(const []);
  return ref.watch(projectRepositoryProvider).watchMyProjects(user.uid);
});

final myInvitesProvider = StreamProvider<List<Invite>>((ref) {
  final user = ref.watch(userProvider).value;
  final email = user?.email;
  if (user == null || email == null || !user.emailVerified) return Stream.value(const []);
  return ref.watch(projectRepositoryProvider).watchInvitesFor(email);
});

final projectProvider = StreamProvider.family<Project?, String>(
  (ref, pid) => ref.watch(projectRepositoryProvider).watchProject(pid),
);

final projectInvitesProvider = StreamProvider.family<List<Invite>, String>(
  (ref, pid) => ref.watch(projectRepositoryProvider).watchProjectInvites(pid),
);

final ingestKeysProvider = StreamProvider.family<List<IngestKey>, String>(
  (ref, pid) => ref.watch(projectRepositoryProvider).watchKeys(pid),
);

final servicesProvider = StreamProvider.family<List<ServiceInfo>, String>(
  (ref, pid) => ref.watch(projectRepositoryProvider).watchServices(pid),
);

/// The signed-in user's role in a project, or null while loading or if they aren't a member.
final myRoleProvider = Provider.family<ProjectRole?, String>((ref, pid) {
  final uid = ref.watch(userProvider).value?.uid;
  final project = ref.watch(projectProvider(pid)).value;
  if (uid == null || project == null) return null;
  return project.roleOf(uid);
});

// ------------------------------------------------------------------- settings

final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('Overridden in main()'),
);

class ThemeModeController extends Notifier<ThemeMode> {
  static const _key = 'theme_mode';

  @override
  ThemeMode build() {
    final saved = ref.watch(sharedPreferencesProvider).getString(_key);
    return ThemeMode.values.firstWhere((m) => m.name == saved, orElse: () => ThemeMode.system);
  }

  void set(ThemeMode mode) {
    state = mode;
    ref.read(sharedPreferencesProvider).setString(_key, mode.name);
  }
}

final themeModeProvider = NotifierProvider<ThemeModeController, ThemeMode>(ThemeModeController.new);

class LastProjectController extends Notifier<String?> {
  static const _key = 'last_project';

  @override
  String? build() => ref.watch(sharedPreferencesProvider).getString(_key);

  void set(String pid) {
    if (state == pid) return;
    state = pid;
    ref.read(sharedPreferencesProvider).setString(_key, pid);
  }
}

final lastProjectProvider = NotifierProvider<LastProjectController, String?>(LastProjectController.new);

/// Text-file copies of logs in LogSight's app folder, one store per project.
final textLogStoreProvider = Provider.family<TextLogStore, String>((ref, pid) => TextLogStore(pid));

/// Whether LogSight saves every log it loads to text files (default on).
class AutoSaveController extends Notifier<bool> {
  static const _key = 'auto_save_text_logs';

  @override
  bool build() => ref.watch(sharedPreferencesProvider).getBool(_key) ?? true;

  void set(bool on) {
    state = on;
    ref.read(sharedPreferencesProvider).setBool(_key, on);
  }
}

final autoSaveProvider = NotifierProvider<AutoSaveController, bool>(AutoSaveController.new);

// ------------------------------------------------------------------ insights

final insightsRepositoryProvider = Provider<InsightsRepository>(
  (ref) => InsightsRepository(ref.watch(firestoreProvider)),
);

final savedViewsProvider = StreamProvider.family<List<SavedView>, String>(
  (ref, pid) => ref.watch(insightsRepositoryProvider).watchViews(pid),
);

final issueStatesProvider = StreamProvider.family<Map<String, IssueState>, String>(
  (ref, pid) => ref.watch(insightsRepositoryProvider).watchIssues(pid),
);

final alertsProvider = StreamProvider.family<List<AlertRule>, String>(
  (ref, pid) => ref.watch(insightsRepositoryProvider).watchAlerts(pid),
);

final alertEventsProvider = StreamProvider.family<List<AlertEvent>, String>(
  (ref, pid) => ref.watch(insightsRepositoryProvider).watchAlertEvents(pid),
);

/// Desktop sidebar: null = automatic (collapsed when the window is narrow),
/// true/false = the user's choice, remembered across launches.
class SidebarCollapsedController extends Notifier<bool?> {
  static const _key = 'sidebar_collapsed';

  @override
  bool? build() => ref.watch(sharedPreferencesProvider).getBool(_key);

  void set(bool collapsed) {
    state = collapsed;
    ref.read(sharedPreferencesProvider).setBool(_key, collapsed);
  }
}

final sidebarCollapsedProvider = NotifierProvider<SidebarCollapsedController, bool?>(SidebarCollapsedController.new);

// ------------------------------------------------------------------ activity

final activityRepositoryProvider = Provider<ActivityRepository>(
  (ref) => ActivityRepository(ref.watch(firestoreProvider)),
);

final peopleProvider = StreamProvider.family<List<Person>, String>(
  (ref, pid) => ref.watch(activityRepositoryProvider).watchPeople(pid),
);

final personProvider = StreamProvider.family<Person?, (String, String)>(
  (ref, args) => ref.watch(activityRepositoryProvider).watchPerson(args.$1, args.$2),
);

final eventDefinitionsProvider = StreamProvider.family<List<EventDefinition>, String>(
  (ref, pid) => ref.watch(activityRepositoryProvider).watchDefinitions(pid),
);

/// Property columns shown in the Activity table (remembered per device).
class ActivityColumnsController extends Notifier<List<String>> {
  static const _key = 'activity_columns';

  @override
  List<String> build() => ref.watch(sharedPreferencesProvider).getStringList(_key) ?? const [];

  void set(List<String> columns) {
    state = columns;
    ref.read(sharedPreferencesProvider).setStringList(_key, columns);
  }
}

final activityColumnsProvider = NotifierProvider<ActivityColumnsController, List<String>>(
  ActivityColumnsController.new,
);
