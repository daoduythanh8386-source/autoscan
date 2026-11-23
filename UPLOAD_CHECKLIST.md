# Trước khi đưa lên GitHub – kiểm tra không thiếu file

1. Chạy kiểm tra (cần Python 3):
   ```
   python3 scripts/check_files.py
   ```
   Phải thấy dòng **"KẾT QUẢ: ĐẦY ĐỦ – sẵn sàng upload."**
2. Danh sách đầy đủ, kèm kích thước và mã SHA-256 của từng file, nằm trong **FILES.md**.
3. Những chỗ hay bị thiếu khi upload bằng trình duyệt:
   - Thư mục ẩn **`.github/`**: không có nó thì GitHub không tự build APK. Trên Windows, bật *View → Hidden items* để thấy thư mục này.
   - File **`.gitignore`**, **`vercel.json`**.
   - Thư mục **`assets/fonts/`**, **`native_templates/`**, **`site/`**, **`scripts/`**.
   - GitHub web chỉ nhận tối đa **100 file mỗi lần kéo thả**. Dự án có khoảng 75 file, vẫn nên upload theo từng thư mục cho chắc.
4. **KHÔNG cần** upload `android/`, `ios/`, `build/`, `.dart_tool/`. GitHub Actions tự sinh các thư mục này.
5. Sau khi đẩy lên, vào tab **Actions**. Bước đầu tiên "Rà soát đủ file" sẽ báo đích danh file nào còn thiếu.
