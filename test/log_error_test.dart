import 'package:flutter_test/flutter_test.dart';
import 'package:trackapp/data/models.dart';

void main() {
  test('LogError.fromMap keeps non-empty strings and ignores junk', () {
    expect(LogError.fromMap(null), isNull);
    expect(LogError.fromMap({'type': ''}), isNull);
    final e = LogError.fromMap({'type': 'StateError', 'message': 'Bad state', 'stack': '#0 a\n\n#1 b\n', 'x': 1})!;
    expect(e.type, 'StateError');
    expect(e.reason, isNull);
    expect(e.stackLines, ['#0 a', '#1 b']);
    expect(e.toJson().keys, ['type', 'message', 'stack']);
    expect(e.toText(), startsWith('StateError: Bad state'));
  });
}
