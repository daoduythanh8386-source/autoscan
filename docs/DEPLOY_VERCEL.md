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

## Khác biệt bản web và APK
- Bản web: chụp, tự nhận 4 góc, nắn phẳng và nắn cong, làm sáng, nhiều trang, xuất PDF/JPG/PNG/ảnh gốc, chia sẻ, chạy offline.
- Chỉ APK có: OCR, xuất GIF.
- Độ phân giải chụp của bản web phụ thuộc trình duyệt:
  - Chrome Android có ImageCapture nên chụp được ảnh đầy đủ.
  - Safari iPhone lấy khung hình từ video, độ phân giải thấp hơn ảnh chụp gốc.
  - Để có chất lượng tối đa trên iPhone: chụp bằng app Camera rồi bấm "Chọn ảnh".
