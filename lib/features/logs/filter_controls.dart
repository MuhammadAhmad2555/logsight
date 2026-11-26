import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/app_menu.dart';
import '../../core/theme.dart';

import '../../core/severity.dart';
import '../../data/log_query.dart';

/// Picks a relative or custom time range.
class TimeRangeButton extends StatelessWidget {
  const TimeRangeButton({
    super.key,
    required this.range,
    required this.onChanged,
  });

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
    final start = DateTime(
      picked.start.year,
      picked.start.month,
      picked.start.day,
      startTime.hour,
      startTime.minute,
    );
    var end = DateTime(
      picked.end.year,
      picked.end.month,
      picked.end.day,
      endTime.hour,
      endTime.minute,
      59,
    );
    if (end.isAfter(now)) end = now;
    if (!start.isBefore(end)) return;
    onChanged(TimeRange.absolute(start, end));
  }

  static String _d(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return AppMenuAnchor<Object>(
      tooltip: 'Time range',
      selected: {range.isRelative ? range.preset! : 'custom'},
      searchable: false,
      minWidth: 210,
      entries: () => [
        for (final p in RelativePreset.values)
          MenuEntry<Object>(p, p.label, section: 'Relative'),
        const MenuEntry<Object>(
          'custom',
          'Custom range…',
          icon: Icons.date_range_outlined,
          section: 'Absolute',
        ),
      ],
      onSelected: (v) {
        if (v is RelativePreset) {
          onChanged(TimeRange.relative(v));
        } else {
          _custom(context);
        }
      },
      builder: (context, open) => MenuPill(
        icon: Icons.schedule_rounded,
        label: range.label,
        open: open,
        active: !range.isRelative,
      ),
    );
  }
}

/// Multi-select of severity levels, with counts when available.
class SeverityButton extends StatelessWidget {
  const SeverityButton({
    super.key,
    required this.selected,
    required this.totals,
    required this.onChanged,
  });

  final Set<Severity> selected;
  final Map<Severity, int>? totals;
  final ValueChanged<Set<Severity>> onChanged;

  @override
  Widget build(BuildContext context) {
    final label = selected.isEmpty
        ? 'All levels'
        : Severity.values
              .where(selected.contains)
              .map((s) => s.label)
              .join(', ');
    return AppMenuAnchor<Severity>(
      tooltip: 'Severity',
      multi: true,
      searchable: false,
      selected: selected,
      minWidth: 200,
      entries: () => [
        for (final s in Severity.values.reversed)
          MenuEntry(
            s,
            s.label,
            leading: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: s.color, shape: BoxShape.circle),
            ),
            trailing: totals == null
                ? null
                : NumberFormat.compact().format(totals![s] ?? 0),
          ),
      ],
      onToggle: (s) {
        final next = {...selected};
        next.contains(s) ? next.remove(s) : next.add(s);
        onChanged(next);
      },
      builder: (context, open) => MenuPill(
        icon: Icons.filter_list_rounded,
        label: label,
        open: open,
        active: selected.isNotEmpty,
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

/// Built-in log fields offered in the filter picker (see [LogEntry.field]).
const logBuiltInFields = [
  'service.name',
  'severity',
  'message',
  'pattern',
  'userId',
  'sessionId',
  'traceId',
  'error.type',
  'error.message',
  'error.reason',
];

/// Built-in activity fields (see [ActivityEvent.field]).
const activityBuiltInFields = ['service.name', 'event', 'distinctId', 'sessionId'];

Future<FilterChoice?> showFilterDialog(
  BuildContext context, {
  required List<String> knownServices,
  required List<String> knownKeys,
  Map<String, List<String>> knownValues = const {},
  List<String> builtInKeys = logBuiltInFields,
}) {
  return showDialog<FilterChoice>(
    context: context,
    builder: (_) => _FilterDialog(
      knownServices: knownServices,
      knownKeys: knownKeys,
      knownValues: knownValues,
      builtInKeys: builtInKeys,
    ),
  );
}

class _FilterDialog extends StatefulWidget {
  const _FilterDialog({
    required this.knownServices,
    required this.knownKeys,
    required this.knownValues,
    required this.builtInKeys,
  });

  final List<String> knownServices;
  final List<String> knownKeys;
  final Map<String, List<String>> knownValues;
  final List<String> builtInKeys;

  @override
  State<_FilterDialog> createState() => _FilterDialogState();
}

class _FilterDialogState extends State<_FilterDialog> {
  final _key = TextEditingController(text: 'service.name');
  final _value = TextEditingController();
  FilterOp _op = FilterOp.equals;

  bool get _isService => const {
    'service.name',
    'service_name',
    'service',
  }.contains(_key.text.trim());

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
      Navigator.pop(
        context,
        ServiceChoice(value, exclude: _op == FilterOp.notEquals),
      );
      return;
    }
    Navigator.pop(
      context,
      AttrChoice(AttrFilter(_isService ? 'service' : key, _op, value)),
    );
  }

  Widget _fieldPicker(BuildContext context, String key) {
    final builtIn = widget.builtInKeys.toSet();
    final custom = widget.knownKeys.where((k) => !builtIn.contains(k)).toList();
    String? count(String k) {
      final n = k == 'service.name' ? widget.knownServices.length : widget.knownValues[k]?.length;
      return n == null || n == 0 ? null : '$n';
    }

    return AppMenuAnchor<String>(
      tooltip: 'Field',
      searchable: true,
      searchHint: 'Search ${builtIn.length + custom.length} fields or type a new one',
      selected: {key},
      minWidth: 300,
      maxHeight: 440,
      customLabel: 'Use field',
      onCustom: (q) => q.trim(),
      entries: () => [
        for (final k in builtIn) MenuEntry(k, k, mono: true, trailing: count(k), section: 'Built-in fields'),
        for (final k in custom)
          MenuEntry(k, k, mono: true, trailing: count(k), section: 'Custom attributes (${custom.length})'),
      ],
      onSelected: (k) => setState(() {
        if (k.isEmpty) return;
        _key.text = k;
        _value.clear();
      }),
      builder: (context, open) => InputDecorator(
        isFocused: open,
        decoration: InputDecoration(
          labelText: 'Field',
          helperText: custom.isEmpty
              ? 'Built-in field or any attribute name (e.g. app.version)'
              : '${custom.length} custom attributes found · or type any name',
          suffixIcon: AnimatedRotation(
            turns: open ? 0.5 : 0,
            duration: const Duration(milliseconds: 150),
            child: const Icon(Icons.keyboard_arrow_down_rounded, size: 20),
          ),
        ),
        child: Text(key, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final key = _key.text.trim();
    final allSuggestions = _isService
        ? widget.knownServices
        : (widget.knownValues[key] ?? const <String>[]);
    final typed = _value.text.trim().toLowerCase();
    final suggestions = allSuggestions
        .where((v) => typed.isEmpty || v.toLowerCase().contains(typed))
        .take(40)
        .toList();
    final mobile = isMobileLayout(context);
    final form = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _fieldPicker(context, key),
        const SizedBox(height: 14),
        AppSelectField<FilterOp>(
          label: 'Operator',
          value: _op,
          entries: [for (final op in FilterOp.values) MenuEntry(op, op.label)],
          onChanged: (v) => setState(() => _op = v),
        ),
        if (_op.needsValue) ...[
          const SizedBox(height: 14),
          TextField(
            controller: _value,
            autofocus: !mobile,
            decoration: InputDecoration(
              labelText: 'Value',
              hintText: allSuggestions.isEmpty
                  ? 'Enter a value'
                  : 'Search existing values',
              suffixIcon: IconButton(
                tooltip: 'Clear value',
                onPressed: () => setState(_value.clear),
                icon: const Icon(Icons.close_rounded),
              ),
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
          if (suggestions.isNotEmpty) ...[
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: suggestions.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final value = suggestions[index];
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.history_rounded, size: 18),
                    title: Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => setState(() => _value.text = value),
                  );
                },
              ),
            ),
          ],
        ],
      ],
    );
    if (mobile) {
      return Dialog.fullscreen(
        child: Scaffold(
          backgroundColor: Theme.of(context).colorScheme.surface,
          appBar: AppBar(
            title: const Text('Add filter'),
            leading: IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close_rounded),
            ),
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              children: [form],
            ),
          ),
          bottomNavigationBar: SafeArea(
            minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: _submit,
                    child: const Text('Add filter'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return AlertDialog(
      title: const Text('Add filter'),
      content: SizedBox(width: 420, child: form),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Add filter')),
      ],
    );
  }
}
