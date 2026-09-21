# Kế hoạch giảm trễ màn trập, nhòe khi di chuyển máy và tối ưu lưu ảnh

Ngày kiểm tra: 2026-09-21. Phạm vi: ảnh thường, Live Photo, ProRAW và chân dung. Thiết bị mục tiêu duy nhất: iPhone 13 Pro, iOS 27 theo xác nhận của người dùng. Chỉ phân tích và lập kế hoạch; chưa sửa Swift.

## 0. Plan đã thống nhất — tách phản hồi chụp thành 3 mốc

Cập nhật 2026-09-21: đã triển khai phần code cho ba mốc trong `CameraManager.swift`, `CameraManagerCapture.swift`, `CameraUI.swift`. Phần này thay thế đề xuất chung về hiệu ứng màn trập ở mục 1; các tối ưu capture/lưu khác vẫn là công việc riêng.

**Trạng thái kiểm chứng:** đã thêm 17 XCTest trong `Tests/CaptureFeedbackTests.swift` và target/scheme trong `project.yml`. Kiểm tra parser Swift không thấy lỗi ở capture/UI/test; hai parse gaps có sẵn của `CameraManager.swift` vẫn nằm ở cú pháp closure một dòng của audio helpers. YAML đọc được và `git diff --check` đạt. Windows không có Swift/Xcode/iOS SDK nên chưa chạy XCTest, type-check hoặc test thiết bị. Trên Mac: chạy `xcodegen generate`, chọn scheme `NoTeleCamera`, chạy Test trên iOS Simulator có sẵn; kiểm chứng timing Live/RAW/bracket và chuyển động trên iPhone thật theo mục E trước khi nghiệm thu.

Đã thực hiện: phản hồi nhận thao tác, chỉ báo giữ máy, callback thu nhận ảnh tĩnh/Live, trạng thái lưu theo thứ tự request, chặn thumbnail cũ, chống callback trùng/đến sau abort, đếm burst theo ảnh thu nhận. Delegate cập nhật main bằng `DispatchQueue.main.async` nhất quán để giữ thứ tự enqueue của callback, thay các Task độc lập. Không thay capture quality hoặc mở khóa chụp ở mốc thu nhận. Record phản hồi tách khỏi pending file data và được dọn khi thu nhận, lỗi/hủy, callback cuối hoặc hoàn tất lưu.

**Sửa sau review (2026-09-21):**

- Bỏ `lastThumbnail = nil` ở đầu `capturePhoto`. Nó chạy trước cả guard `session.isRunning` và không đường hỏng nào trả ảnh cũ về, nên mọi cú chụp lỗi đều xoá trắng thumbnail hợp lệ của lần trước. Thứ tự đã do `publishPhotoThumbnail` giữ, phần nhìn đã do huy hiệu `.processing` giữ.
- Thêm `abandonLiveWait(_:)` cho hai đường cứu ảnh — watchdog hết giờ và `didFinishProcessingLivePhotoToMovieFileAt` lỗi. Trước đó cả hai gọi `clearAcquisitionFeedback` nên *nuốt* phản hồi: ảnh tĩnh vẫn vào thư viện mà không có màn trập nào. Giờ là kết thúc chờ đúng nghĩa, có ảnh tĩnh thì màn trập vẫn nổ; không có mảnh nào mới dọn sổ trắng.
- `photoSaveState` tự tắt: `.saved` sau 2s, `.failed` sau 4s, qua cửa duy nhất `setPhotoSaveState(_:)` (huỷ hẹn giờ cũ, kiểm `latestPhotoSequence`). Trước đó huy hiệu tick xanh nằm lại trên nút thư viện tới tận lần chụp sau.
- Nút thư viện: `accessibilityLabel` trả về "Mở thư viện ảnh", trạng thái lưu chuyển sang `accessibilityValue`, huy hiệu con đặt `accessibilityHidden`. Trước đó VoiceOver đọc "Đã lưu ảnh, nút" — mất tên hành động.
- Toast watchdog "Chụp chưa hoàn tất" không bắn ở burst nữa (một loạt 20 tấm hụt mảnh là 20 lần toast).

**Còn treo, chưa sửa:** (a) 6 closure `DispatchQueue.main.async` trong `CameraManagerCapture.swift` mutate state MainActor từ closure `@Sendable` non-isolated — Swift 5 ra warning, Swift 6 là lỗi; nên bọc `MainActor.assumeIsolated`. (b) Overlay "Giữ máy" nhấp nháy ~150ms ở ảnh thường, nên chỉ hiện khi acquisition vượt ~350ms. (c) Chỗ đăng ký pending vẫn dùng `Task { @MainActor in }` — an toàn vì `photoOutput.capturePhoto` nằm trong chính task đó, nhưng là bất biến ngầm.

### Hành vi người dùng nhìn thấy

| Mốc | Điều kiện | Phản hồi UI | Ý nghĩa |
|---|---|---|---|
| 1. Nhận thao tác | Handler chấp nhận yêu cầu chụp hoặc bắt đầu hẹn giờ | Nút chụp phản hồi ngay bằng thay đổi nhẹ kích thước/trạng thái; timer hiện đếm ngược | App đã nhận thao tác; vẫn cần giữ máy |
| 2. Thu nhận xong | Đã nhận callback kết thúc thu nhận phù hợp với request | Phát hiệu ứng màn trập một lần cho ảnh đơn; kết thúc chỉ báo giữ máy | Không cần tiếp tục giữ máy cho lần thu nhận này; ảnh còn có thể đang xử lý/lưu |
| 3. Lưu xong | PhotoKit completion trả `ok == true` | Thumbnail có trạng thái đã lưu; bỏ chỉ báo đang xử lý/lưu | Ảnh đã được lưu vào thư viện |

Thumbnail có thể xuất hiện trước mốc 3 nhưng phải mang trạng thái đang xử lý/lưu. Không chờ Photos completion để phát màn trập. Hiệu ứng mốc 2 không bảo đảm ảnh nét hoặc lưu thành công; lỗi xử lý/lưu sau đó vẫn phải được báo.

### A. Nối từng mốc với luồng hiện tại

1. **Nhận thao tác — `CameraManager.swift`, `CameraUI.swift`:** thống nhất phản hồi cho nút trên màn hình và nút âm lượng tại đường điều phối `shutterTapped()`. Nhánh timer chỉ xác nhận bắt đầu đếm ngược; hủy timer không phát màn trập. Yêu cầu bị từ chối không được báo như đã nhận chụp. Không thêm rung bắt buộc vào thời điểm trước phơi sáng.
2. **Thu nhận xong — `CameraManagerCapture.swift`:** bỏ `shutterFlashTrigger += 1` khỏi đầu `capturePhoto()`. Dùng `didCapturePhotoFor` để đánh dấu ảnh tĩnh đã thu nhận, rồi cập nhật UI trên MainActor. Apple mô tả callback này được gọi khi kết thúc bước phơi sáng; không phải khi encode hoặc lưu hoàn tất. [Tài liệu Apple](https://developer.apple.com/documentation/avfoundation/avcapturephotocapturedelegate/photooutput(_:didcapturephotofor:))
3. **Live Photo:** thêm callback `didFinishRecordingLivePhotoMovieForEventualFileAt`. Chỉ phát mốc 2 khi đã có cả dấu hiệu ảnh tĩnh thu nhận xong và phim Live ngừng ghi. Không đợi `didFinishProcessingLivePhotoToMovieFileAt`, vì đó là bước trả kết quả xử lý phim. Dựa trên cấu hình resolved thực tế; Live bị hệ thống loại ngay từ đầu thì áp dụng policy ảnh tĩnh. Đây là lựa chọn UX để người dùng không di chuyển máy trong đoạn Live còn đang ghi. [Các callback của Apple](https://developer.apple.com/documentation/avfoundation/avcapturephotocapturedelegate)
4. **Lưu xong — `savePhoto()`:** lưu trạng thái theo capture ID: `processing → saving → saved / failed`. Đặt `saving` lúc submit PhotoKit, `saved` chỉ trong completion thành công. Thumbnail được publish trước completion hiện nay phải được gắn đúng ID và trạng thái chờ.

### B. Trạng thái và vòng đời

- Tách trạng thái phản hồi khỏi `isCapturing`, `capturesInFlight` và `PendingCapture.isComplete`. Các biến hiện tại phục vụ điều tiết đầu vào/gom tài nguyên; mốc 2 không tự mở khóa chụp tiếp.
- Tạo request token và thứ tự tăng dần từ lúc chấp nhận chụp, rồi ánh xạ sang `photoSettings.uniqueID` sau khi tạo settings trên sessionQueue. Log/phản hồi mốc 1 nhờ đó liên kết được với mốc 2 và 3, kể cả lỗi trước khi có settings ID.
- Theo dõi riêng `stillAcquired`, `liveRecordingFinished`, cấu hình Live resolved và `feedbackEmitted` theo ID. Dùng một hàm xét điều kiện phát mốc 2 để hai callback có thể đến theo bất kỳ thứ tự nào mà không nháy hai lần.
- Không chỉ giữ trạng thái phản hồi/lưu trong `pendingCaptures`: `finishIfComplete()` hiện xóa pending ngay sau bàn giao lưu. Giữ record cần thiết qua callback UI và Photos completion; dọn sau các trạng thái kết thúc, không giữ record vô hạn.
- Mọi chuyển trạng thái UI trên MainActor. Callback mang ID/request generation; bỏ callback muộn của request đã hủy, không để nó kích hoạt hiệu ứng sau đổi camera hoặc trở lại app. Không giả định các `Task { @MainActor ... }` độc lập luôn chạy đúng thứ tự delegate.
- Job cũ hoàn tất chỉ cập nhật trạng thái của chính nó, không ghi đè thumbnail hoặc trạng thái ảnh mới. Lỗi lưu ảnh cũ vẫn phải được thông báo.
- Watchdog, lỗi capture và session interruption phải kết thúc chỉ báo đang chụp, nhưng không được phát màn trập thành công giả. Nếu chỉ cứu được ảnh tĩnh từ Live/RAW lỗi, hiển thị kết quả suy giảm rõ ràng; timeout không được dùng làm bằng chứng thu nhận xong.

### C. Policy theo chế độ

| Đường chụp | Policy mốc 2 |
|---|---|
| Photo HEIF/JPEG, chân dung, ProRAW | Theo callback thu nhận ảnh tĩnh; không chờ render chân dung, encode hoặc RAW/processed data về đủ |
| Live Photo | Đợi ảnh tĩnh thu nhận xong và movie ngừng ghi; trong khi chờ giữ chỉ báo Live đang chụp |
| EV bracket một nấc hiện tại | Kiểm chứng callback trên thiết bị; phát một lần/request. Nếu mở rộng bracket nhiều nấc, phải bổ sung điều kiện đã thu nhận đủ, không dùng callback khung đầu |
| Timer | Phản hồi bắt đầu đếm ngược ở mốc 1; sau countdown dùng policy của ảnh thực tế |
| Burst | Theo dõi thu nhận theo từng request; UI dùng chỉ báo đang burst và số ảnh đã thu nhận, không xếp hàng animation toàn màn hình gây nháy kéo dài. Không báo có thể di chuyển máy khi chuỗi còn tiếp tục |
| Time-lapse / QuickTake / video | Tách khỏi phản hồi ảnh đơn; không phát hiệu ứng mới cho từng frame nội bộ hoặc thao tác quay |

### D. Thứ tự triển khai

1. Thêm record phản hồi theo ID/token và chuyển trạng thái có thể kiểm thử; nối log hiện tại với request token.
2. Tách phản hồi nút nhận thao tác; chuyển trigger màn trập sang điều kiện thu nhận xong, bao gồm callback Live và xử lý hủy/lỗi.
3. Gắn thumbnail với ID/thứ tự; thêm trạng thái xử lý/lưu/thất bại và nối PhotoKit completion. Bước này chưa yêu cầu tối ưu tạo thumbnail sớm của P1.
4. Rà soát timer, nút âm lượng, burst và các đường gọi capture nội bộ để không phát sai hiệu ứng hoặc đếm sai ảnh.
5. Build bằng Mac/Xcode và kiểm thử trên iPhone 13 Pro. Giữ nguyên policy chất lượng, EV, queue capture và điều kiện mở khóa hiện tại trong thay đổi này để đánh giá riêng tác động UX.

### E. Kiểm chứng và nghiệm thu

- Log cùng ID/token: `inputAccepted`, `captureCall`, `didCapture`, `liveRecordingFinished`, `acquisitionFeedbackPublished`, `thumbnailPublished`, `photosSubmit`, `photosComplete`. Giữ timestamp callback gốc; timestamp publish không đồng nghĩa frame UI đã vẽ.
- Ảnh đơn được nhận: phản hồi nút ngay, không nháy màn hình trước callback thu nhận, hiệu ứng xuất hiện đúng một lần và không đợi encode/Photos. Đo callback → publish riêng để phát hiện nghẽn main.
- Live: thử cả hai thứ tự callback; hiệu ứng không xuất hiện khi movie vẫn ghi. Live bị loại trong resolved settings không gây chờ vô hạn.
- Unit test chuyển trạng thái: callback trùng, callback đảo thứ tự, callback muộn sau abort, RAW + processed không phát hai lần, Photos failure sau mốc 2, job cũ lưu xong sau job mới. Kiểm tra record được dọn và counter không giảm hai lần.
- Thử timer/hủy timer, nút âm lượng, burst, QuickTake, time-lapse, đổi camera, gián đoạn session và watchdog; không có flash thành công giả hoặc chỉ báo bị treo.
- Thử HEIF, Live, ProRAW, chân dung, EV khác 0; cảnh sáng và trong nhà. So sánh giữ yên với di chuyển máy sau hiệu ứng. Báo riêng tỷ lệ nhòe và độ trễ; thay đổi phản hồi không tự rút ngắn phơi sáng hay thời gian queue.
- Khi Photos lỗi, thumbnail không được mang trạng thái đã lưu. Khi callback Photos chậm, không kéo dài chỉ báo cần giữ máy.

### Bằng chứng cho plan này

Graph mức Verify, project `C-Users-conglv-Desktop-Work-NoTeleCamera`, generation `2026-09-21T08:50:45Z`; tìm symbol và trace trực tiếp hai chiều của `capturePhoto()` không còn trang kết quả. Coverage báo metadata thay đổi ở các file đã đọc và parse gaps `CameraManager.swift:576,610`; đã đọc nguồn hiện tại của các đường liên quan và hai vùng gap. Graph chưa thể hiện đầy đủ delegate/closure bất đồng bộ nên đối chiếu nguồn trực tiếp. Chưa build iOS hoặc xác nhận timing trên thiết bị; callback bracket/Live và thứ tự scheduling phải được kiểm chứng khi triển khai.

## 1. Kết luận cập nhật theo triệu chứng thực tế

### Đã thêm log — lượt test tiếp theo

Người dùng xác nhận EV không chỉnh, mới thử trong nhà. Hạ nghi vấn bracket, ưu tiên đo capture latency/exposure/focus khi thiếu sáng. Đã thêm instrumentation và mục **Cài đặt → Chẩn đoán chụp ảnh**; chưa thay capture quality, EV, ZSL hoặc hiệu ứng màn trập. Các câu “chưa sửa Swift” bên dưới mô tả trạng thái của bản phân tích trước khi thêm instrumentation.

Sau khi build/cài bản mới trên iPhone 13 Pro:

1. Mở Cài đặt, bật **Ghi log chụp thử**, đóng Cài đặt. Đặt Photo, HEIF, 4:3, EV 0, timer off, flash off, camera sau 1x. Giữ nguyên Live Photo cho lượt đầu và ghi lại bật/tắt. Chờ preview ổn định khoảng 2 giây.
2. Trong nhà, chụp một vật đứng yên có chữ/chi tiết, cách khoảng 1–2 m. Chụp 6 ảnh theo thứ tự: ảnh 1/3/5 giữ yên thêm khoảng 1 giây; ảnh 2/4/6 di chuyển máy ngay sau bấm như khi gặp lỗi. Đợi khoảng 3 giây giữa các ảnh, không chụp thêm ngoài chuỗi này để dễ ghép số ảnh với ID log.
3. Đợi khoảng 5 giây sau ảnh cuối, vào Cài đặt, tắt ghi log (không bật lại), chọn **Tạo file log → Chia sẻ log**, lưu file về Files và đính kèm vào cuộc trò chuyện. Xuất trước khi đóng/khởi động lại app; log chỉ nằm trong RAM và giữ tối đa khoảng 2000 dòng. File export là snapshot: chụp thêm phải tạo lại. Bật lại ghi log sẽ xóa lượt cũ.
4. Gửi kèm kết quả theo thứ tự (ví dụ 1 nét, 2 nhòe...) và một cặp ảnh gốc nét/nhòe nếu có thể. Log không chứa pixel nên không tự đánh giá được mức nhòe hay chuyển động tay. Có thể làm lượt thứ hai ở nơi sáng hơn, xuất thành file riêng sau khi đã lưu lượt đầu.

Chưa cần test nhiều tổ hợp hoặc chỉnh `.speed`. Sau lượt đầu mới chọn thử nghiệm tiếp theo theo số liệu.

Các event dùng `id` của capture và `t_ms` theo system uptime; một số mốc được ghi lại muộn với timestamp gốc nên khi phân tích cần nhóm theo ID rồi sắp theo `t_ms`. `request` là lúc vào hàm capture, `shutterTapped` là lúc handler nhận thao tác (không phải timestamp touch-down phần cứng). Timer/burst có đường riêng, vì vậy lượt test này tắt timer và không giữ nút chụp.

- `captureCall - request`: thời gian app chuẩn bị/qua queue.
- `willCapture - captureCall`, `didCapture - captureCall`: mốc tiến trình camera; không dùng hiệu hai callback để thay EXIF exposure time.
- `photoMetadata exposure_s/ISO`: thông số ảnh đầu ra; `previewExposure_ms/previewISO` chỉ là snapshot thiết bị trước chụp. `photoTimestamp_s` giữ riêng, chưa trừ với uptime nếu chưa xác minh cùng clock domain.
- `fileDataReady`, `resourcesReady`, `thumbnailPublished`, `photosComplete`: tách xử lý/gom Live/hiện thumbnail/ghi Photos khỏi lúc lấy ảnh. `thumbnailPublished` là lúc publish state, không đo chính xác frame UI đã vẽ.
- `captureState`: EV/bracket được ghi ở request/settings; ZSL, readiness, rotation thay đổi, focus, exposure, nhiệt và Low Power Mode được ghi để đối chiếu. Không đổi cấu hình camera trong logger.

Log tắt mặc định, không tự upload, không có GPS/ảnh. Việc ghi chỉ append chuỗi vào RAM có khóa ngắn; ghi file diễn ra ở task nền khi người dùng xuất. Vẫn có overhead nhỏ của instrumentation cần tính đến. Môi trường hiện tại là Windows, chưa thể build/type-check với iOS SDK hoặc đo trên iPhone.

Người dùng xác nhận: trên iPhone 13 Pro / iOS 27, bấm rồi di chuyển máy ngay làm ảnh nhòe; phải giữ yên khoảng 1 giây hoặc hơn mới chắc chắn. Mục tiêu chính là giảm thời gian phải giữ máy sau cú bấm, không phải thời gian thumbnail xuất hiện hay Photos ghi xong.

Việc lưu ảnh đã được chụp xong không thể làm chuyển động xảy ra sau đó lọt vào ảnh. Cần kiểm tra trễ từ cú bấm đến lấy khung hình, phơi sáng dài, lấy nét và đường xử lý nhiều khung hình. Chưa đủ dữ liệu để khẳng định riêng nguyên nhân nào; khoảng 1 giây người dùng giữ máy không đồng nghĩa exposure time là 1 giây.

Các nghi vấn cần ưu tiên:

- `CameraManagerCapture.swift:90` phát hiệu ứng màn trập ngay khi nhận cú bấm, trước cả khi đi qua các queue để gọi capture. Hiệu ứng này chỉ xác nhận cú bấm, chưa xác nhận ảnh đã lấy xong; có thể khiến người dùng di chuyển máy sớm.
- `CameraManagerCapture.swift:127` dùng bracket khi EV khác 0 và output cho phép. Apple xác nhận bracket không dùng Zero Shutter Lag. Đây là nghi vấn mạnh nếu người dùng có chỉnh EV, kể cả khi cờ ZSL trên output vẫn bật. Cần thử EV 0 đối chứng. [Apple WWDC23](https://developer.apple.com/videos/play/wwdc2023/10105/)
- Khi EV 0, vẫn phải đo thời gian chờ queue và kiểm tra ZSL/capture readiness thực tế, flash, exposure duration/ISO và lấy nét. Không suy luận từ việc helper đã bật cờ rằng mọi lần chụp đều hưởng ZSL.
- Đo ảnh hưởng cập nhật rotation/mirroring ngay trước capture; chưa có bằng chứng runtime rằng thao tác này gây trễ trong lần chụp được báo cáo.

### Thứ tự ưu tiên mới — thay thế thứ tự P0–P5 phía dưới

1. **Đo thời điểm lấy ảnh:** ghi tap → gọi capture → `willCapturePhotoFor` → `didCapturePhotoFor` → callback xử lý. Kèm timestamp ảnh, EXIF ExposureTime/ISO, trạng thái focus/exposure, EV, bracket, flash và ZSL. Callback là mốc tiến trình, không dùng khoảng cách hai callback như phép đo chính xác thời gian phơi sáng. Apple mô tả `willCapturePhotoFor` gần thời điểm bắt đầu chụp trong [tài liệu delegate](https://developer.apple.com/documentation/avfoundation/avcapturephotocapturedelegate/photooutput(_:willcapturephotofor:)).
2. **Đối chứng có kiểm soát:** Photo HEIF 4:3, EV 0, flash off, Live off, ánh sáng tốt; so với cùng cảnh ở Camera mặc định. Sau đó lần lượt bật Live, chỉnh EV, thử ánh sáng yếu và balanced/speed. Dùng cùng cách di chuyển máy sau cú bấm; chụp nhiều lần ở các mốc 0/100/250/500/1000 ms nếu có cách đo đáng tin cậy, ghi tỷ lệ ảnh nét. Kiểm tra ảnh tĩnh đã lưu, không nhầm với khung hình khi Live Photo đang phát.
3. **Nếu bracket gây trễ:** thiết kế lại policy EV cho chế độ chụp nhanh, thử capture thường với exposure bias. Phải kiểm tra giữ được độ sáng mong muốn; không bỏ cơ chế EV hiện tại một cách âm thầm. `.speed` không khôi phục ZSL cho bracket.
4. **Nếu tap → capture chậm:** giảm công việc và các lượt đổi queue trên đường màn trập, vẫn đăng ký pending trước capture và giữ đúng quyền sở hữu session. Tránh tái cấu hình không cần thiết sát cú bấm; kiểm chứng ZSL/readiness sau mỗi mode/camera.
5. **Nếu exposure dài hoặc focus chưa ổn định:** đo trong điều kiện ánh sáng tương ứng và thử quality policy. Chỉ cân nhắc giới hạn shutter/đẩy ISO khi có bằng chứng cần thiết: có đánh đổi nhiễu/độ sáng, và manual exposure có thể mất ZSL. Không áp một ngưỡng shutter cố định mặc định cho mọi cảnh.
6. **Sửa phản hồi màn trập:** tách phản hồi nhận thao tác khỏi tiến trình lấy ảnh thật, dùng callback phù hợp; không coi thumbnail hay Photos completion là tín hiệu cần giữ yên. Sửa UI không tự chữa nguyên nhân ảnh nhòe.
7. **Sau khi giảm nhòe mới tối ưu lưu:** áp dụng các P1–P5 phía dưới theo số đo. Thumbnail sớm, mở khóa chụp tiếp và deferred delivery không phải bằng chứng camera đã lấy khung hình sớm hơn.

Tiêu chí thành công chính: giảm p95 tap → thời điểm capture và giảm tỷ lệ ảnh nhòe khi di chuyển máy sớm, so với baseline trên cùng iPhone 13 Pro. Thời gian Photos completion là chỉ số thứ cấp. Chưa sửa Swift và chưa có phép đo trên thiết bị.

### Phân tích luồng lưu trước khi làm rõ triệu chứng

Mã nguồn có những bước chờ làm trải nghiệm chụp/lưu chậm, nhưng chưa có phép đo để kết luận PhotoKit hoặc tốc độ ghi bộ nhớ là nguyên nhân chính. Cần phân biệt bốn mốc: ghi nhận cú bấm, hiện thumbnail, sẵn sàng chụp tiếp, và Photos xác nhận lưu thành công. Thumbnail hiện không đồng nghĩa ảnh đã lưu.

Luồng hiện tại:

```text
Bấm chụp → main → sessionQueue → main đăng ký pending → sessionQueue capture
 → AVFoundation xử lý và trả ảnh → fileDataRepresentation
 → chờ đủ HEIF/JPEG + RAW nếu bật + movie nếu bật Live Photo
 → bàn giao savePhoto và mở khóa chụp
 → task nền: render chân dung → crop → tạo thumbnail
 → chờ MainActor cập nhật thumbnail → gọi PhotoKit → callback lưu
```

## 2. Những điểm đã xác nhận từ mã nguồn

| Điểm | Bằng chứng | Tác động và giới hạn kết luận |
|---|---|---|
| Live Photo bật mặc định | `CaptureTypes.swift:147`; giá trị đã lưu được nạp lại ở dòng 175 | Cài đặt thực tế trên điện thoại có thể khác mặc định. |
| Chờ đủ movie/RAW mới bàn giao lưu và mở khóa chụp | `PendingCapture.isComplete`, `CameraManagerCapture.swift:43`; `finishIfComplete`, dòng 291 | Nếu ảnh tĩnh về trước movie, app vẫn chưa hiện thumbnail và chưa cho chụp thường tiếp. Đây là phụ thuộc chắc chắn, thời gian chờ cần đo. |
| Chụp thường bị tuần tự hóa | `capturePhoto`, dòng 67; `endCapture`, dòng 266 | `isCapturing` chặn cú bấm kế tiếp cho đến khi gom đủ dữ liệu. Burst có đường riêng. Bật responsive capture ở output chưa loại bỏ giới hạn này. |
| Thumbnail xuất hiện muộn trong chuỗi xử lý | `savePhoto`, dòng 321–388 | Chờ render/crop và gom tài nguyên trước khi tạo thumbnail. Sau đó còn `await MainActor.run` rồi mới gửi Photos. |
| Nâng trần kích thước và dùng trần đó cho từng ảnh | `CameraManager.swift:479`, `:881`; `CameraManagerCapture.swift:181` | Chọn phần tử cuối của danh sách kích thước, không có preset độ phân giải phục vụ tốc độ. iPhone 13 Pro có camera 12MP: loại giả thuyết chụp 48MP khỏi chẩn đoán cho máy này. Vẫn log kích thước resolved và file thực tế. |
| Crop cần tạo ảnh và encode lại | `MediaProcessing.swift:88` | 16:9/1:1 khi được phép crop có thêm công việc trước lưu. Nhánh 4:3 thường không đi qua bước này. |
| Chân dung render full-frame rồi encode JPEG | `PortraitRenderer.render`, `CameraManagerCapture.swift:512`; cuối hàm dòng 571–572 | Khi còn crop tiếp, có thể decode/encode thêm lần nữa. Là ứng viên nghẽn CPU/GPU riêng của chân dung. |
| Mỗi lần lưu tạo một task `.utility` | `CameraManagerCapture.swift:333` | Công việc đã ở nền. Khi chụp nhiều, các job có thể tranh tài nguyên; số capture giới hạn không đồng nghĩa số save job được giới hạn. Tác động QoS cần đo A/B. |
| Watchdog chờ 8 giây, có nhánh đặt lại 2 giây | `CameraManagerCapture.swift:244`, `:491` | Chỉ là nhánh cứu hộ khi thiếu kết quả, không phải delay cố định ở mọi lần chụp. Nếu chậm thành từng đợt vài giây, log nhánh này. |
| EV khác 0 có thể chuyển sang bracket | `CameraManagerCapture.swift:128` | Đây là một đường chụp khác, cần benchmark riêng; không thay đổi cơ chế EV chỉ để lấy tốc độ mà chưa kiểm tra ảnh. |

App đã có `tuneForLowLatency` tại `CameraManager.swift:413`, bật ZSL, responsive capture và fast capture prioritization theo capability. Không nên lập kế hoạch chỉ bằng cách bật lại ba cờ này. `finishIfComplete` cũng đã mở khóa trước khi PhotoKit hoàn tất; chờ ghi thư viện không phải điều kiện mở khóa hiện tại.

iPhone 13 Pro dùng hệ camera 12MP theo [thông số Apple](https://support.apple.com/pt-br/111871). Vì vậy không ưu tiên hạ độ phân giải; giữ 12MP và tối ưu các bước chờ trước. Capability của từng tổ hợp camera/Live/depth vẫn cần đọc trên iOS 27 thực tế.

## 3. So với Camera mặc định

Apple trình bày việc chụp chồng lấp, theo dõi readiness và xử lý ảnh trì hoãn để cải thiện phản hồi. Hiện ảnh nhanh trên giao diện không chứng minh mọi xử lý và lưu ảnh cuối đã xong. Deferred delivery có thể trả proxy để đưa vào Photos, nhưng không đồng nghĩa ảnh cuối sẵn sàng chia sẻ ngay. Xem [WWDC23: Create a more responsive camera experience](https://developer.apple.com/videos/play/wwdc2023/10105/).

Không có benchmark cùng điện thoại/cảnh/cấu hình nên chưa thể xác định khoảng cách với Camera mặc định. Không coi những nhận xét trong comment về Night mode, Deep Fusion hay số giây chờ là kết quả đo hoặc bảo đảm của API.

## 4. Kế hoạch theo thứ tự triển khai

### P0 — Đo đúng trước khi thay đổi hành vi

Thêm signpost theo `uniqueID` của capture, dùng đồng hồ monotonic:

- Cú bấm được nhận hoặc bị từ chối và lý do; thời điểm gọi API capture.
- `willBeginCapture`, callback ảnh, thời gian riêng của `fileDataRepresentation`, callback RAW/movie, callback kết thúc capture.
- Thời điểm đủ tài nguyên, job vào queue/bắt đầu chạy; thời gian render, crop, thumbnail.
- Thumbnail được hiển thị, readiness cho phép chụp tiếp, PhotoKit bắt đầu và completion thành công/thất bại.
- Watchdog, fallback encode, số capture và số save job đang tồn tại.

Log cấu hình thực tế: model/iOS, camera/format, dimensions yêu cầu và resolved, số byte, Live/RAW/depth/bracket, quality, capability và enabled flags sau cấu hình, nhiệt độ hệ thống và Low Power Mode. Không cần log dữ liệu ảnh hay GPS.

Kết quả: bảng p50/p95 từng giai đoạn. Nếu phần chậm nằm trước callback ảnh, ưu tiên capture; nếu nằm ở render/crop, ưu tiên xử lý; nếu nằm trong PhotoKit completion, ưu tiên thử nghiệm đường nhập tài nguyên và kiểm tra trạng thái thiết bị.

### P1 — Rút ngắn đường đến thumbnail và Photos

Phạm vi: `CameraManagerCapture.swift`, `CameraUI.swift`, `MediaProcessing.swift`.

1. Tạo thumbnail sớm từ ảnh tĩnh/preview của chính capture vừa trả về, không đợi movie Live Photo hoặc RAW. Với chân dung/crop, preview tạm phải phản ánh trạng thái đang xử lý và được thay bằng kết quả cuối.
2. Đưa việc tạo/cập nhật thumbnail ra khỏi điều kiện để submit PhotoKit. Không để `await MainActor.run` trì hoãn việc bắt đầu lưu.
3. Giữ đường 4:3 HEIF/JPEG thường truyền nguyên `Data` sang PhotoKit khi không cần biến đổi.
4. Theo dõi riêng `saving/saved/failed`. Chỉ báo lưu thành công khi PhotoKit completion thành công; không lấy thumbnail làm bằng chứng.
5. Gắn thứ tự capture cho thumbnail để một job cũ hoàn thành muộn không ghi đè ảnh mới.

Tác dụng: giảm chờ do app tạo ra và cải thiện phản hồi mà không phải hạ chất lượng ảnh. Live Photo vẫn phải đủ cặp ảnh/movie để lưu đúng một asset.

### P2 — Cho chụp tiếp theo khả năng thật của camera

Phạm vi: `CameraManager.swift`, `CameraManagerCapture.swift`, UI liên quan.

1. Tách trạng thái camera sẵn sàng, capture đang xử lý và job đang lưu.
2. Tích hợp `AVCapturePhotoOutputReadinessCoordinator` để quyết định nhận cú bấm, giữ các cổng chặn khi session đang thay đổi.
3. Cho các capture chồng lấp khi hỗ trợ; giữ giới hạn hữu hạn theo readiness và áp lực bộ nhớ, không đơn thuần xóa guard `isCapturing`.
4. Quản lý mỗi request đến đúng vòng đời cuối; xử lý callback xen kẽ, lỗi, timeout, đổi mode/camera mà không giảm counter hai lần hoặc mất dữ liệu. Snapshot aspect/intensity/location và policy ngay khi nhận cú bấm, thay vì đọc settings muộn trong save.
5. Đo rồi mới giảm các lần qua lại main/sessionQueue, vẫn bảo đảm pending tồn tại trước capture và mọi cấu hình output được đọc tại queue sở hữu.

Tác dụng chính: khoảng cách giữa hai lần chụp; không tự làm PhotoKit ghi từng ảnh nhanh hơn.

### P3 — Preset tốc độ có đánh đổi rõ ràng

Đề xuất tùy chọn “Nhanh”: HEIF, 4:3, giữ 12MP theo active format hỗ trợ của iPhone 13 Pro, Live Photo/RAW tắt, thử `.speed` so với `.balanced`. Đây là đề xuất để người dùng chọn, không tự đổi các cài đặt đã lưu.

Chọn dimensions từ danh sách hỗ trợ; không hard-code một kích thước trên mọi camera. Giữ cấu hình output ổn định và chọn dimensions hợp lệ trên mỗi request khi có thể. Apple lưu ý thay đổi output dimensions có thể tái cấu hình lâu; ảnh đầu ra cũng có thể nhỏ hơn trần yêu cầu. Xem [output maxPhotoDimensions](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/maxphotodimensions) và [settings maxPhotoDimensions](https://developer.apple.com/documentation/avfoundation/avcapturephotosettings/maxphotodimensions).

Đo độ nét, nhiễu, chi tiết vùng sáng/tối và EV cùng tốc độ; `.speed` là đánh đổi chất lượng. Kiểm tra lại capability sau đổi mode/camera. Giữ yêu cầu không chọn ống tele.

### P4 — Deferred delivery cho luồng tương thích

Thử trước trên ảnh thường không crop/filter. Kiểm tra `isAutoDeferredPhotoDeliverySupported`, cấu hình `isAutoDeferredPhotoDeliveryEnabled` trước khi chạy session theo [tài liệu Apple](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isautodeferredphotodeliveryenabled).

Implement callback `didFinishCapturingDeferredPhotoProxy`, lưu dữ liệu proxy nguyên bản bằng resource `.photoProxy`; vẫn xử lý ảnh thường vì không phải lần chụp nào cũng trả proxy. Sửa điều kiện hoàn tất, watchdog và tài nguyên đi kèm để hiểu cả hai dạng kết quả. Kiểm tra tên API/signature bằng SDK đang dùng khi triển khai.

Không chuyển proxy qua hàm crop/portrait hiện tại. Nếu cần chỉnh ảnh cuối, thiết kế PhotoKit adjustments riêng và kiểm tra quyền đọc tương ứng. Đây là hướng giảm thời gian chờ ảnh xử lý xong; không dùng để hứa ảnh cuối có ngay. Quy trình được Apple mô tả trong [WWDC23](https://developer.apple.com/videos/play/wwdc2023/10105/).

### P5 — Giảm công việc xử lý và bảo đảm lưu khi rời app

1. Với chân dung + crop, ghép biến đổi vào một pipeline rồi encode một lần; tái sử dụng CIContext đã có. Kiểm chứng orientation, metadata, màu và HDR/gain map khi xuất lại.
2. Dùng hàng đợi lưu có giới hạn và điều tiết đầu vào theo tổng bộ nhớ/công việc; thử 1–2 job xử lý nặng đồng thời rồi chọn bằng p95 và memory peak. Không tạo số task nặng không giới hạn.
3. Đo A/B `.userInitiated` cho phần ảnh người dùng đang đợi với `.utility`; không nâng ưu tiên toàn bộ task mặc định.
4. Thử resource dạng Data so với fileURL chỉ khi profiling chỉ ra bộ nhớ/copy hoặc import là nghẽn. File tạm thêm một lần ghi nên chưa chắc nhanh hơn.
5. Bảo vệ thời gian bàn giao Photos khi app vào nền, xử lý expiration và cleanup. Nếu cần sống qua force quit/crash, có spool bền vững và cơ chế retry tránh asset trùng; background task đơn thuần không bảo đảm điều đó.

## 5. Kiểm chứng và tiêu chí nghiệm thu

Trên iPhone thật, build Release, cùng cảnh/ánh sáng và cùng các thiết lập so sánh được với Camera mặc định. Mỗi cấu hình 30 ảnh, tách ảnh đầu sau mở app/đổi mode khỏi các ảnh khi session đã ổn định:

| Nhóm | Cấu hình |
|---|---|
| Baseline | Photo, HEIF, 4:3, EV 0, flash off; Live bật/tắt |
| Độ phân giải và quality | Xác nhận ảnh 12MP; so sánh balanced/speed, không có thử nghiệm 48MP |
| Xử lý phụ | 16:9, 1:1, chân dung; RAW nếu hỗ trợ |
| Khác đường capture | EV khác 0/bracket, flash, camera trước, đổi mode rồi quay về Photo |
| Áp lực | Bấm nhanh 10–20 lần, vào nền ngay sau chụp, máy nóng/Low Power Mode, lưu lỗi |

Nghiệm thu: p50/p95 cho thumbnail, sẵn sàng chụp tiếp và Photos completion được báo riêng; không bỏ cú bấm âm thầm, không mất/trùng asset, thumbnail không đảo thứ tự, không hỏng cặp Live/RAW, không tụt chất lượng ngoài đánh đổi đã chọn. Memory peak không tăng theo số ảnh vô hạn. Với deferred, phân biệt thời gian proxy được nhập và ảnh cuối sẵn sàng.

Mục tiêu ban đầu có thể đặt p95 phần app từ lúc có dữ liệu ảnh đến submit Photos dưới 100 ms cho HEIF 4:3 không chỉnh sửa khi queue rỗng. Đây là ngân sách cần đo và điều chỉnh, không phải kết quả hiện có; không áp cho capture/Live/movie hoặc toàn bộ PhotoKit.

Thứ tự khuyến nghị: P0 → P1 → P2 → P3, sau đó P4/P5 theo số đo. P0 cần Mac/Xcode/Instruments và iPhone; môi trường Windows hiện tại chỉ cho phép kiểm tra tĩnh.

## 6. Giới hạn bằng chứng

Đã dùng graph ở mức Verify với project `C-Users-conglv-Desktop-Work-NoTeleCamera`, generation `2026-09-21T08:39:15Z`. Coverage báo metadata thay đổi và hai parse gaps `CameraManager.swift:576,610`; đã đọc nguồn hiện tại cho các đường liên quan và cả hai vùng này. Graph trace không thể hiện đầy đủ delegate/closure bất đồng bộ nên kết luận luồng dựa thêm vào nguồn trực tiếp. Đã biết model iPhone 13 Pro và iOS 27 từ người dùng; chưa có trace runtime, build iOS cụ thể hay cài đặt thực tế của lần bị chậm; chưa xếp hạng thời gian tiêu tốn bằng số liệu.
