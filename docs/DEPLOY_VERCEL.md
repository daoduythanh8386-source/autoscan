# Vercel & GitHub – vì sao bị 404 và cách sửa

**APP scan PDF là ứng dụng điện thoại (Flutter Android/iOS), không phải trang web.**
Vercel chỉ phục vụ trang web, nên khi liên kết thẳng repo vào Vercel, Vercel không tìm thấy trang nào để hiển thị và báo `404 NOT_FOUND`.

## Cách dùng đúng
1. **GitHub** build ra app: mỗi lần đẩy code lên nhánh `main`, workflow *Build & Test* chạy kiểm thử, build APK rồi đăng lên mục **Releases**.
2. **Vercel** chỉ hiển thị trang giới thiệu và nút tải APK, nằm trong thư mục `site/`. File `vercel.json` đã cấu hình sẵn `outputDirectory: site`.

## Các bước
1. Mở file `site/config.js`, sửa thành tên repo của bạn, ví dụ:
   `window.APP_REPO = "ten-tai-khoan/ten-repo";`
2. Đẩy code lên GitHub (nhánh `main`).
3. Trên Vercel: Project → Settings → Build & Deployment:
   - Framework Preset: **Other**
   - Root Directory: để trống (thư mục gốc repo)
   - Các ô Build/Output: để mặc định, vì `vercel.json` đã cấu hình
   Sau đó vào Deployments → **Redeploy**.
4. Trên GitHub: tab **Actions** → xem lần chạy *Build & Test*. Nếu thành công, APK có trong **Releases** và nút "Tải APK" trên trang Vercel sẽ hoạt động.

Nếu Actions báo lỗi (đỏ), gửi ảnh chụp hoặc link lần chạy cho Claude để sửa.
