# Mục tiêu ứng dụng PDF Duplex Batch Printer

## 1. Tầm nhìn

PDF Duplex Batch Printer là ứng dụng macOS native giúp người dùng in hàng loạt tài liệu PDF và hình ảnh trên máy in một mặt, đồng thời thực hiện in hai mặt thủ công theo quy trình rõ ràng, ổn định và hạn chế tối đa việc đảo sai thứ tự giấy.

Ứng dụng tập trung vào tình huống thực tế tại gia đình, lớp học và văn phòng nhỏ: người dùng có nhiều tài liệu cần in liên tiếp nhưng máy in không hỗ trợ đảo mặt tự động hoặc driver máy in không xử lý thứ tự trang đúng như mong muốn.

## 2. Người dùng mục tiêu

- Giáo viên in đề bài, đáp án và tài liệu học tập theo lô.
- Phụ huynh in bài tập cho học sinh tại nhà.
- Văn phòng nhỏ sử dụng máy in một mặt hoặc máy in có driver duplex không ổn định.
- Người dùng cần in nhiều hình ảnh theo thứ tự xác định.
- Người dùng muốn kiểm soát chính xác thứ tự Odd/Even và thao tác lật giấy.

## 3. Vấn đề cần giải quyết

- Phải mở và in từng file riêng lẻ, dễ bỏ sót hoặc nhầm thứ tự.
- Khó xác định trang lẻ/chẵn cần in xuôi hay ngược đối với từng loại máy in.
- Dễ lật hoặc xoay chồng giấy sai chiều khi in hai mặt thủ công.
- Tài liệu có số trang lẻ có thể làm lệch cặp mặt trước/mặt sau.
- Một số driver bỏ qua trang trắng, làm sai toàn bộ thứ tự giấy.
- Lớp annotation hoặc phần lời giải trong PDF đôi khi không được driver in ra.
- Khó theo dõi file hoặc hình ảnh nào đang in, đã hoàn thành hay bị lỗi.
- Tên file ảnh dài khiến việc kiểm tra thứ tự bằng danh sách chữ không thuận tiện.

## 4. Mục tiêu chức năng

### 4.1. Hàng đợi PDF

- Thêm nhiều PDF cùng lúc bằng hộp chọn file hoặc kéo thả.
- Sắp xếp lại thứ tự trước khi in.
- Xử lý tuần tự từng file: Odd → chờ lật giấy → Even → file tiếp theo.
- Cho phép chọn độc lập thứ tự trang của lượt Odd và Even.
- Tạo trang trắng đệm cho tài liệu có số trang lẻ và buộc máy in nạp trang đó.
- Bỏ qua bước lật giấy đối với tài liệu chỉ có một trang.
- Làm phẳng annotation để nội dung hiển thị trong PDF được in đầy đủ.

### 4.2. Hàng đợi hình ảnh

- Thêm và sắp xếp nhiều hình ảnh; mỗi hình tương ứng một trang in.
- Hỗ trợ in một mặt hoặc hai mặt thủ công.
- Co vừa ảnh theo khổ A4 hoặc Letter, giữ tỷ lệ và không cắt nội dung.
- Khi in một mặt, gửi từng ảnh tuần tự để trạng thái từng trang được cập nhật theo thời gian thực.
- Khi in hai mặt, áp dụng cùng quy tắc Odd/Even và trang trắng đệm như PDF.

### 4.3. Kiểm tra và sắp xếp

- Chuyển giữa chế độ xem List và Thumbnails.
- Hiển thị số thứ tự rõ ràng trên từng hàng hoặc thumbnail.
- Preview trực tiếp PDF và hình ảnh trước khi in.
- Duyệt Previous/Next trong cửa sổ Preview để kiểm tra toàn bộ thứ tự.
- Cho phép di chuyển và xóa nội dung ngay từ chế độ thumbnail.

### 4.4. Máy in và profile

- Liệt kê các máy in đã cài đặt trên macOS thông qua CUPS.
- Lưu profile riêng cho từng máy in.
- Profile bao gồm khổ giấy, màu, thứ tự Odd/Even, hướng xoay khi nạp lại và cạnh đóng gáy.
- Dùng chung một profile cho toàn bộ batch để kết quả nhất quán.
- Cung cấp tài liệu calibration để xác định đúng chiều nạp giấy thực tế.

### 4.5. Trạng thái và khôi phục lỗi

- Hiển thị Ready, Printing (với PDF là Printing odd pages / Printing even pages), Waiting for paper flip, Completed, Skipped, Error và Missing (hiển thị trên UI là "Original file not found").
- Cảnh báo trong app và gửi notification khi cần lật giấy.
- Cho phép Retry, Skip hoặc Cancel khi xảy ra lỗi.
- Retry ảnh một mặt phải tiếp tục đúng ảnh lỗi, không in lại các ảnh đã hoàn thành.
- Theo dõi job CUPS và chỉ chuyển bước sau khi job hiện tại kết thúc.

### 4.6. Lưu trạng thái

- Lưu danh sách PDF, danh sách ảnh và thứ tự của chúng khi đóng app.
- Lưu máy in và profile đã chọn.
- Dùng macOS file bookmark để khôi phục quyền truy cập file.
- Giữ lại mục bị mất file và hiển thị trạng thái Missing thay vì tự động xóa.

## 5. Mục tiêu trải nghiệm người dùng

- Người dùng không cần hiểu lệnh CUPS hoặc tự tách file Odd/Even.
- Luồng in phải thể hiện rõ việc cần làm tiếp theo.
- Các thao tác nguy hiểm trong khi đang in phải bị khóa để tránh thay đổi hàng đợi giữa chừng.
- Trạng thái phải phản ánh đúng phạm vi theo dõi được của CUPS, không báo hoàn thành sớm.
- Preview và thumbnail phải giúp nhận ra nhanh nội dung ngay cả khi tên file khó đọc.
- Giao diện phải hoạt động như ứng dụng macOS native, có icon và xuất hiện trên Dock.

## 6. Mục tiêu kỹ thuật

- Xây dựng bằng SwiftUI, AppKit và PDFKit trên macOS 14 trở lên.
- Sử dụng CUPS (`lp`, `lpstat`, `cancel`) để gửi, theo dõi và hủy job in.
- Mỗi pass luôn ép `sides=one-sided`, `copies=1` và `number-up=1` để tránh driver tự thay đổi quy trình.
- Tạo file PDF tạm cho từng pass và xóa sau khi hoàn thành hoặc lỗi.
- Cache hàng đợi và profile bằng JSON trong Application Support.
- Có kiểm thử tự động cho planner, PDF/image generation, CUPS parsing, cache và state machine.

## 7. Tiêu chí thành công

- Một batch nhiều PDF hoàn tất đúng thứ tự mà không cần mở từng file thủ công.
- Với profile mặc định, tài liệu 9 trang in Odd `9, 7, 5, 3, 1` và Even `2, 4, 6, 8, 10`, trong đó trang 10 là trang trắng đệm.
- File một trang không yêu cầu lật giấy.
- Danh sách ảnh một mặt cập nhật Completed lần lượt sau từng ảnh.
- Danh sách và profile được khôi phục đúng sau khi đóng/mở app.
- Trang trắng không bị driver Epson bỏ qua khi máy hỗ trợ tùy chọn kiểm soát blank page.
- Annotation và lời giải hiển thị trong PDF xuất hiện trên bản in.
- Người dùng có thể xác nhận thứ tự bằng Preview hoặc Thumbnails trước khi in.
- Toàn bộ bộ kiểm thử của dự án đạt trước khi phát hành bản app mới.

## 8. Ngoài phạm vi hiện tại

- Không thay thế toàn bộ hộp thoại Print hoặc driver của macOS.
- Không đảm bảo phát hiện được giấy đã được đặt đúng chiều bằng cảm biến vật lý.
- Không điều khiển được các tùy chọn độc quyền mà driver không công bố qua CUPS.
- Không chỉnh sửa nội dung PDF hoặc hình ảnh như một ứng dụng thiết kế.
- Không đồng bộ hàng đợi qua cloud hoặc nhiều máy Mac.
- Không hỗ trợ Windows, Linux, iPhone hoặc iPad trong phiên bản hiện tại.

## 9. Hướng phát triển

- Cho phép lưu nhiều preset bố cục ảnh trên một trang.
- Hỗ trợ kéo thả trực tiếp để sắp xếp thumbnail.
- Hiển thị lịch sử batch và thống kê số trang đã in.
- Cho phép tiếp tục batch sau khi app hoặc máy Mac khởi động lại.
- Bổ sung localization đầy đủ cho tiếng Việt và tiếng Anh.
- Đóng gói, ký Developer ID và notarize để phân phối ngoài máy phát triển.
