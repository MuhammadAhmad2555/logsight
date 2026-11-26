import 'package:flutter/material.dart';

/// Building blocks of a help topic. Text may contain `code` spans in
/// backticks and **bold** spans. `{{PROJECT_ID}}`, `{{FIREBASE_PROJECT_ID}}`
/// are replaced with the open project's values when shown.
sealed class HelpBlock {
  const HelpBlock();

  /// Plain text used by search.
  String get searchText;
}

class HHeading extends HelpBlock {
  const HHeading(this.text);
  final String text;
  @override
  String get searchText => text;
}

class HText extends HelpBlock {
  const HText(this.text);
  final String text;
  @override
  String get searchText => text;
}

class HBullets extends HelpBlock {
  const HBullets(this.items);
  final List<String> items;
  @override
  String get searchText => items.join(' ');
}

/// Numbered steps.
class HSteps extends HelpBlock {
  const HSteps(this.items);
  final List<String> items;
  @override
  String get searchText => items.join(' ');
}

class HCode extends HelpBlock {
  const HCode(this.code, {this.title});
  final String code;
  final String? title;
  @override
  String get searchText => '${title ?? ''} $code';
}

enum TipKind { tip, warning }

class HTip extends HelpBlock {
  const HTip(this.text, {this.kind = TipKind.tip});
  final String text;
  final TipKind kind;
  @override
  String get searchText => text;
}

/// One row of a field/parameter table.
class HField {
  const HField(this.name, this.type, this.description, {this.required = false, this.defaultValue, this.limit});
  final String name;
  final String type;
  final String description;
  final bool required;
  final String? defaultValue;
  final String? limit;
}

class HFields extends HelpBlock {
  const HFields(this.fields, {this.title});
  final List<HField> fields;
  final String? title;
  @override
  String get searchText =>
      '${title ?? ''} ${fields.map((f) => '${f.name} ${f.type} ${f.description} ${f.limit ?? ''}').join(' ')}';
}

enum HelpCategory {
  start('Get started'),
  sdk('Send data (SDK)'),
  app('Using the dashboard'),
  reference('Reference');

  const HelpCategory(this.label);
  final String label;
}

class HelpTopic {
  HelpTopic({
    required this.id,
    required this.title,
    required this.icon,
    required this.category,
    required this.summary,
    required this.blocks,
    this.related = const [],
  });

  final String id;
  final String title;
  final IconData icon;
  final HelpCategory category;
  final String summary;
  final List<HelpBlock> blocks;

  /// IDs of related topics, shown at the end.
  final List<String> related;

  late final String searchText =
      '$title $summary ${blocks.map((b) => b.searchText).join(' ')}'.toLowerCase();

  /// Search score for [query] (0 = no match). Title hits rank first.
  int score(String query) {
    final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return 1;
    var s = 0;
    for (final w in words) {
      if (!searchText.contains(w)) return 0;
      if (title.toLowerCase().contains(w)) s += 10;
      if (summary.toLowerCase().contains(w)) s += 3;
      s += 1;
    }
    return s;
  }
}
