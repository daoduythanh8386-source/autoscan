# Hướng dẫn build

## Chuẩn bị chung
- Flutter stable 3.24 trở lên (`flutter doctor` không còn lỗi).
- Python 3 (dùng cho `scripts/patch_platforms.py`).

```bash
bash scripts/bootstrap.sh
```
Script sẽ chạy `flutter create --platforms android,ios .` (không ghi đè `lib/`, `pubspec.yaml`, `test/`), sau đó vá:
- Android: quyền `CAMERA`, `minSdk 24`, tên app, `MainActivity.kt` (kênh dung lượng trống), `proguard-rules.pro` cho ML Kit.
- iOS: `NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription`, hiện file xuất trong app **Tệp**, iOS 15.5, `Podfile`, kênh dung lượng trống trong `AppDelegate.swift`.

## Android
```bash
flutter test
flutter build apk --release          # build/app/outputs/flutter-apk/app-release.apk
flutter build appbundle --release    # AAB để đưa lên Google Play
```
Mặc định bản release ký bằng **debug key** (chỉ để cài thử). Muốn phát hành, tạo keystore và cấu hình `signingConfigs` trong `android/app/build.gradle.kts` theo hướng dẫn chính thức của Flutter.

Cài thử: chép APK vào điện thoại → mở file → cho phép "Cài ứng dụng không rõ nguồn".

## iOS (cần macOS + Xcode)
```bash
cd ios && pod install && cd ..
open ios/Runner.xcworkspace
```
Trong Xcode: Runner → Signing & Capabilities → chọn Team (Apple ID) → chọn iPhone → Run.
- Với Apple ID miễn phí: app chạy 7 ngày rồi phải cài lại.
- Muốn tạo IPA/TestFlight: cần Apple Developer Program, sau đó `flutter build ipa`.

CI chỉ build `--no-codesign` để kiểm tra mã biên dịch được. **File này không cài được lên iPhone** cho tới khi được ký.

## Kiểm thử trên thiết bị
Làm theo `docs/TEST_PLAN.md` và ghi kết quả vào `docs/TEST_REPORT.md`.
