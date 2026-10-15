import 'package:flutter_test/flutter_test.dart';
import 'package:local_pdf_editor/features/viewer/export_dialog.dart';

void main() {
  test(
    'page ranges keep requested order and deduplicate without admitting invalid pages',
    () {
      expect(parsePageRange('', 3), [0, 1, 2]);
      expect(parsePageRange('3,1-2,2，5', 5), [2, 0, 1, 4]);
      for (final invalid in ['0', '6', '3-1', '1,,2', '1-', '-2']) {
        expect(() => parsePageRange(invalid, 5), throwsFormatException);
      }
    },
  );
}
