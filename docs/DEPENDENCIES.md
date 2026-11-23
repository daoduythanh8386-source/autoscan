# Thư viện sử dụng

Trạng thái: **ràng buộc phiên bản đề xuất, CHƯA kiểm chứng build** (môi trường soạn mã không có mạng để chạy `pub get`). CI sẽ xác nhận; sau lần chạy xanh đầu tiên, hãy ghi phiên bản thực tế từ `pubspec.lock` vào bảng dưới.

| Gói | Ràng buộc | Mục đích | Android | iOS | Ghi chú |
|---|---|---|---|---|---|
| camera | ^0.11.0 | Preview, stream khung, chụp độ phân giải tối đa, flash, lấy nét, phơi sáng | CameraX | AVFoundation | Thay bằng native nếu stream không ổn định |
| image_picker | ^1.1.2 | Nhập ảnh từ thư viện (không nén) | Photo Picker | PHPicker | Không cần quyền bộ nhớ trên Android 13+ |
| path_provider | ^2.1.4 | Thư mục dữ liệu app | ✓ | ✓ | |
| sqflite | ^2.4.0 | SQLite lưu metadata | ✓ | ✓ | |
| image | ^4.2.0 | Giải mã/mã hoá JPEG, PNG, GIF; EXIF | Dart thuần | Dart thuần | Chậm hơn native với ảnh lớn |
| pdf | ^3.11.1 | Tạo PDF, lớp chữ OCR | Dart thuần | Dart thuần | |
| printing | ^5.13.2 | Xem trước PDF (không dùng in/chia sẻ của gói) | ✓ | ✓ | |
| share_plus | ^10.1.0 | Chia sẻ file thật qua hệ điều hành | Intent | UIActivityViewController | API `Share.shareXFiles` |
| sensors_plus | ^6.1.1 | Gia tốc kế cho thước thăng bằng trên camera | ✓ | ✓ | Không cần quyền đặc biệt |
| google_mlkit_text_recognition | ^0.14.0 | OCR on-device (Latin, gồm tiếng Việt theo tài liệu ML Kit) | ✓ (minSdk 21+) | iOS ≥ 15.5, arm64 | Tuỳ chọn; tăng dung lượng app |

Không dùng: thư viện mạng, analytics, quảng cáo, đăng nhập, cloud SDK.

OpenCV chưa được đưa vào v0.1: bộ nhận diện thuần Dart chạy được trên cả hai nền tảng mà không cần Native Assets/CocoaPods cho OpenCV. Nếu kiểm thử thực tế cho thấy độ chính xác chưa đủ, OpenCV là phương án nâng cấp đầu tiên (xem `RISKS.md`).
