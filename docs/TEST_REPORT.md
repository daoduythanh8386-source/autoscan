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
