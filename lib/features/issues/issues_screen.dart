import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/glass.dart';
import '../../core/severity.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../data/insights.dart';
import '../../data/log_query.dart';
import '../../data/models.dart';
import '../../state/providers.dart';

/// Errors grouped into issues (service + exception type + message pattern).
/// Admins can resolve, ignore, reopen and assign; a resolved issue that gets
/// new errors shows as "Regressed".
class IssuesScreen extends ConsumerStatefulWidget {
  const IssuesScreen({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<IssuesScreen> createState() => _IssuesScreenState();
}

enum _StatusFilter { open, resolved, ignored, all }

class _IssuesScreenState extends ConsumerState<IssuesScreen> {
  RelativePreset _range = RelativePreset.d7;
  String? _service;
  _StatusFilter _status = _StatusFilter.open;
  Future<List<LogEntry>>? _errors;
  int _scanned = 0;

  static const _errorLevels = {Severity.error, Severity.fatal};

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    setState(() {
      _errors = ref
          .read(logRepositoryProvider)
          .fetchPage(
            widget.projectId,
            LogQuery(
              range: TimeRange.relative(_range),
              severities: _errorLevels,
              services: _service == null ? const [] : [_service!],
            ),
            want: 2000,
            maxScan: 2000,
          )
          .then((p) {
            _scanned = p.scanned;
            return p.logs;
          });
    });
  }

  bool _visible(IssueGroup g) => switch (_status) {
    _StatusFilter.open => g.status == IssueStatus.open || g.regressed,
    _StatusFilter.resolved => g.status == IssueStatus.resolved && !g.regressed,
    _StatusFilter.ignored => g.status == IssueStatus.ignored,
    _StatusFilter.all => true,
  };

  Future<void> _act(Future<void> Function() action, String done) async {
    try {
      await action();
      if (mounted) showMessage(context, done);
    } catch (e) {
      if (mounted) showMessage(context, friendlyError(e), error: true);
    }
  }

  void _openLogs(IssueGroup g) {
    final q = LogQuery(
      range: TimeRange.relative(_range),
      services: [g.service],
      severities: _errorLevels,
      filters: [AttrFilter('pattern', FilterOp.equals, g.pattern)],
    );
    context.go(Uri(path: '/p/${widget.projectId}/logs', queryParameters: q.toQueryParameters()).toString());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final states = ref.watch(issueStatesProvider(widget.projectId)).value ?? const <String, IssueState>{};
    final services = ref.watch(servicesProvider(widget.projectId)).value ?? const <ServiceInfo>[];
    final role = ref.watch(myRoleProvider(widget.projectId));
    final canEdit = role?.canManageKeys ?? false;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
      children: [
        Text('Issues', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          'Errors and fatal logs grouped by service, exception type and message pattern.',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedButton<_StatusFilter>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: _StatusFilter.open, label: Text('Open')),
                ButtonSegment(value: _StatusFilter.resolved, label: Text('Resolved')),
                ButtonSegment(value: _StatusFilter.ignored, label: Text('Ignored')),
                ButtonSegment(value: _StatusFilter.all, label: Text('All')),
              ],
              selected: {_status},
              onSelectionChanged: (s) => setState(() => _status = s.first),
            ),
            SegmentedButton<RelativePreset>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: RelativePreset.h24, label: Text('24h')),
                ButtonSegment(value: RelativePreset.d7, label: Text('7d')),
                ButtonSegment(value: RelativePreset.d30, label: Text('30d')),
              ],
              selected: {_range},
              onSelectionChanged: (s) {
                _range = s.first;
                _load();
              },
            ),
            DropdownButton<String?>(
              value: _service,
              hint: const Text('All services'),
              borderRadius: BorderRadius.circular(14),
              items: [
                const DropdownMenuItem(value: null, child: Text('All services')),
                for (final s in services) DropdownMenuItem(value: s.name, child: Text(s.name)),
              ],
              onChanged: (v) {
                _service = v;
                _load();
              },
            ),
            IconButton(tooltip: 'Refresh', onPressed: _load, icon: const Icon(Icons.refresh)),
          ],
        ),
        const SizedBox(height: 16),
        FutureBuilder<List<LogEntry>>(
          future: _errors,
          builder: (context, snap) {
            if (snap.hasError) return ErrorView(snap.error!, onRetry: _load);
            if (!snap.hasData) {
              return const Padding(
                padding: EdgeInsets.all(48),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final groups = groupIssues(snap.data!, states).where(_visible).toList();
            if (groups.isEmpty) {
              return GlassCard(
                child: EmptyState(
                  icon: Icons.verified_outlined,
                  title: _status == _StatusFilter.open ? 'No open issues' : 'Nothing here',
                  message: 'Based on $_scanned error logs in this range.',
                ),
              );
            }
            return Column(
              children: [
                for (final g in groups)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _IssueCard(
                      group: g,
                      canEdit: canEdit,
                      onOpenLogs: () => _openLogs(g),
                      onStatus: (s) => _act(
                        () => ref.read(insightsRepositoryProvider).setIssueStatus(widget.projectId, g.fingerprint, s),
                        'Marked ${s.label.toLowerCase()}',
                      ),
                      onAssignMe: () => _act(
                        () => ref
                            .read(insightsRepositoryProvider)
                            .assignIssue(widget.projectId, g.fingerprint, ref.read(userProvider).value),
                        'Assigned to you',
                      ),
                      onUnassign: () => _act(
                        () => ref.read(insightsRepositoryProvider).assignIssue(widget.projectId, g.fingerprint, null),
                        'Unassigned',
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    'Grouped from the latest $_scanned error logs in this range.',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _IssueCard extends StatelessWidget {
  const _IssueCard({
    required this.group,
    required this.canEdit,
    required this.onOpenLogs,
    required this.onStatus,
    required this.onAssignMe,
    required this.onUnassign,
  });

  final IssueGroup group;
  final bool canEdit;
  final VoidCallback onOpenLogs;
  final ValueChanged<IssueStatus> onStatus;
  final VoidCallback onAssignMe;
  final VoidCallback onUnassign;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final g = group;
    final badge = g.regressed
        ? ('Regressed', Severity.warn.color)
        : switch (g.status) {
            IssueStatus.open => ('Open', Severity.error.color),
            IssueStatus.resolved => ('Resolved', Severity.info.color),
            IssueStatus.ignored => ('Ignored', theme.colorScheme.outline),
          };
    return GlassCard(
      child: InkWell(
        onTap: onOpenLogs,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: badge.$2.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            badge.$1,
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: badge.$2),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            g.service,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      g.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: monoStyle.copyWith(fontSize: 13.5, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 14,
                      runSpacing: 4,
                      children: [
                        _Meta(Icons.repeat, '${g.count} events'),
                        if (g.users.isNotEmpty) _Meta(Icons.person_outline, '${g.users.length} users'),
                        _Meta(Icons.schedule, 'last ${timeAgo(g.lastSeen)}'),
                        _Meta(Icons.history, 'first ${timeAgo(g.firstSeen)}'),
                        if (g.state?.assigneeEmail != null)
                          _Meta(Icons.assignment_ind_outlined, g.state!.assigneeEmail!),
                      ],
                    ),
                  ],
                ),
              ),
              if (canEdit)
                PopupMenuButton<String>(
                  tooltip: 'Actions',
                  onSelected: (v) => switch (v) {
                    'resolve' => onStatus(IssueStatus.resolved),
                    'ignore' => onStatus(IssueStatus.ignored),
                    'reopen' => onStatus(IssueStatus.open),
                    'assign' => onAssignMe(),
                    'unassign' => onUnassign(),
                    _ => onOpenLogs(),
                  },
                  itemBuilder: (_) => [
                    if (g.status != IssueStatus.resolved || g.regressed)
                      const PopupMenuItem(value: 'resolve', child: Text('Resolve')),
                    if (g.status != IssueStatus.ignored) const PopupMenuItem(value: 'ignore', child: Text('Ignore')),
                    if (g.status != IssueStatus.open) const PopupMenuItem(value: 'reopen', child: Text('Reopen')),
                    const PopupMenuDivider(),
                    const PopupMenuItem(value: 'assign', child: Text('Assign to me')),
                    if (g.state?.assigneeUid != null) const PopupMenuItem(value: 'unassign', child: Text('Unassign')),
                    const PopupMenuDivider(),
                    const PopupMenuItem(value: 'logs', child: Text('View logs')),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta(this.icon, this.text);

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: c),
        const SizedBox(width: 4),
        Text(text, style: TextStyle(fontSize: 12, color: c)),
      ],
    );
  }
}
