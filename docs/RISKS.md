# Rủi ro kỹ thuật & phương án thay thế

| Rủi ro | Ảnh hưởng | Giảm thiểu hiện tại | Phương án nếu không đạt |
|---|---|---|---|
| Nhận diện 4 góc thuần Dart (Otsu + thành phần liên thông + bao lồi) kém trên nền sáng, nền hoa văn, giấy trắng trên bàn trắng | Không tự crop được → người dùng phải kéo góc | Chấm điểm tin cậy; thấp thì **không crop**, mở chỉnh tay; thử cả 2 cực tính | Thay `DocumentDetector` bằng OpenCV (`opencv_dart` hoặc OpenCV NDK/iOS framework: Canny + findContours + approxPolyDP) hoặc Apple Vision `VNDetectRectanglesRequest` trên iOS. Interface đã tách sẵn. |
| Toạ độ góc tính trên ảnh thu nhỏ 720px | (Đã xử lý) | `refineQuad` dò mép ở độ phân giải đầy đủ, mô phỏng < 1 px | Nếu mép giấy mờ/nền cùng màu: người dùng kéo tay + "Bắt dính mép giấy". |
| Giải mã/xử lý JPEG 12–50MP bằng Dart thuần chậm & tốn RAM | Chờ 2–8 giây/trang; máy RAM thấp có thể bị đóng app | Chạy trong isolate; xem trước 1600px; PDF nạp ảnh từng trang | Chuyển giải mã/warp sang native (Android Bitmap/OpenCV, iOS Core Image/Accelerate) qua platform channel. |
| Ngưỡng chất lượng (độ nét, tối, cháy sáng) chưa hiệu chuẩn | Cảnh báo sai/thiếu | Ngưỡng tập trung trong `QualityAssessor`, dễ chỉnh | Hiệu chuẩn bằng bộ 60 ảnh mẫu (mục 25). |
| Tỷ lệ rộng/cao sau nắn phẳng | (Đã xử lý) bản v0.1 sai 12–53% | `estimateAspect`: EXIF → điểm tụ → mặc định, khớp khổ chuẩn | Giấy khổ lạ + không EXIF + nghiêng 1 trục mạnh: sai ~1–3%, chọn khổ tay. |
| Giấy cong (sách, giấy gấp) | Chữ gần gáy bị cong | Chưa phát hiện | Phát hiện độ cong của cạnh và cảnh báo; khử cong cần mô hình mặt cong. |
| Ảnh HEIC từ thư viện iPhone | `image` không giải mã được HEIC | Báo lỗi rõ ràng + hướng dẫn | Giải mã HEIC bằng native (UIImage/ImageIO) trước khi xử lý. |
| ML Kit: iOS ≥ 15.5, chỉ arm64; dung lượng app tăng; độ chính xác tiếng Việt chưa đo | Build/OCR có thể lỗi | OCR tách module, lỗi không chặn xuất | Tesseract (`vie.traineddata`) on-device làm engine thay thế. |
| Plugin `camera`: stream ảnh khi chọn độ phân giải tối đa không ổn định trên một số máy Android | Không có viền nhận diện trực tiếp | Lỗi stream được bỏ qua, vẫn chụp tay + nhận diện sau chụp | Dùng CameraX native với ImageAnalysis riêng độ phân giải thấp. |
| Hướng khung stream (sensorOrientation) khác nhau giữa các máy | Viền vẽ lệch | Suy hướng xoay từ kích thước khung + sensorOrientation | Kiểm thử ma trận thiết bị; sửa theo từng hãng nếu cần. |
| Android: lưu ra thư mục tuỳ ý ngoài app | Hạn chế của Scoped Storage | Lưu trong app + Chia sẻ/"Lưu vào Tệp" của hệ điều hành | Storage Access Framework (`ACTION_CREATE_DOCUMENT`) qua platform channel. |
| Phiên bản thư viện chưa kiểm chứng build | CI có thể lỗi khi `pub get`/build | CI build trên cả 2 nền tảng sau mỗi lần đẩy code | Ghim lại phiên bản theo kết quả CI, cập nhật `DEPENDENCIES.md`. |
