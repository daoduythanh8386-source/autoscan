# Báo cáo kiểm thử

| Lần | Ngày | Môi trường | Kết quả |
|---|---|---|---|
| 0 | 2026-11-23 | Soạn mã, không có Flutter SDK/thiết bị | Chưa chạy bất kỳ kiểm thử nào. Toàn bộ hạng mục: **NOT VERIFIED**. |

## Kiểm thử tự động (CI)
Kết quả `flutter analyze`, `flutter test`, build APK và iOS (không ký) xem tại tab **Actions** của repo. Khi có kết quả, cập nhật bảng dưới.

| Bộ test | Số ca | Kết quả |
|---|---|---|
| geometry_test | 5 | NOT VERIFIED |
| detector_test | 4 | NOT VERIFIED |
| enhancer_test | 6 | NOT VERIFIED |
| export_test | 6 | NOT VERIFIED |
| widget_test | 1 | NOT VERIFIED |
| rectify_test | 7 | NOT VERIFIED |
| dewarp_test | 7 | NOT VERIFIED |

## Mô phỏng hình học (lần 1, 2026-11-23)
Python/OpenCV, 7 tư thế camera: góc < 1 px sau tinh chỉnh; tỷ lệ đúng khổ A4 ở cả 7 tư thế (cách cũ sai tới 53%). Chi tiết: `GEOMETRY_VALIDATION.md`.

## Kiểm thử trên thiết bị
Chưa thực hiện. Xem `TEST_PLAN.md`.


## Mô phỏng giấy cong & làm sáng (lần 2, 2026-11-23)
Mép quăn 16→7, gáy sách 17→0, gợn sóng 20→5 px/1000; giấy phẳng không bị can thiệp. Tương phản chữ/nền 135→199. Chi tiết: `GEOMETRY_VALIDATION.md`.


## Xoá bóng đèn (web 1.1)

Ảnh mô phỏng tờ A4 có bóng đèn mép sắc (giấy trong bóng tối hơn ~53%), kèm highlight vàng, ô xám, khối màu cam.

| Chỉ số | Ảnh chụp | Trước (Tăng cường) | Mới: Tự động + Xoá bóng | Magic Color |
|---|---|---|---|---|
| Chênh lệch nền trong/ngoài bóng (0–255) | 107 | 12 | **3** | 4 |
| Vệt mép bóng (điểm tối nhất 5% sát mép) | 91 | 164 | **251** | 250 |
| Độ đậm mực trong / ngoài bóng | 12 / 25 | 10 / 13 | **9 / 11** | 10 / 11 |
| Độ sắc mép chữ trong / ngoài bóng (Sobel p90) | 394 / 766 | 980 / 977 | **1011 / 1017** | 1017 / 1020 |

- Highlight vàng, khối màu cam và ô xám nằm trong vùng bóng: giữ nguyên màu.
- Ô xám trơn không chữ ở vùng sáng: bị làm trắng (giới hạn đã biết).
- Thời gian ở trang A4 300 DPI (2480×3508, Node, 1 luồng): 0,6 s khi không xoá bóng, 2,6 s khi xoá bóng.
