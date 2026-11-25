import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/glass.dart';
import '../../core/severity.dart';
import '../../core/ui.dart';
import '../../data/models.dart';
import '../../state/providers.dart';

/// Alert rules (error spike, log volume, service went quiet) and their history.
/// A scheduled Cloud Function checks enabled rules every 5 minutes and calls
/// each rule's webhook (Slack, Discord or any HTTPS URL) when it fires or recovers.
class AlertsScreen extends ConsumerWidget {
  const AlertsScreen({super.key, required this.projectId});

  final String projectId;

  Future<void> _edit(BuildContext context, WidgetRef ref, [AlertRule? rule]) async {
    final services = ref.read(servicesProvider(projectId)).value ?? const <ServiceInfo>[];
    final result = await showDialog<AlertRule>(
      context: context,
      builder: (_) => _AlertDialog(rule: rule, services: services.map((s) => s.name).toList()),
    );
    if (result == null) return;
    final uid = ref.read(userProvider).value?.uid;
    if (uid == null) return;
    try {
      await ref.read(insightsRepositoryProvider).saveAlert(projectId, result, uid: uid);
      if (context.mounted) showMessage(context, rule == null ? 'Alert created' : 'Alert saved');
    } catch (e) {
      if (context.mounted) showMessage(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final alerts = ref.watch(alertsProvider(projectId));
    final events = ref.watch(alertEventsProvider(projectId)).value ?? const <AlertEvent>[];
    final canEdit = ref.watch(myRoleProvider(projectId))?.canManageKeys ?? false;
    final list = alerts.value ?? const <AlertRule>[];
    final checkerRunning = list.any(
      (a) => a.lastCheckedAt != null && DateTime.now().difference(a.lastCheckedAt!).inMinutes < 30,
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
      children: [
        Row(
          children: [
            Expanded(child: Text('Alerts', style: theme.textTheme.headlineSmall)),
            if (canEdit)
              FilledButton.icon(
                onPressed: () => _edit(context, ref),
                icon: const Icon(Icons.add_alert_outlined),
                label: const Text('New alert'),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Get a Slack, Discord or webhook message when errors spike or a service goes quiet. '
          'Rules are checked every 5 minutes.',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        if (list.isNotEmpty && !checkerRunning)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: GlassCard(
              shape: RoundedRectangleBorder(side: BorderSide(color: Severity.warn.color.withValues(alpha: 0.6))),
              child: ListTile(
                leading: Icon(Icons.info_outline, color: Severity.warn.color),
                title: const Text('The alert checker isn’t running yet'),
                subtitle: const Text(
                  'Alerts are checked by a Cloud Function, which needs the Firebase Blaze plan. '
                  'Your rules are saved and will start working as soon as it is deployed.',
                ),
              ),
            ),
          ),
        alerts.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => ErrorView(e),
          data: (rules) => rules.isEmpty
              ? GlassCard(
                  child: EmptyState(
                    icon: Icons.notifications_none,
                    title: 'No alerts yet',
                    message: 'Example: notify Slack when keyo_ios logs 10+ errors in 15 minutes.',
                    action: canEdit
                        ? FilledButton.icon(
                            onPressed: () => _edit(context, ref),
                            icon: const Icon(Icons.add),
                            label: const Text('Create alert'),
                          )
                        : null,
                  ),
                )
              : Column(
                  children: [
                    for (final a in rules)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _AlertCard(
                          rule: a,
                          canEdit: canEdit,
                          onEdit: () => _edit(context, ref, a),
                          onToggle: (v) => ref
                              .read(insightsRepositoryProvider)
                              .saveAlert(
                                projectId,
                                AlertRule(
                                  id: a.id,
                                  name: a.name,
                                  type: a.type,
                                  service: a.service,
                                  threshold: a.threshold,
                                  windowMinutes: a.windowMinutes,
                                  enabled: v,
                                  webhookUrl: a.webhookUrl,
                                ),
                                uid: ref.read(userProvider).value!.uid,
                              )
                              .catchError((Object e) {
                                if (context.mounted) showMessage(context, friendlyError(e), error: true);
                              }),
                          onDelete: () async {
                            final ok = await confirm(
                              context,
                              title: 'Delete “${a.name}”?',
                              message: 'The rule stops being checked. Its history is kept.',
                              action: 'Delete',
                              destructive: true,
                            );
                            if (ok) await ref.read(insightsRepositoryProvider).deleteAlert(projectId, a.id);
                          },
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 24),
        const SectionLabel('History'),
        if (events.isEmpty)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text('No alerts have fired yet.', style: TextStyle(color: theme.colorScheme.outline)),
          )
        else
          GlassCard(
            child: Column(
              children: [
                for (var i = 0; i < events.length; i++) ...[
                  if (i > 0) const Divider(),
                  ListTile(
                    dense: true,
                    leading: Icon(
                      events[i].state == 'firing' ? Icons.notifications_active : Icons.check_circle_outline,
                      color: events[i].state == 'firing' ? Severity.error.color : Severity.info.color,
                    ),
                    title: Text('${events[i].alertName}: ${events[i].state == 'firing' ? 'firing' : 'resolved'}'),
                    subtitle: Text(
                      '${DateFormat('MMM d, HH:mm').format(events[i].at)} · value ${events[i].value}'
                      '${events[i].webhookStatus == null ? '' : ' · webhook ${events[i].webhookStatus}'}',
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _AlertCard extends StatelessWidget {
  const _AlertCard({
    required this.rule,
    required this.canEdit,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
  });

  final AlertRule rule;
  final bool canEdit;
  final VoidCallback onEdit;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;

  String get _condition {
    final scope = rule.service ?? 'all services';
    return switch (rule.type) {
      AlertType.errorSpike => '≥ ${rule.threshold} errors in ${rule.windowMinutes} min · $scope',
      AlertType.logVolume => '≥ ${rule.threshold} logs in ${rule.windowMinutes} min · $scope',
      AlertType.serviceSilent => 'No logs for ${rule.windowMinutes} min · $scope',
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = !rule.enabled
        ? theme.colorScheme.outline
        : rule.firing
        ? Severity.error.color
        : Severity.info.color;
    return GlassCard(
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        leading: Icon(
          rule.firing && rule.enabled ? Icons.notifications_active : Icons.notifications_outlined,
          color: color,
        ),
        title: Text(rule.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          '${rule.type.label}: $_condition\n'
          '${!rule.enabled
              ? 'Disabled'
              : rule.firing
              ? 'FIRING'
              : 'OK'}'
          ' · checked ${timeAgo(rule.lastCheckedAt)}'
          '${rule.lastValue == null ? '' : ' · last value ${rule.lastValue}'}'
          '${rule.webhookUrl == null ? ' · no webhook' : ''}',
        ),
        isThreeLine: true,
        trailing: canEdit
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Switch(value: rule.enabled, onChanged: onToggle),
                  PopupMenuButton<String>(
                    onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('Edit')),
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
                ],
              )
            : null,
        onTap: canEdit ? onEdit : null,
      ),
    );
  }
}

class _AlertDialog extends StatefulWidget {
  const _AlertDialog({this.rule, required this.services});

  final AlertRule? rule;
  final List<String> services;

  @override
  State<_AlertDialog> createState() => _AlertDialogState();
}

class _AlertDialogState extends State<_AlertDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.rule?.name ?? '');
  late final _threshold = TextEditingController(text: '${widget.rule?.threshold ?? 10}');
  late final _webhook = TextEditingController(text: widget.rule?.webhookUrl ?? '');
  late AlertType _type = widget.rule?.type ?? AlertType.errorSpike;
  late String? _service = widget.rule?.service;
  late int _window = widget.rule?.windowMinutes ?? 15;

  @override
  void dispose() {
    _name.dispose();
    _threshold.dispose();
    _webhook.dispose();
    super.dispose();
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    final hook = _webhook.text.trim();
    Navigator.pop(
      context,
      AlertRule(
        id: widget.rule?.id ?? '',
        name: _name.text.trim(),
        type: _type,
        service: _service,
        threshold: _type == AlertType.serviceSilent ? 1 : int.parse(_threshold.text.trim()),
        windowMinutes: _window,
        enabled: widget.rule?.enabled ?? true,
        webhookUrl: hook.isEmpty ? null : hook,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final services = {...widget.services, ?_service}.toList()..sort();
    return AlertDialog(
      title: Text(widget.rule == null ? 'New alert' : 'Edit alert'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _name,
                  autofocus: widget.rule == null,
                  decoration: const InputDecoration(labelText: 'Name', hintText: 'keyo_ios error spike'),
                  validator: (v) => (v ?? '').trim().isEmpty
                      ? 'Required'
                      : (v!.trim().length > 80 ? 'Keep it under 80 characters' : null),
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<AlertType>(
                  initialValue: _type,
                  decoration: const InputDecoration(labelText: 'When'),
                  items: [for (final t in AlertType.values) DropdownMenuItem(value: t, child: Text(t.label))],
                  onChanged: (v) => setState(() => _type = v ?? _type),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
                  child: Text(_type.description, style: Theme.of(context).textTheme.bodySmall),
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<String?>(
                  initialValue: _service,
                  decoration: const InputDecoration(labelText: 'service.name'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('All services')),
                    for (final s in services) DropdownMenuItem(value: s, child: Text(s)),
                  ],
                  onChanged: (v) => setState(() => _service = v),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    if (_type != AlertType.serviceSilent) ...[
                      Expanded(
                        child: TextFormField(
                          controller: _threshold,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'At least'),
                          validator: (v) {
                            final n = int.tryParse((v ?? '').trim());
                            return n == null || n < 1 || n > 1000000 ? '1 to 1,000,000' : null;
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _window,
                        decoration: const InputDecoration(labelText: 'Within'),
                        items: const [
                          DropdownMenuItem(value: 5, child: Text('5 minutes')),
                          DropdownMenuItem(value: 15, child: Text('15 minutes')),
                          DropdownMenuItem(value: 30, child: Text('30 minutes')),
                          DropdownMenuItem(value: 60, child: Text('1 hour')),
                          DropdownMenuItem(value: 360, child: Text('6 hours')),
                          DropdownMenuItem(value: 1440, child: Text('24 hours')),
                        ],
                        onChanged: (v) => setState(() => _window = v ?? _window),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _webhook,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Webhook URL (optional)',
                    hintText: 'https://hooks.slack.com/services/…',
                    helperText: 'Slack and Discord webhooks get a formatted message; other URLs get JSON.',
                    helperMaxLines: 2,
                  ),
                  validator: (v) {
                    final s = (v ?? '').trim();
                    if (s.isEmpty) return null;
                    if (!s.startsWith('https://') || s.length > 500) return 'Use an https:// URL';
                    return null;
                  },
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
