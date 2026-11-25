# Vercel & GitHub

Repo gồm 2 phần:

| Phần | Thư mục | Chạy ở đâu |
|---|---|---|
| **Web app APP scan PDF (PWA)** | `site/` | Vercel: mở bằng trình duyệt điện thoại, cài lên màn hình chính được |
| App Android/iOS (Flutter) | `lib/`, `test/`… | GitHub Actions build APK, đăng lên Releases |

`vercel.json` đã cấu hình sẵn: Vercel phục vụ thư mục `site/` và tự điền tên repo cho nút tải APK. Không cần sửa file nào.

## Trên Vercel
Project → Settings → Build & Deployment → **Framework Preset: Other** (Root Directory để trống) → **Redeploy**.

## Dùng trên điện thoại
- Mở link Vercel bằng **Chrome (Android)** hoặc **Safari (iPhone)**, bấm "Scan tài liệu" rồi cho phép camera.
- Cài như app:
  - Android: bấm nút "Cài đặt app" trên trang chủ, hoặc menu ⋮ → Thêm vào màn hình chính.
  - iPhone: Safari → nút Chia sẻ → Thêm vào MH chính.
- Camera cần HTTPS. Link Vercel đã là HTTPS.

## Cách dùng (giống CamScanner)
1. Bấm nút camera tròn → chọn **Một trang** hoặc **Nhiều trang** → giữ máy yên để app tự chụp (hoặc bấm chụp).
2. **Cắt**: kéo 4 góc hoặc 4 cạnh (có kính lúp). Các nút: Tự động, Toàn ảnh, Xoay, Nắn cong, Bỏ ảnh → **Tiếp**.
3. **Bộ lọc** (như CamScanner): **Tự động** / **Magic Color** / **Làm sáng** / Gốc / Xám / Trắng đen.
   - Nút **☀ Xoá bóng** (bật sẵn): xoá bóng đèn, bóng tay, bóng điện thoại hắt lên giấy, kể cả bóng có mép sắc.
     Nét chữ giữ nguyên độ đậm và độ sắc (không làm mờ); highlight màu, con dấu, ảnh màu được giữ lại.
   - 🎚️ để chỉnh Độ sáng, Tương phản, **Chi tiết** (độ nét), Làm thẳng → **Xong**.
   - Giới hạn: một ô xám trơn (không có chữ) nằm giữa trang có thể bị coi là nền và làm trắng, giống các app scan khác.
4. **Tài liệu**: Thêm trang, Nhập ảnh, Chia sẻ (PDF/JPG/ảnh gốc), Lưu PDF. Chạm 1 trang để cắt lại, đổi bộ lọc, xoay, đổi thứ tự, xoá.

Mỗi trang được dựng ảnh chất lượng cao (A4 300 DPI) **một lần** khi bấm Xong, nên tạo PDF gần như tức thì.
Trên iPhone, "Lưu PDF" mở bảng chia sẻ của iOS → chọn **Lưu vào Tệp**.

## Khác biệt bản web và APK
- Bản web: chụp, tự nhận 4 góc, nắn phẳng và nắn cong, làm sáng, nhiều trang, xuất PDF/JPG/PNG/ảnh gốc, chia sẻ, chạy offline.
- Chỉ APK có: OCR, xuất GIF.
- Độ phân giải chụp của bản web phụ thuộc trình duyệt:
  - Chrome Android có ImageCapture nên chụp được ảnh đầy đủ.
  - Safari iPhone lấy khung hình từ video, độ phân giải thấp hơn ảnh chụp gốc.
  - Để có chất lượng tối đa trên iPhone: chụp bằng app Camera rồi bấm "Chọn ảnh".
