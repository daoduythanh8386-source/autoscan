# Kiểm thử web app (site/)

1. `python3 tools/sim/gen_cases.py`: sinh ảnh mô phỏng vào /tmp/jt (cần numpy, opencv).
2. `node tools/web_e2e/node_pipeline.js`: chạy lõi `site/cv.js` trên ảnh mô phỏng, ghi kết quả ra /tmp/jt/res.json.
3. Chạy web: `cd site && python3 -m http.server 8765`
4. `python3 tools/web_e2e/e2e_camera.py`: Chromium mô phỏng điện thoại với camera giả (/tmp/doc.y4m). Kịch bản: tự chụp → chỉnh sửa → xuất PDF/JPG → tải lại trang.
5. `python3 tools/web_e2e/e2e_import_curved.py`: nhập ảnh giấy cong (/tmp/e2e/book.jpg, curl.jpg) → nắn cong → xuất PDF.
6. `python3 tools/web_e2e/e2e_safari_fallback.py`: ép `createImageBitmap` lỗi như trên Safari iPhone, kiểm tra đường giải mã dự phòng.

Kết quả lần chạy 2026-11-23: tự chụp sau 2,1 giây; PDF A4 hợp lệ (qpdf, pypdf); dữ liệu còn sau khi tải lại trang; 2 ảnh giấy cong được nắn tự động; không có lỗi JavaScript.
