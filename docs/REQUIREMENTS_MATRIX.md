# Bảng đối chiếu yêu cầu – SMART DOCUMENT SCANNER v0.1

Phân loại trạng thái theo mục 27: **PASS** (đã kiểm thử và đạt) · **NEEDS FIX** · **NOT VERIFIED** (chưa kiểm thử) · **NOT SUPPORTED**.

Ngày lập: 2026-11-23. Môi trường soạn mã không có Flutter SDK hay thiết bị thật nên **mọi hạng mục đều là NOT VERIFIED**. Cột "Kiểm thử tự động" cho biết phần nào có unit test chạy trên CI. Unit test đạt cũng chưa đủ để chuyển sang PASS: theo đặc tả, phải kiểm thử trên điện thoại và mở file đầu ra thật.

| # | Yêu cầu (mục) | Triển khai | Kiểm thử tự động | Trạng thái |
|---|---|---|---|---|
| 2.1 | AUTO: nhận diện, viền, ổn định góc, tự chụp, chụp tay | `document_detector.dart`, `frame_analyzer.dart`, `camera_screen.dart` | detector_test (ảnh tổng hợp) | NOT VERIFIED |
| 2.1 | Độ tin cậy thấp → không tự crop, chuyển chỉnh tay | `CaptureAnalysis.autoCropReliable`, `camera_screen._capture` | detector_test (ảnh đồng màu) | NOT VERIFIED |
| 2.2 | MAXIMUM: ảnh gốc độ phân giải đầy đủ, không lấy preview làm nguồn | `ResolutionPreset.max`, `takePicture`, `ImagePipeline.render(maxSide: null)` | – | NOT VERIFIED |
| 2.2 | Không nén JPEG chồng | cache PNG lossless; JPG mã hoá 1 lần | export_test | NOT VERIFIED |
| 2.2 | Cảnh báo ảnh mờ, cháy sáng | `quality.dart` | – | NOT VERIFIED (ngưỡng chưa hiệu chuẩn) |
| 2.3 | OCR tuỳ chọn, mặc định tắt, lỗi OCR không ảnh hưởng | `ocr_service.dart`, `export_service.dart` (try/catch) | – | NOT VERIFIED |
| 2.3 | PDF có lớp chữ ẩn | `buildPdf` + `pw.Opacity(0)` + font DejaVu | – | NOT VERIFIED |
| 2.4 | DEVICE: không đăng nhập, không mạng, không cloud | không có thư viện mạng; ML Kit chạy trên máy | – | NOT VERIFIED (cần thử chế độ máy bay) |
| 2.4 | Cảnh báo bộ nhớ gần đầy | kênh native `sds/storage` + bắt ENOSPC | – | NOT VERIFIED |
| 3 | Camera: trước/sau, flash, lấy nét, phơi sáng, thư viện, xem trang, hoàn tất | `camera_screen.dart` | – | NOT VERIFIED |
| 3 | Lưới căn chỉnh, khung A4, thước thăng bằng trên camera | `_GridPainter`, `_LevelIndicator` (sensors_plus) | – | NOT VERIFIED |
| 12 | Tự động khổ A4 | khớp A4 ±6% (gần nhất), PDF mặc định A4, khổ lạ giữ tỷ lệ thật | rectify_test | NOT VERIFIED |
| 3 | Chỉ xin quyền cần thiết | CAMERA (Android), Camera + Thư viện ảnh (iOS); không xin quyền bộ nhớ | – | NOT VERIFIED |
| 4 | Làm mượt góc giữa khung hình | `CornerStabilityTracker` (EMA) | detector_test | NOT VERIFIED |
| 4 | Phát hiện bị che, nền phức tạp, thiếu sáng | issues `occluded`, `low_contrast`, `dark` | một phần | NOT VERIFIED |
| 6 | Kiểm tra chất lượng ngay sau chụp, đề nghị chụp lại | `quality.dart`, `_qualityDialog` | – | NOT VERIFIED |
| 6 | "Vùng chữ quá nhỏ" | ước lượng gián tiếp qua tỷ lệ diện tích tài liệu/khung | – | NOT VERIFIED (chưa đo kích thước chữ trực tiếp) |
| 7 | Homography + nội suy, không kéo giãn, không mất mép | `warpPerspectiveRgb` (bicubic có kẹp), `refineQuad` (mép giấy < 1 px), `estimateAspect` (tỷ lệ thật + khớp A4/Letter/Legal) | geometry_test, rectify_test, mô phỏng `tools/sim` | NOT VERIFIED (mô phỏng đạt, xem GEOMETRY_VALIDATION.md) |
| 7 | Làm thẳng dòng chữ, chụp ngang đúng chiều | `estimateSkew`, `rotateFineRgb`, bỏ khoá hướng chụp | rectify_test | NOT VERIFIED |
| 7 | Phát hiện & nắn giấy cong / mép quăn / gáy sách | `dewarp.dart`: đường cong 4 mép, mô hình trụ 3D, lưới Coons; thông báo sau khi chụp; nút "Nắn giấy cong" | dewarp_test, mô phỏng `tools/sim/curve.py` | NOT VERIFIED (mô phỏng đạt) |
| 8 | Cân bằng sáng thích ứng, khử bóng, khử ám vàng, giấy trắng – chữ rõ | `BackgroundModel` + chia theo kênh + kéo giãn tuyến tính (giữ biên nét) | enhancer_test, `tools/sim/enhance_check.py` | NOT VERIFIED |
| 9 | Bảo toàn dấu đỏ, chữ ký xanh, nét mảnh, không AI | nền chỉ ước lượng từ điểm ảnh độ bão hoà thấp; Sauvola k=0,15 | enhancer_test | NOT VERIFIED |
| 9 | 4 chế độ: Màu gốc / Tài liệu màu / Trắng đen / Thang xám | `ColorMode` | enhancer_test | NOT VERIFIED |
| 10 | Kéo góc, xoay, crop, sáng, tương phản, nét có giới hạn, cân bằng trắng, giảm bóng | `editor_screen.dart`, `corner_editor.dart` | – | NOT VERIFIED |
| 10 | Phóng to, so sánh trước/sau, hoàn tác/làm lại, khôi phục gốc, không phá huỷ | `InteractiveViewer`, lịch sử `EditParams` | enhancer_test (không sửa input) | NOT VERIFIED |
| 11 | Nhiều trang: thêm/xoá/xoay/sắp xếp/chọn/nháp/mở lại | `page_manager_screen.dart`, `app_storage.dart` | – | NOT VERIFIED |
| 11 | Không mất trang khi app bị đóng đột ngột | ảnh gốc ghi atomic + ghi DB ngay khi chụp | – | NOT VERIFIED |
| 12 | PDF 1/nhiều trang, A4/A5/Letter/tự động, nén, xem trước, đặt tên | `export_core.buildPdf`, `export_screen.dart` | export_test | NOT VERIFIED |
| 12 | Kiểm tra PDF sau khi xuất | `verifyPdf` (header, %%EOF, số trang) | export_test | NOT VERIFIED (chưa mở bằng trình đọc thật) |
| 13 | PNG lossless, kiểm tra từng pixel | `verifyPngLossless` | export_test | NOT VERIFIED |
| 14 | JPG chọn chất lượng | slider 60–100, mặc định 95 | export_test | NOT VERIFIED |
| 14 | "Kiểm tra mất nét do nén" | chỉ cảnh báo trong UI khi chất lượng < 85 | – | **NEEDS FIX** (chưa đo PSNR/độ nét sau nén) |
| 15 | GIF: nhiều trang, thời gian khung, lặp, kích thước, cảnh báo 256 màu | `buildGif` | export_test | NOT VERIFIED |
| 16 | Xuất ảnh gốc nguyên byte, giữ metadata | sao chép byte + `verifyIdentical` | export_test | NOT VERIFIED |
| 17 | Đặt/đổi tên (có dấu), thư mục, ngày/trang/định dạng/dung lượng, xoá có xác nhận, chống ghi đè | `app_storage.dart`, `library_screen.dart` | export_test (sanitize) | NOT VERIFIED |
| 17 | Chọn thư mục ngoài app | thư mục con trong vùng app; iOS hiện trong app Tệp | – | NOT VERIFIED (Android: dùng Chia sẻ để lưu ra ngoài) |
| 18 | Chia sẻ file thật qua hệ điều hành | `share_plus` `shareXFiles` | – | NOT VERIFIED |
| 19 | OCR tiếng Việt, số, nhiều trang, tìm kiếm, cảnh báo không chắc chắn | ML Kit Latin; tìm kiếm theo OCR trong thư viện | – | NOT VERIFIED |
| 19 | Sao chép văn bản OCR trong app | qua PDF (lớp chữ) | – | **NEEDS FIX** (chưa có nút sao chép văn bản trong app) |
| 20 | Tách module, xử lý nặng ngoài UI thread, thay engine được | `Isolate.run`; `DocumentDetector`/`OcrEngine` là interface thay được | – | NOT VERIFIED |
| 22 | SQLite metadata, file ngoài DB, nháp, toàn vẹn file | `app_storage.dart` | – | NOT VERIFIED |
| 23 | Không log nội dung tài liệu | không có lệnh log nội dung | – | NOT VERIFIED |
| 24 | 6 màn hình, giao diện tiếng Việt | `screens/` | – | NOT VERIFIED |
| 25–26 | Bộ 60 ảnh mẫu, kiểm thử hiệu năng | kế hoạch trong `TEST_PLAN.md` | – | NOT VERIFIED |
| 29.11 | APK Android | CI `flutter build apk` | – | NOT VERIFIED cho đến khi CI chạy xanh |
| 29.12 | IPA iOS | CI build không ký; IPA cần tài khoản Apple Developer | – | NOT SUPPORTED trong môi trường này |
