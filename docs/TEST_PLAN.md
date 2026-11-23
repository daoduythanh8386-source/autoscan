# Kế hoạch kiểm thử trên thiết bị (mục 25–27)

## Thiết bị tối thiểu
| Nhóm | Ví dụ | Ghi chú |
|---|---|---|
| Android tầm trung | RAM 4 GB, camera 48 MP | kiểm tra RAM/thời gian xử lý |
| Android cao cấp | RAM 8 GB+ | |
| iPhone | iPhone 11 trở lên, iOS ≥ 15.5 | |

## Bộ 60 ảnh mẫu (mỗi loại ≥ 4 ảnh, chụp bằng cả 3 thiết bị)
Văn bản in nhỏ · Bảng số liệu · Đồng hồ đo · Hóa đơn · Giấy có dấu đỏ · Giấy có chữ ký · Văn bản tiếng Việt · Văn bản có số thập phân · Giấy bị nghiêng · Giấy bị bóng tay · Giấy thiếu sáng · Nền có hoa văn · Giấy bóng (phản sáng) · Giấy cong nhẹ · Tài liệu nhiều trang.

Lưu ảnh gốc (xuất "Ảnh gốc") vào thư mục `test_images/<loại>/` để chạy hồi quy sau này.

## Ca kiểm thử
| Mã | Ca | Tiêu chí đạt |
|---|---|---|
| D1 | Độ chính xác 4 góc | ≥ 90% ảnh tự crop đúng (lệch ≤ 1% đường chéo); ảnh còn lại KHÔNG crop sai mà chuyển chỉnh tay |
| D2 | Nền phức tạp / hoa văn | Không tự crop sai |
| D3 | Giấy bị che một phần | Hiển thị cảnh báo "bị che" |
| D4 | Ánh sáng yếu | Cảnh báo thiếu sáng; flash/torch hoạt động |
| Q1 | So sánh chữ trước/sau (phóng 200%) | Không mất nét, không viền giả |
| Q2 | Số liệu, dấu thập phân, dấu âm | Đọc được như ảnh gốc, không mất dấu chấm/phẩy |
| Q3 | Dấu đỏ, chữ ký xanh (chế độ Màu gốc & Tài liệu màu) | Giữ màu, không bị tẩy |
| Q4 | Đường kẻ bảng | Thẳng, liền mạch |
| E1 | PDF nhiều trang | Mở được bằng Google Drive, Adobe Acrobat, Tệp (iOS); đúng thứ tự |
| E2 | PNG | Kích thước = ảnh đã xử lý; lossless |
| E3 | JPG | Đúng chất lượng đã chọn |
| E4 | GIF | Đúng số khung, thời gian, lặp |
| E5 | Ảnh gốc | Trùng từng byte với ảnh chụp/nhập (checksum) |
| E6 | Tên file tiếng Việt, trùng tên | Giữ dấu; hỏi đổi tên/thay thế |
| E7 | Chia sẻ Zalo, Gmail, Messenger, Drive | Người nhận mở được file |
| S1 | Tắt app khi đang scan (vuốt bỏ) | Mở lại thấy bản nháp đủ trang |
| S2 | Bộ nhớ gần đầy | Có cảnh báo, không hỏng file |
| S3 | Chế độ máy bay | Scan, chỉnh, lưu, xuất, OCR đều chạy |
| P1 | Thời gian nhận diện khung | Viền cập nhật ≥ 4 lần/giây |
| P2 | Thời gian xử lý 1 trang 12 MP | Ghi lại số đo; UI không đơ |
| P3 | 20 trang liên tiếp → PDF | Không bị đóng app do hết RAM |
| O1 | OCR tiếng Việt có dấu | Ghi tỷ lệ ký tự đúng; tìm kiếm trong PDF hoạt động |

Ghi kết quả vào `TEST_REPORT.md` theo đúng 4 trạng thái: PASS / NEEDS FIX / NOT VERIFIED / NOT SUPPORTED.
