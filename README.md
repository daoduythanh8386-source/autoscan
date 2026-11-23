# APP scan PDF (SMART DOCUMENT SCANNER)

Ứng dụng scan tài liệu cho **Android và iPhone** (Flutter/Dart): chụp bằng camera → tự nhận diện 4 góc → nắn phẳng phối cảnh → cân bằng sáng, khử bóng → chỉnh tay → quản lý nhiều trang → xuất **PDF / PNG / JPG / GIF / ảnh gốc** → chia sẻ (Zalo, Gmail, Messenger, Drive…).

Cấu hình đã chốt: **AUTO · MAXIMUM · OPTIONAL (OCR) · DEVICE**. Không cần đăng nhập, không cần máy chủ, không cần Internet, không tự tải lên cloud.

> ⚠️ **Trạng thái hiện tại: mã nguồn v0.1 – NOT VERIFIED.**
> Mã chưa được chạy trên thiết bị thật. Kiểm thử đơn vị và bản build APK/iOS chạy tự động trên GitHub Actions (xem tab **Actions**). Theo mục 27 của đặc tả, không hạng mục nào được đánh dấu PASS khi chưa kiểm thử trên điện thoại. Xem [docs/REQUIREMENTS_MATRIX.md](docs/REQUIREMENTS_MATRIX.md).

## Tải bản build

Mỗi lần đẩy code, workflow **Build & Test** sẽ:
1. Sinh thư mục `android/` và `ios/` (`flutter create`) rồi vá cấu hình bằng `scripts/patch_platforms.py`.
2. Chạy `flutter analyze` và `flutter test`.
3. Build `app-release.apk` (ký bằng debug key, chỉ để cài thử) và `Runner-unsigned.zip` cho iOS (chưa ký).

Vào **Actions → lần chạy mới nhất → Artifacts** để tải về.

## Build trên máy của bạn

```bash
# Yêu cầu: Flutter stable (3.24+), Android Studio/SDK; với iOS: macOS + Xcode 15+ + CocoaPods
git clone <repo>
cd smart-document-scanner
bash scripts/bootstrap.sh        # flutter create + vá quyền, minSdk, iOS 15.5…
flutter test                     # kiểm thử đơn vị
flutter run                      # chạy trên điện thoại đang cắm
flutter build apk --release      # APK Android
```

iOS: mở `ios/Runner.xcworkspace` bằng Xcode, chọn Team ký ứng dụng, rồi Run trên iPhone. Chi tiết: [docs/BUILD.md](docs/BUILD.md).

## Kiến trúc

```
lib/
  core/            geometry.dart (homography, warp bicubic, xoay)
                   rectify.dart  (tinh chỉnh mép giấy, tỷ lệ thật, khớp A4, làm thẳng chữ)
                   dewarp.dart   (giấy cong: mép cong, mô hình trụ 3D, lưới Coons), ids.dart
  models/          document.dart, edit_params.dart (chỉnh sửa không phá huỷ)
  services/
    imaging/       document_detector.dart  – nhận diện 4 góc (thuần Dart)
                   frame_analyzer.dart     – phân tích khung camera trong isolate
                   enhancer.dart           – cân bằng sáng/khử bóng, 4 chế độ màu
                   quality.dart            – kiểm tra mờ, tối, cháy sáng, bóng, mất góc
                   pipeline.dart           – giải mã EXIF, render, chạy ngoài UI thread
    storage/       app_storage.dart        – SQLite metadata + file trong thư mục app
    export/        export_core.dart        – PDF/GIF + kiểm tra file đầu ra
                   export_service.dart     – xuất, đặt tên, chống ghi đè, chia sẻ
    ocr/           ocr_service.dart        – ML Kit on-device, tuỳ chọn
  screens/         home, camera, editor, page_manager, export, library, settings
  widgets/         corner_editor.dart (kéo góc + kính lúp), common.dart
native_templates/  MainActivity.kt, AppDelegate plugin (dung lượng trống), Podfile
scripts/           bootstrap.sh, patch_platforms.py
test/              kiểm thử đơn vị hình học, nhận diện, xử lý ảnh, xuất file
```

Nguyên tắc bảo toàn nội dung: chỉ dùng phép biến đổi ảnh cổ điển (homography + nội suy song tuyến, chia nền thích ứng theo từng ảnh, Sauvola, unsharp có giới hạn). **Không dùng AI tạo lại chữ**, không đoán số, không ghi đè ảnh gốc.

## Tài liệu

- [docs/REQUIREMENTS_MATRIX.md](docs/REQUIREMENTS_MATRIX.md) – bảng đối chiếu từng yêu cầu ↔ mã nguồn ↔ trạng thái
- [docs/GEOMETRY_VALIDATION.md](docs/GEOMETRY_VALIDATION.md) – kiểm chứng nắn phẳng/tỷ lệ bằng mô phỏng camera
- [docs/RISKS.md](docs/RISKS.md) – rủi ro kỹ thuật và phương án thay thế
- [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md) – thư viện, lý do chọn, trạng thái kiểm chứng
- [docs/BUILD.md](docs/BUILD.md) – hướng dẫn build Android/iOS
- [docs/TEST_PLAN.md](docs/TEST_PLAN.md) – kế hoạch kiểm thử trên thiết bị (60 ảnh mẫu)
- [docs/USER_GUIDE.md](docs/USER_GUIDE.md) – hướng dẫn sử dụng

**App làm bởi Đào Duy Thanh – © since 2026.**

Font `assets/fonts/DejaVuSans.ttf` (dùng cho lớp chữ OCR trong PDF, hỗ trợ tiếng Việt) – giấy phép tự do, xem `assets/fonts/DejaVu-LICENSE.txt`.
