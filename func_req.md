# NoTeleCamera — Danh sách chức năng
 
App chụp ảnh & quay video cho iPhone 13 Pro, khoá cứng ở cụm Dual Wide
(ống siêu rộng 0,5× + ống chính 1×). **Ống tele 77mm không bao giờ được
cấp điện**, nên OIS hỏng của nó không kêu và không lọt vào tiếng video.
 
- Yêu cầu: iOS 17+, Xcode 15+, chạy trên máy thật
- Trạng thái: Giai đoạn 1 + 2 + 3 đã xong
### Các file mã nguồn
 
| File | Nội dung |
|---|---|
| `CaptureTypes.swift` | enum chế độ, tuỳ chọn, ghi nhớ cài đặt |
| `CameraManager.swift` | session, ống kính, zoom, lấy nét, các chế độ ghi hình |
| `CameraManager_Capture.swift` | chụp ảnh, ProRAW, Live Photo, chân dung |
| `MediaProcessing.swift` | xuất quay chậm, ghép tua nhanh, tiện ích ảnh |
| `CameraUI.swift` | toàn bộ giao diện |
| `NoTeleCameraApp.swift` | điểm vào |
 
⚠️ `NoTeleCamera_Phase1.swift` phải được gỡ khỏi target hoặc xoá hẳn — nó
khai báo lại `CameraManager`, `ContentView` và một `@main` thứ hai.
 
---
 
## 0. Cấu hình bắt buộc
 
Thêm vào Info.plist, thiếu là app crash:
 
| Key | Dùng cho |
|---|---|
| `NSCameraUsageDescription` | Mở camera |
| `NSMicrophoneUsageDescription` | Thu âm khi quay video |
| `NSPhotoLibraryAddUsageDescription` | Lưu ảnh/video |
| `NSLocationWhenInUseUsageDescription` | Gắn GPS vào ảnh |
 
---
 
## 1. Ống kính — phần cốt lõi
 
- [x] Khoá cứng ở `builtInDualWideCamera` — chỉ gồm ống siêu rộng và ống chính
- [x] Ống tele 77mm không nằm trong thiết bị ảo, nên không thể bị kích hoạt
- [x] Tự rơi về `builtInWideAngleCamera` nếu máy không có cụm dual wide
- [x] Ngoại lệ duy nhất: chế độ quay chậm dùng `builtInWideAngleCamera` — đó là
      ống chính 1×, vẫn không phải tele, xem §14
- [x] Bảng chọn zoom không có mốc 3× — không có đường nào gọi tới tele
- [x] Trần zoom số đặt ở 5× để tránh ảnh nát
- [x] Camera trước dùng ống góc rộng đơn (vốn không có tele)
- [x] Bảng chọn zoom: 0,5× / 1× / 2× (sau), 1× / 2× (chân dung và quay chậm),
      1× (trước)
## 2. Zoom
 
- [x] Nút chọn nhanh, nút đang chọn phóng to và chuyển màu vàng
- [x] Pinch để zoom mượt, nối tiếp đúng mức zoom trước đó
- [x] Dùng `MagnifyGesture` thay `.onTapGesture` để không chồng lên cử chỉ
      chạm lấy nét bên trong `CameraPreview`
- [x] Tự kẹp trong khoảng min/max mà thiết bị hỗ trợ
- [x] Quy đổi giữa mức hiển thị và `videoZoomFactor` thô theo
      `virtualDeviceSwitchOverVideoZoomFactors`
## 3. Lấy nét & phơi sáng
 
- [x] Chạm để lấy nét + đo sáng tại điểm chạm
- [x] Ô vàng hiện tại điểm chạm, nảy 1,35× rồi co về 1× (lò xo, kiểu iOS),
      tự ẩn sau 3,5 giây
- [x] Giữ lâu 0,6 giây để khoá AE/AF, kèm phản hồi rung
- [x] Huy hiệu "AE/AF LOCK" ở thanh trên, bấm vào để mở khoá
- [x] Chỉnh EV (−2 đến +2) bằng vuốt dọc một ngón trên preview khi ô vàng đang
      hiện; icon mặt trời chạy trên đường ray cạnh ô, bám 1:1 theo ngón tay và
      hiện số khi lệch khỏi 0. Không còn thanh trượt EV ngang ở đáy màn hình
- [x] Đang vuốt thì ô vàng đứng yên, chỉ đếm 3,5 giây sau khi nhấc ngón tay ra
- [x] Lia máy sang cảnh mới (`subjectAreaDidChangeNotification`): ô vàng mờ dần
      rồi biến mất, camera trở lại Continuous AF/AE và EV về 0
- [x] Đang khoá AE/AF thì lia máy không làm mất khoá
- [x] Chạm điểm mới trả EV về 0, như Camera gốc
- [x] Reset EV và mở khoá khi đổi camera trước/sau
## 4. Năm chế độ
 
Thanh cuộn ngang: **TUA NHANH · QUAY CHẬM · VIDEO · ẢNH · CHÂN DUNG**
 
- [x] Cuộn tự canh giữa chế độ đang chọn
- [x] Chế độ đang chọn màu vàng
- [x] Khoá không cho đổi chế độ khi đang quay hoặc đang xuất file
- [x] Ba chế độ ghi hình (video / quay chậm / tua nhanh) dùng nút chụp
      kiểu bật-tắt; hai chế độ ảnh dùng kiểu bấm-nhả
## 5. Chụp ảnh
 
- [x] Chụp HEIF (HEVC), tự rơi về mặc định nếu máy không hỗ trợ
- [x] `photoQualityPrioritization = .quality` — đường để iOS tự áp
      Deep Fusion và Smart HDR cho app bên thứ ba
- [x] Chụp ở `maxPhotoDimensions` của format hiện tại, đọc lại sau mỗi
      lần đổi `activeFormat`
- [x] Khoá hướng ảnh về dọc (`videoRotationAngle = 90`)
- [x] Lật gương đúng khi dùng camera trước
- [x] Hiệu ứng nút chụp co lại khi bấm
- [x] `PendingCapture` gom các mảnh của một lần bấm máy (ảnh đã xử lý +
      RAW + đoạn phim Live Photo) rồi mới lưu một lần
## 6. ProRAW
 
- [x] Bật `isAppleProRAWEnabled` khi máy hỗ trợ
- [x] Chụp DNG kèm một bản HEIF để xem nhanh
- [x] Lưu DNG dưới dạng `alternatePhoto` → thành một asset ProRAW đúng chuẩn
- [x] Bộ chọn định dạng HEIF / ProRAW chỉ hiện trên máy hỗ trợ
## 7. Live Photo
 
- [x] Bật/tắt bằng nút riêng ở thanh trên và trong bảng cài đặt
- [x] Đoạn phim lưu kèm dưới dạng `pairedVideo`
- [x] Mất phần phim thì vẫn lưu ảnh tĩnh
- [x] Live Photo và `AVCaptureMovieFileOutput` loại trừ nhau — code tráo
      output theo chế độ thay vì giữ cả hai
- [x] `quickTakeAvailable` báo cho UI biết QuickTake tạm nghỉ
## 8. Chân dung
 
- [x] Lấy `AVDepthData` riêng, không nhúng vào file
- [x] `PortraitRenderer` tự dựng xoá phông: quy về disparity, lấy mặt
      phẳng nét ở tâm khung, dựng mask rồi `CIMaskedVariableBlur`
- [x] Thanh trượt cường độ xoá phông 0…1
- [x] Depth chỉ bật ở chế độ này — bật thừa sẽ giới hạn format
> Đây là bản tự dựng, không phải chế độ Chân dung của Apple. Apple còn
> dùng phân đoạn người bằng mạng neural để bắt tóc và viền tay; ở đây chỉ
> có depth map nên viền mềm hơn và đôi khi ăn lẹm.
 
## 9. Macro
 
- [x] Chỉ bật trên máy có ống siêu rộng, camera sau, chế độ Ảnh
- [x] Bật macro = ép về 0,5× + `autoFocusRangeRestriction = .near`
- [x] Zoom vượt 0,6× thì macro tự tắt
## 10. Chụp liên tiếp (burst)
 
- [x] Kéo nút chụp sang trái để bắt đầu
- [x] Chụp liên tục cách nhau 220ms cho tới khi thả tay
- [x] Đếm số ảnh đã chụp hiển thị giữa khung hình
- [x] Burst dùng `.speed` thay vì `.quality` để bắt kịp nhịp
## 11. Hẹn giờ
 
- [x] Ba mức: Tắt / 3 giây / 10 giây, bấm icon để xoay vòng
- [x] Đếm ngược số to giữa màn hình, nền mờ
- [x] Rung nhẹ mỗi giây
- [x] Chạm màn hình hoặc bấm lại nút chụp để huỷ
## 12. Quay video
 
- [x] Ba mức chất lượng: 1080p30 / 1080p60 / 4K30
- [x] Ép khung hình/giây nếu format hiện tại hỗ trợ
- [x] Mic chỉ gắn vào session ngay trước khi quay và gỡ ra sau đó
- [x] Audio session chỉ chuyển `.playAndRecord` lúc quay, còn lại `.ambient`
      để không cắt nhạc người dùng đang nghe
- [x] Đồng hồ đếm thời gian quay ở thanh trên kèm chấm đỏ
- [x] Bật ổn định hình (`preferredVideoStabilizationMode = .auto`)
- [x] Ẩn các nút không liên quan khi đang quay
- [x] Đèn pin (torch) thay cho flash ở chế độ quay
## 13. QuickTake
 
- [x] Giữ nút chụp 0,45 giây ở chế độ Ảnh để quay ngay
- [x] Thả tay là dừng và lưu
- [x] Movie output có sẵn trong session nên độ trễ thấp
- [x] Nút chụp đổi hình dạng để phân biệt QuickTake với quay thường
- [x] Tự vô hiệu khi Live Photo đang bật, kèm câu giải thích trong cài đặt
## 14. Quay chậm

- [x] Hai mức: 120 fps / 240 fps, có nút chuyển nhanh trên thanh trên và mục
      chọn trong Cài đặt
- [x] Tự tráo sang ống chính 1× (`builtInWideAngleCamera`) vì thiết bị ảo kép
      (`builtInDualWideCamera`) không khai báo format tốc độ cao — vẫn là ống
      1×, hoàn toàn không đụng tới tele
- [x] Tráo ngược lại về thiết bị kép khi thoát chế độ, để lấy lại góc siêu rộng
      0,5× và macro
- [x] Tự tìm format tốc độ cao, ưu tiên độ phân giải lớn nhất ở mức fps đó
- [x] Tự hạ 240 fps xuống 120 fps khi camera hiện tại không đạt (thường là camera
      trước) và báo nhẹ cho người dùng — chỉ hạ cho lần chạy này, mức đã lưu
      trong Cài đặt giữ nguyên nên lật về camera sau là 240 fps trở lại
- [x] Kẹp fps theo dải thật của format trước khi gán `activeVideoMinFrameDuration`
      — gán ra ngoài dải là AVFoundation ném exception chứ không trả lỗi
- [x] Máy không có format nào từ 120 fps trở lên thì chặn luôn nút quay, không
      để clip tốc độ thường bị kéo giãn thành video giật
- [x] Mốc zoom ở chế độ quay chậm quy về 1× / 2× (không có 0,5× vì đang chạy
      ống 1×)
- [x] `sessionPreset = .inputPriority` để giữ được `activeFormat` đã chọn
- [x] Sau khi quay xong kéo giãn trục thời gian bằng `scaleTimeRange`
      rồi xuất lại — nếu không video sẽ phát ở tốc độ thường
- [x] Hệ số kéo giãn lấy theo fps THẬT đã quay, không theo mức đã chọn, để clip
      quay ở mức bị hạ không ra sai tốc độ gấp đôi
- [x] Bỏ âm thanh (tiếng kéo chậm 8 lần chỉ còn là tiếng rền)
- [x] Lớp phủ "Đang xuất video…" trong lúc xử lý
- [x] Khôi phục format gốc khi thoát chế độ (chỉ cần cho camera trước — camera
      sau đổi hẳn device nên `activeFormat` của thiết bị kép không bị bẩn)
- [x] Đèn pin, EV và khoá AE/AF được đặt lại sau khi tráo device, vì các trạng
      thái đó gắn với từng `AVCaptureDevice`
- [x] Các cờ năng lực Live Photo / depth / ProRAW KHÔNG đọc lại lúc tráo device:
      `movieOutput` đang nằm trong session sẽ che mất chúng
## 15. Tua nhanh (time-lapse)
 
- [x] Ba nhịp: 0,5s / 1s / 3s
- [x] Chụp ảnh tĩnh theo chu kỳ rồi ghép, tốn ít bộ nhớ hơn quay dài rồi tua
- [x] `TimeLapseRecorder` ghi từng khung ra đĩa, quay dài bao lâu cũng được
- [x] Ghép thành video H.264 30fps bằng `AVAssetWriter`
- [x] Ép kích thước về số chẵn, nếu không encoder từ chối
- [x] Đếm số khung hiển thị giữa khung hình
- [x] Dưới 2 khung thì báo "quá ít khung hình" thay vì tạo file hỏng
## 16. Quét mã QR / mã vạch
 
- [x] Nhận QR, EAN-13, EAN-8, Code128, PDF417, DataMatrix
- [x] Banner trượt xuống từ thanh trên, hiện loại mã và nội dung
- [x] Mã là URL / mailto / tel → nút "Mở"; còn lại → nút sao chép
- [x] Rung nhẹ khi bắt được mã mới
- [x] Tự nghỉ khi đang quay, bật/tắt được trong cài đặt
## 17. Khung hình & hỗ trợ bố cục
 
- [x] Ba tỉ lệ: 4:3 / 16:9 / 1:1, đổi có hiệu ứng
- [x] Chế độ quay luôn dùng khung 16:9 bất kể tỉ lệ đang chọn
- [x] Khung preview khoá đúng tỉ lệ file sẽ ghi ra (`CameraManager.outputAspectRatio`):
      4:3 → khung 3:4, 16:9 và mọi chế độ quay → khung 9:16, 1:1 → khung vuông.
      Preview vẫn là lớp nền dưới cùng; `aspectRatio(.fit)` canh giữa nên hở viền
      đen trên/dưới, khung nào dài thì tràn xuống dưới cụm nút. Đổi tỉ lệ hoặc
      đổi chế độ thì khung co giãn theo trong 0,25 giây
- [x] Live Photo / ProRAW đang bật thì khung preview đứng ở 4:3 cho khớp file
      (ảnh không cắt được), kèm dòng nhắc trong Cài đặt
- [x] 4:3 lưu nguyên file gốc, giữ đủ metadata
- [x] 16:9 và 1:1 cắt canh giữa rồi lưu JPEG 95% — chỉ khi chụp thường,
      vì cắt sẽ phá cặp Live Photo và không áp được cho RAW
- [x] Lưới 3×3 bật/tắt
- [x] Thước thăng bằng chuẩn iOS 17 (1 thanh 3 đoạn, dài 180pt, chuyển vàng và tự ẩn sau khi cân bằng)
## 18. Camera trước
 
- [x] Nút đổi camera trước/sau
- [x] Lật gương đúng cho cả ảnh lẫn video
- [x] Tự tắt đèn khi đổi camera
- [x] Khoá không cho đổi khi đang quay hoặc đang xuất file
## 19. Đèn
 
- [x] Flash ba chế độ cho ảnh: tự động → bật → tắt
- [x] Đèn pin bật/tắt cho video
- [x] Icon và màu đổi theo trạng thái
## 20. Lưu trữ
 
- [x] Lưu thẳng vào thư viện Ảnh của máy
- [x] Gắn toạ độ GPS vào cả ảnh và video
- [x] Thumbnail ảnh/video vừa chụp ở góc dưới trái
- [x] Thumbnail video lấy từ khung hình đầu tiên
- [x] Bấm thumbnail để mở app Ảnh
- [x] Tự xoá file tạm sau khi lưu xong
## 21. Điều khiển & hệ thống
 
- [x] Phím âm lượng làm nút chụp, kèm `MPVolumeView` ẩn chặn HUD
- [x] Sau mỗi lần bấm kéo âm lượng về giữa dải — nếu để chạm 0 hoặc max
      thì bấm tiếp không sinh thay đổi và phím chết
- [x] Dùng category `.ambient`, không dùng `.playAndRecord`, để không
      giữ mic suốt thời gian mở app
- [x] Xin quyền camera, mic, thư viện ảnh, vị trí khi khởi động
- [x] Session chạy trên hàng đợi riêng, không chặn giao diện
- [x] Theo dõi `scenePhase` — `onDisappear` không chạy khi app vào nền
- [x] Đang quay mà app vào nền: dừng ghi, đợi file ghi xong rồi mới tắt session
- [x] Session chỉ dựng một lần, quay lại từ nền chỉ `startRunning`
- [x] Xử lý gián đoạn: cuộc gọi đến, app khác chiếm camera/mic, chia đôi
      màn hình — hiện toast và tự chạy lại khi hết gián đoạn
- [x] Tự khởi động lại khi `mediaServicesWereReset`
- [x] Báo lỗi bằng alert; thông báo nhẹ bằng toast tự tắt sau 3 giây
## 22. Ghi nhớ cài đặt
 
Lưu qua `UserDefaults`, khôi phục khi mở lại app:
 
- [x] Chế độ đang dùng · Chế độ flash · Tỉ lệ khung hình
- [x] Lưới · Thước thăng bằng · Mức hẹn giờ
- [x] Chất lượng video · Mức quay chậm · Nhịp tua nhanh
- [x] Định dạng ảnh (HEIF/ProRAW) · Live Photo · Macro
- [x] Quét mã · Cường độ xoá phông
## 23. Giao diện
 
- [x] Preview là lớp nền dưới cùng, khung khoá theo tỉ lệ file sẽ ghi (viền đen
      trên/dưới), nháy trắng khi bấm máy phủ cả màn hình, ẩn thanh trạng thái
- [x] Ép chế độ tối
- [x] Bảng cài đặt dạng sheet nửa màn hình
- [x] Huy hiệu xác nhận "Ống tele 77mm đã bị vô hiệu hoá" trong cài đặt
---
 
## Cần làm tiếp
 
### A. Sửa lỗi — ưu tiên cao
 
| Việc | Chi tiết |
|---|---|
| Chân dung nhiều khả năng không chạy | `applyMode` không gỡ `movieOutput` ở chế độ `.portrait`, mà movie output làm `isDepthDataDeliverySupported` trả về false → nhánh bật depth bị bỏ qua im lặng, ảnh ra y hệt ảnh thường. Phải tráo output giống cách đang làm với Live Photo |
| Lật camera không áp lại chế độ | `flipCamera` không gọi `applyMode`, nên preset/format/Live Photo/depth giữ nguyên của camera cũ |
| Khả năng máy không cập nhật khi lật | `supportsDepth`, `supportsMacro`, `supportsLivePhoto`, `supportsProRAW` vẫn là giá trị đọc từ camera sau |
| Dòng thừa trong `flipCamera` | `defaultFormat = goingFront ? newFormat : newFormat` — hai nhánh giống hệt nhau |
| Thu âm đang là mono | Tài liệu cũ ghi "stereo" nhưng code không set `multichannelAudioMode = .stereo` trên `AVCaptureDeviceInput` |
| Câu giải thích Live Photo trong cài đặt | Nói "iOS không cho" là không đúng — đây là giới hạn của `AVCaptureMovieFileOutput`, không phải của iOS |
| Đồng hồ quay trôi | Cộng dồn `+= 0.1` mỗi tick Timer, sai dần khi quay lâu. Nên lấy hiệu thời gian thật |
| Quét mã nuốt mất `metadataObjects` khác | Chỉ đọc phần tử `.first`, nhiều mã trong khung sẽ bỏ sót |
 
### B. Chức năng còn thiếu so với Camera gốc
 
| Việc | Ghi chú |
|---|---|
| Live Photo + QuickTake cùng lúc | Bỏ `AVCaptureMovieFileOutput`, chuyển sang `AVCaptureVideoDataOutput` + `AVAssetWriter`. Đây cũng là cách gốc làm |
| Giữ depth trong file chân dung | Lưu HEIC kèm depth aux thay vì nung mờ cứng vào JPEG, để app Ảnh chỉnh lại khẩu độ sau |
| Cắt tỉ lệ không mất metadata | Hiện đi qua `UIImage` nên rụng hết EXIF và tụt xuống JPEG. Nên cắt trên `CGImageDestination` và giữ HEIF |
| 4K60 và 4K24 | 13 Pro có, bảng `VideoQuality` chưa liệt kê |
| Chụp ảnh trong lúc quay video | Thêm `AVCapturePhotoOutput` vào cùng session lúc quay |
| Hiệu ứng chớp màn hình lúc chụp | Gốc có, ở đây chỉ có nút co lại |
| Burst nhanh hơn và gom stack | 220ms ≈ 4,5 ảnh/giây, gốc ~10; ảnh cũng chưa gom thành burst |
| Tua nhanh tự giãn nhịp | Gốc giãn nhịp theo độ dài quay nên quay 1 tiếng vẫn ra video ngắn |
| Macro tự chuyển khi lại gần | Gốc tự đổi sang siêu rộng theo khoảng lấy nét |
| Live Text | `VNRecognizeTextRequest` trên khung preview |
| ProRes | `AVCaptureMovieFileOutput` hỗ trợ trên 13 Pro |
| Action mode | Cần iOS 16+ và `isCenterStageEnabled`-tương đương; kiểm tra API trước |
 
### C. Không làm được — Apple không mở API
 
- Photographic Styles
- Night mode (độc quyền app Camera của Apple)
- Portrait Lighting
- Cinematic mode
- Panorama (về lý thuyết tự ghép được, nhưng là một dự án riêng)
---
 
## Cách kiểm chứng tele đã bị vô hiệu hoá
 
1. Mở app, áp tai vào lưng máy.
2. Bấm qua lại giữa 0,5× và 1×, rồi pinch zoom lên 5×.
3. Phải im hoàn toàn, không có tiếng tách tách.
4. Quay thử 10 giây rồi nghe lại — tiếng phải sạch.