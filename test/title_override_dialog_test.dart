import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/widgets/title_override_dialog.dart';

void main() {
  group('overrideTitleValue', () {
    test('unchanged from enriched -> null (automatic)', () {
      expect(overrideTitleValue('Kyoku', 'Kyoku'), isNull);
      expect(overrideTitleValue('', null), isNull); // both empty
    });
    test('cleared a non-empty enriched -> "" (suppress)', () {
      expect(overrideTitleValue('', 'Kyoku'), '');
    });
    test('edited -> the text (override)', () {
      expect(overrideTitleValue('NewReading', 'Kyoku'), 'NewReading');
    });
  });
}
