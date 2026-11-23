import 'package:flutter_test/flutter_test.dart';
import 'package:smart_document_scanner/core/ids.dart';

// File này tồn tại để `flutter create` không sinh test mẫu tham chiếu MyApp.
void main() {
  test('newId sinh chuỗi 32 ký tự hex khác nhau', () {
    final a = newId(), b = newId();
    expect(a.length, 32);
    expect(a == b, isFalse);
  });
}
