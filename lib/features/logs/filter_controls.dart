import 'package:flutter/material.dart';

import '../../core/severity.dart';
import '../../data/log_query.dart';

/// Picks a relative or custom time range.
class TimeRangeButton extends StatelessWidget {
  const TimeRangeButton({super.key, required this.range, required this.onChanged});

  final TimeRange range;
  final ValueChanged<TimeRange> onChanged;

  Future<void> _custom(BuildContext context) async {
    final now = DateTime.now();
    final (from, to) = range.resolve(now);
    final picked = await showDateRangePicker(
      context: context,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now,
      initialDateRange: DateTimeRange(
        start: DateTime(from.year, from.month, from.day),
        end: DateTime(to.year, to.month, to.day),
      ),
      helpText: 'Select dates',
    );
    if (picked == null || !context.mounted) return;
    final startTime = await showTimePicker(
      context: context,
      helpText: 'Start time on ${_d(picked.start)}',
      initialTime: const TimeOfDay(hour: 0, minute: 0),
    );
    if (startTime == null || !context.mounted) return;
    final endTime = await showTimePicker(
      context: context,
      helpText: 'End time on ${_d(picked.end)}',
      initialTime: const TimeOfDay(hour: 23, minute: 59),
    );
    if (endTime == null) return;
    final start = DateTime(picked.start.year, picked.start.month, picked.start.day, startTime.hour, startTime.minute);
    var end = DateTime(picked.end.year, picked.end.month, picked.end.day, endTime.hour, endTime.minute, 59);
    if (end.isAfter(now)) end = now;
    if (!start.isBefore(end)) return;
    onChanged(TimeRange.absolute(start, end));
  }

  static String _d(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<Object>(
      tooltip: 'Time range',
      position: PopupMenuPosition.under,
      onSelected: (v) {
        if (v is RelativePreset) {
          onChanged(TimeRange.relative(v));
        } else {
          _custom(context);
        }
      },
      itemBuilder: (_) => [
        for (final p in RelativePreset.values)
          CheckedPopupMenuItem(value: p, checked: range.preset == p, child: Text(p.label)),
        const PopupMenuDivider(),
        CheckedPopupMenuItem(value: 'custom', checked: !range.isRelative, child: const Text('Custom range…')),
      ],
      child: _OutlinedChip(icon: Icons.schedule, label: range.label),
    );
  }
}

/// Multi-select of severity levels, with counts when available.
class SeverityButton extends StatelessWidget {
  const SeverityButton({super.key, required this.selected, required this.totals, required this.onChanged});

  final Set<Severity> selected;
  final Map<Severity, int>? totals;
  final ValueChanged<Set<Severity>> onChanged;

  @override
  Widget build(BuildContext context) {
    final label = selected.isEmpty
        ? 'All levels'
        : Severity.values.where(selected.contains).map((s) => s.label).join(', ');
    return PopupMenuButton<Severity>(
      tooltip: 'Severity',
      position: PopupMenuPosition.under,
      onSelected: (s) {
        final next = {...selected};
        next.contains(s) ? next.remove(s) : next.add(s);
        onChanged(next);
      },
      itemBuilder: (_) => [
        for (final s in Severity.values.reversed)
          CheckedPopupMenuItem(
            value: s,
            checked: selected.contains(s),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: s.color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(s.label)),
                if (totals != null)
                  Text('${totals![s] ?? 0}', style: TextStyle(color: Theme.of(context).colorScheme.outline)),
              ],
            ),
          ),
      ],
      child: _OutlinedChip(icon: Icons.filter_list, label: label, active: selected.isNotEmpty),
    );
  }
}

class _OutlinedChip extends StatelessWidget {
  const _OutlinedChip({required this.icon, required this.label, this.active = false});

  final IconData icon;
  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: active ? scheme.secondaryContainer : null,
        border: Border.all(color: active ? scheme.secondaryContainer : scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240),
            child: Text(label, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
          ),
          const SizedBox(width: 2),
          const Icon(Icons.arrow_drop_down, size: 18),
        ],
      ),
    );
  }
}

/// Result of [showFilterDialog]: either a service filter or an attribute filter.
sealed class FilterChoice {}

class ServiceChoice extends FilterChoice {
  ServiceChoice(this.service, {required this.exclude});
  final String service;
  final bool exclude;
}

class AttrChoice extends FilterChoice {
  AttrChoice(this.filter);
  final AttrFilter filter;
}

Future<FilterChoice?> showFilterDialog(
  BuildContext context, {
  required List<String> knownServices,
  required List<String> knownKeys,
}) {
  return showDialog<FilterChoice>(
    context: context,
    builder: (_) => _FilterDialog(knownServices: knownServices, knownKeys: knownKeys),
  );
}

class _FilterDialog extends StatefulWidget {
  const _FilterDialog({required this.knownServices, required this.knownKeys});

  final List<String> knownServices;
  final List<String> knownKeys;

  @override
  State<_FilterDialog> createState() => _FilterDialogState();
}

class _FilterDialogState extends State<_FilterDialog> {
  final _key = TextEditingController(text: 'service.name');
  final _value = TextEditingController();
  FilterOp _op = FilterOp.equals;

  bool get _isService => const {'service.name', 'service_name', 'service'}.contains(_key.text.trim());

  @override
  void dispose() {
    _key.dispose();
    _value.dispose();
    super.dispose();
  }

  void _submit() {
    final key = _key.text.trim();
    final value = _value.text.trim();
    if (key.isEmpty || (_op.needsValue && value.isEmpty)) return;
    if (_isService && (_op == FilterOp.equals || _op == FilterOp.notEquals)) {
      Navigator.pop(context, ServiceChoice(value, exclude: _op == FilterOp.notEquals));
      return;
    }
    Navigator.pop(context, AttrChoice(AttrFilter(_isService ? 'service' : key, _op, value)));
  }

  @override
  Widget build(BuildContext context) {
    final keys = ['service.name', 'message', 'userId', 'sessionId', 'traceId', ...widget.knownKeys];
    final suggestions = _isService ? widget.knownServices : const <String>[];
    return AlertDialog(
      title: const Text('Add filter'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _key,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Field',
                helperText: 'service.name, message, or any attribute (e.g. app.version)',
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final k in keys.toSet().take(14))
                  ChoiceChip(
                    label: Text(k, style: const TextStyle(fontSize: 12)),
                    selected: _key.text.trim() == k,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => setState(() => _key.text = k),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<FilterOp>(
              initialValue: _op,
              decoration: const InputDecoration(labelText: 'Operator'),
              items: [for (final op in FilterOp.values) DropdownMenuItem(value: op, child: Text(op.label))],
              onChanged: (v) => setState(() => _op = v ?? FilterOp.equals),
            ),
            if (_op.needsValue) ...[
              const SizedBox(height: 14),
              TextField(
                controller: _value,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Value'),
                onSubmitted: (_) => _submit(),
              ),
              if (suggestions.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final s in suggestions.take(12))
                      ActionChip(label: Text(s), onPressed: () => setState(() => _value.text = s)),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Add filter')),
      ],
    );
  }
}
