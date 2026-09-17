# Báo cáo audit NoTeleCamera theo `func_req.md`

## Kết luận nhanh

Audit tĩnh cho thấy mục tiêu quan trọng nhất — **không bao giờ chọn ống tele 77 mm** — được triển khai đúng về mặt cấu trúc thiết bị: camera sau dùng `builtInDualWideCamera`, quay chậm dùng `builtInWideAngleCamera`, không có đường chọn `builtInTripleCamera` hoặc `builtInTelephotoCamera`.

Trong 24 nhóm yêu cầu:

- **Đạt:** 0, 4, 6, 9, 11, 18, 22.
- **Cơ bản đạt nhưng có lỗi/edge case:** 1, 2, 3, 5, 7, 8, 10, 12, 13, 14, 15, 16, 17, 19, 20, 21, 23.

- **Không có mục nào hoàn toàn chưa được triển khai.** Tuy nhiên một số lỗi ở time-lapse, chuyển mode/camera, audio session và lifecycle đủ nghiêm trọng để cần sửa trước khi coi app ổn định trên máy thật.

*(19 và 23 trước đây được đánh ✅ dù phần mô tả đã ghi rõ sai lệch — torch tái bật khi tráo device slo-mo, và sheet kéo được lên `.large` trong khi spec nói nửa màn hình. Đã hạ xuống ⚠️ cho nhất quán.)*

Đây là audit source code, không phải xác nhận runtime trên iPhone 13 Pro.

## Đánh giá từng mục

| Mục | Trạng thái | Đánh giá code thực tế |
|---|---|---|
| **0. Cấu hình** | ✅ Đạt | `Info.plist` có đủ camera, microphone, Photo Library Add và location. `project.yml` đặt iOS 26.0 và dùng plist thủ công. `DEVELOPMENT_TEAM` đang rỗng nên máy phát triển phải tự chọn team để chạy thật. |
| **1. Ống kính** | ⚠️ Cơ bản đạt | `CameraManager.bestDevice` khóa rear ở Dual Wide, slo-mo ở Wide và front ở Wide; không có API chọn tele/triple. Trần zoom 5× và không có mốc 3×. Lỗi nhỏ: khi fallback sang wide đơn, UI vẫn hiện 0,5× dù thiết bị không đạt được mức đó. Có race khi đổi mode rồi lật camera vì `flipCamera()` có thể giữ `videoInput` cũ. |
| **2. Zoom** | ⚠️ Cơ bản đạt | Pill zoom, `MagnifyGesture`, nối tiếp pinch, clamp min/max và quy đổi theo switch-over factor đều có. Cần làm `zoomStops` theo khả năng device thật. `setZoom` cập nhật UI trước khi lệnh session queue chắc chắn thành công và đọc `self.baseFactor` muộn, có thể lệch state trong lúc đổi device. |
| **3. Focus & EV** | ⚠️ Cơ bản đạt | Tap focus/exposure, ô vàng, long press 0,6 s, AE/AF badge, EV dọc, bracket EV và reset khi flip đều có. Nếu `lockForConfiguration` thất bại, UI vẫn báo lock/EV thành công. Sau khi ô focus tự ẩn, `subjectAreaDidChange()` có thể return sớm nên camera không chắc quay về continuous AF/AE. |
| **4. Năm chế độ** | ✅ Đạt | Đúng thứ tự, canh giữa, màu vàng, swipe một bước, threshold khoảng 60 pt, gesture arbitration và khóa khi recording/processing/burst. Nên bổ sung guard `isBursting` ngay trong `CameraManager.setMode`, không chỉ ở UI. |
| **5. Chụp ảnh** | ⚠️ Cơ bản đạt | HEIF fallback, balanced/speed, max dimensions, mirror, shutter animation và `PendingCapture` đều có. Code dùng `RotationCoordinator` thay vì khóa cứng góc 90° như tài liệu; đây có thể là cải tiến nhưng đặc tả và code đang lệch nhau. `supportedMaxPhotoDimensions.last` giả định phần tử cuối lớn nhất. |
| **6. ProRAW** | ✅ Đạt trên thiết bị đích | Bật ProRAW theo capability, tạo DNG + processed photo và lưu DNG bằng `.alternatePhoto`; UI chỉ hiện picker khi hỗ trợ. Nhánh ProRAW hard-code HEVC mà không kiểm tra codec có khả dụng trong cấu hình RAW hiện tại. |
| **7. Live Photo** | ⚠️ Cơ bản đạt | Output được tráo thật, paired video được lưu và ảnh tĩnh vẫn cứu được khi movie lỗi. `quickTakeAvailable` được publish trước khi session graph commit; nếu `movieOutput` không add được thì UI vẫn có thể báo QuickTake khả dụng. Có truy cập `session.outputs` ngoài `sessionQueue`. |
| **8. Chân dung** | ⚠️ Cơ bản đạt | Có depth riêng, renderer disparity/mask/variable blur, slider và gỡ movie output. Nếu depth không bật hoặc render thất bại, app âm thầm lưu ảnh thường. Slider mức 0 vẫn blur vì radius tối thiểu là 6 và gain tối thiểu là 2. |
| **9. Macro** | ✅ Đạt | Chỉ khả dụng khi rear + Photo + ultra-wide, ép 0,5×, restriction `.near`, tự tắt khi zoom >0,6 hoặc rời Photo/front; UI chỉ còn toggle trong Settings. Cleanup restriction trên device cũ khi flip chưa diễn ra ngay nhưng state cuối thường đúng. |
| **10. Burst** | ⚠️ Gần đạt | Drag trái, chu kỳ 120 ms, backpressure 4 capture và `.speed` đều có. `burstCount` đếm số request đã submit, không phải số ảnh capture/lưu thành công. Burst vẫn lưu từng asset, phù hợp phần “cần làm tiếp”. |
| **11. Hẹn giờ** | ✅ Đạt | Off/3/10, chỉ hiện ở mode ảnh, overlay, haptic mỗi giây và hủy bằng màn hình/shutter đều đúng. |
| **12. Video** | ⚠️ Một phần | Ba quality, fps, stereo, timer thật, stabilization, torch và save video đều có. Sai lệch lớn: mic/audio session được gắn khi **vào mode Video/Slo-mo**, không phải ngay trước khi quay, và được giữ sau video thường. Vì vậy app có thể giữ mic/`playAndRecord` khi chỉ đang ngắm. Nếu attach mic lỗi, `audioAttached` vẫn thành true và không retry. FPS unsupported bị bỏ qua im lặng. UI chuyển `isRecording` trước khi có callback xác nhận recording bắt đầu. |
| **13. QuickTake** | ⚠️ Cơ bản đạt | Hold 0,45 s, release stop, movie output có sẵn, hình shutter riêng và disable khi Live Photo đều có. Gesture `DragGesture` + `LongPressGesture` đồng thời có race ở ngưỡng 0,45 s: tap có thể chụp ảnh trước khi QuickTake state được set. Cùng lỗi attach mic và recording state của mục 12. |
| **14. Slo-mo** | ⚠️ Một phần | Swap sang Wide 1×, chọn format lớn nhất, fallback 240→120, zoom 1/2×, inputPriority, scale time, bỏ audio và overlay export đều có. `CMTime(value: 1, timescale: CMTimeScale(actualFps))` cắt 239,76 thành 239 và 119,88 thành 119; fps cấu hình lệch factor export. Code tái bật torch trên device mới thay vì reset như yêu cầu. Nếu export lỗi, file gốc vẫn bị xóa nên có thể mất footage. |
| **15. Time-lapse** | ⚠️ Một phần, ưu tiên cao | Có interval, ảnh tĩnh theo chu kỳ, ghi frame xuống disk, H.264 30 fps, kích thước chẵn và chặn dưới 2 frame. Khi stop, code export ngay mà không đợi photo captures/append đang bay; callback cũ có thể lọt vào recorder sau snapshot/reset. Không có backpressure nên pending capture có thể tăng. Write JPEG và `adaptor.append` bỏ qua lỗi. Nhánh assemble lỗi không cleanup đầy đủ. |
| **16. QR/barcode** | ⚠️ Cơ bản đạt | Đủ sáu type, duyệt toàn danh sách, haptic, settings, open/copy. `typeLabel` chỉ nói “Mã QR” hoặc “Mã vạch”, chưa hiện chính xác EAN-13/Code128/PDF417… “Tự nghỉ” hiện chỉ bỏ callback; metadata output vẫn xử lý frame. Transition có khai báo nhưng thay state không nằm trong animation nên banner chưa chắc trượt. |
| **17. Khung hình** | ⚠️ Cơ bản đạt | Preview ratio, crop giữa, ImageIO metadata path, grid và level đều tốt. “Single source of truth” chưa đúng hoàn toàn: save path tự suy `raw == nil && liveMovie == nil` thay vì dùng policy chung. ImageIO re-encode không đảm bảo giữ HEIF auxiliary images/gain map; fallback `UIImage` làm rơi metadata và đổi JPEG. |
| **18. Camera trước** | ✅ Đạt | Flip, mirror ảnh/video, tắt torch, capability/default format refresh và gọi lại `applyMode` đều có. Nên cấu hình preview mirroring rõ ràng thay vì dựa vào mặc định của preview layer. |
| **19. Đèn** | ⚠️ Cơ bản đạt | Flash auto/on/off cho ảnh; torch cho mode quay; icon/màu và reset khi flip đúng. Riêng swap device trong slo-mo đang có logic tái bật torch, lệch mục 14. |
| **20. Lưu trữ** | ⚠️ Cơ bản đạt | Lưu Photos, location cho asset, thumbnail ảnh/video và xóa phần lớn temp file. GPS có thể nil/cũ vì không kiểm age/accuracy. Live Photo save failure có thể để lại movie temp; slo-mo export failure có thể để file dở; time-lapse để thư mục rỗng/frame lỗi. `photos-redirect://` là URL scheme không được tài liệu hóa, có rủi ro App Review/tương thích. |
| **21. Điều khiển & hệ thống** | ⚠️ Một phần | Volume shutter, reset volume, session queue, scenePhase, interruption và runtime reset đều có. Audio policy lệch yêu cầu do vào mode Video đã chuyển `playAndRecord`. Có race background→active: callback finalize video cũ vẫn có thể stop session sau khi app active lại. Location update không dừng khi background. Media-services reset chỉ start graph cũ, không có fallback rebuild. |
| **22. Ghi nhớ settings** | ✅ Đạt | Đủ toàn bộ mode/flash/aspect/grid/level/timer/video/slomo/timelapse/format/Live/macro/scan/portrait intensity; load có fallback và mutation paths có save. |
| **23. UI** | ⚠️ Cơ bản đạt | Preview nền, flash toàn màn hình, dark mode, top bar, bottom layout, mode centering, giữ chỗ khi recording, Liquid Glass và glass IDs đều được nối đúng. Sheet cho phép kéo từ medium lên large; nếu yêu cầu bắt buộc chỉ nửa màn hình thì đây là lệch nhỏ. |

## Những phần đã làm tốt

1. **Mục tiêu chống tele được thiết kế đúng từ cấp device**, không dựa vào việc ẩn nút UI. Đây là điểm quan trọng nhất.
2. `PendingCapture` + watchdog xử lý khá chặt thứ tự callback ảnh/RAW/Live Photo và tránh kẹt trạng thái.
3. Logic mode đã chú ý nhiều gotcha AVFoundation: gỡ movie output trước Live/depth, restore format, `inputPriority` cho slo-mo, và đọc lại capability khi flip.
4. Gesture arbitration giữa swipe mode và EV được làm cẩn thận; mode selector và zoom selector có UX tốt.
5. Lifecycle/interruption đã được xử lý tốt hơn nhiều app camera mẫu: scene phase, cuộc gọi, media reset, stop recording trước stop session.
6. Persistence đầy đủ và UI Liquid Glass bám khá sát đặc tả.
7. Time-lapse ghi frame xuống disk thay vì giữ ảnh full-size trong RAM là hướng kiến trúc đúng, dù vòng đời frame còn cần sửa.

## Danh sách nên sửa theo ưu tiên

### P0 — Có thể mất dữ liệu hoặc tạo kết quả sai

1. **Sửa time-lapse stop/export**:
   - Gắn generation/session ID cho từng frame.
   - Ngừng phát request mới, chờ/drain toàn bộ capture + append thuộc generation hiện tại rồi mới snapshot và assemble.
   - Thêm backpressure tương tự burst.
   - Chỉ tăng counter sau khi frame ghi disk thành công.
   - Kiểm kết quả `write` và `adaptor.append`; cleanup trong `defer` cho mọi nhánh lỗi.
2. **Sửa slo-mo duration** bằng `CMTime(seconds: 1.0 / actualFps, preferredTimescale: 60000)` hoặc rational lấy từ frame-rate range; factor export phải dựa trên fps thực sự đã cấu hình.
3. **Không xóa video slo-mo gốc khi export lỗi**; lưu fallback hoặc giữ temp để retry.
4. **Serialize chuyển mode/flip/shutter/zoom**. Không cho flip/capture/QuickTake khi `isModeTransitioning`; trong `flipCamera` lấy input thực từ `session.inputs` trên `sessionQueue`, không capture `videoInput` có thể stale.

### P1 — Privacy, lifecycle và trạng thái session

5. **Đưa mic/audio session về đúng yêu cầu**: chỉ attach ngay trước recording, detach sau recording. *(Đã chốt — xem D2 trong `REMEDIATION_PLAN.md` §1: giữ theo spec, không prewarm. Code hiện tại chuyển `.playAndRecord` ngay khi vào mode nên cắt nhạc người dùng và giữ chấm privacy mic dù chưa quay.)* Chỉ đặt `audioAttached = true` sau khi add input thành công; lỗi phải rollback và báo/retry.
6. Thêm `isAppActive`/lifecycle generation để callback finalize cũ không stop session sau khi app đã active trở lại.
7. Dừng location updates khi background và start lại khi active; kiểm age/accuracy của location tại thời điểm capture.
8. Chỉ publish `quickTakeAvailable`, capability và transition complete sau khi session graph commit thành công; mọi đọc/ghi `session.inputs/outputs` nên ở `sessionQueue`.

### P2 — Đúng chức năng và phản hồi lỗi

9. Portrait phải báo khi depth không bật hoặc renderer fail; intensity 0 nên trả ảnh không blur.
10. `subjectAreaDidChange` không nên phụ thuộc việc focus indicator còn hiện; cần lưu trạng thái tap-focus riêng và luôn restore continuous AF/AE đúng lúc.
11. Rollback UI state khi lock device thất bại ở focus lock, EV, zoom và torch.
12. Tạo `zoomStops` theo min/max thật; fallback Wide không được hiện 0,5×.
13. Xác minh fps video sau negotiation; nếu preset/fps không hỗ trợ phải báo hoặc chọn format phù hợp, không bỏ qua im lặng.
14. Metadata scanning nên disable connection hoặc metadata types khi recording/off; hiện tên type chính xác và animate state change thực sự.
15. Gom policy aspect/crop thành một source of truth dùng cho cả preview và save path.

### P3 — Đồng bộ đặc tả và độ bền

16. Chốt quyết định orientation: giữ `RotationCoordinator` thì cập nhật mục 5; nếu đặc tả bắt buộc portrait thì đổi code về 90°.
17. Chọn max photo dimension bằng diện tích thay vì `.last`.
18. ProRAW processed codec cần fallback nếu HEVC không khả dụng.
19. Cleanup temp artifacts cả khi app khởi động lại/crash; xóa thư mục time-lapse rỗng và Live Photo temp khi Photos save thất bại.
20. Thay URL scheme mở Photos không được tài liệu hóa bằng giải pháp được Apple hỗ trợ hoặc chấp nhận rõ rủi ro.

### Bổ sung sau lần rà soát lại (không nằm trong 20 mục gốc)

21. **Time-lapse lấy kích thước video từ frame đầu tiên.** `TimeLapseRecorder.assemble` đọc kích thước của `f_0.jpg` rồi ép mọi frame sau vào đúng kích thước đó. Xoay máy giữa lúc quay là các frame sau bị bóp méo, không có cảnh báo. → PR 2.
22. **`scenePhase == .inactive` chưa được xử lý.** `CameraUI.swift` chỉ bắt `.active` và `.background`; kéo Control Center, kéo thanh thông báo hay vào app switcher đều rơi vào `default: break` và session vẫn chạy. Mục 21 ở trên ghi là "scenePhase có" — thực tế mới có hai trong ba pha. → PR 5.
23. **Mục 17 nặng hơn mô tả ban đầu.** Hai nguồn sự thật về aspect không chỉ trùng lặp mà thật sự cho kết quả khác nhau: Live Photo bật **và** EV ≠ 0 → capture đi đường AE bracket → bracket loại trừ Live Photo → `liveMovie == nil` → `shouldCrop` thành true → ảnh bị cắt 16:9 trong khi preview đã hứa 4:3. Đây là lỗi kết quả sai, không phải hạng mục gọn gàng. → PR 10.

## Xác minh đã thực hiện

- Đọc và đối chiếu `func_req.md` với `Info.plist`, `project.yml`, `App.swift`, `CaptureTypes.swift`, `CameraManager.swift`, `CameraManagerCapture.swift`, `MediaProcessing.swift`, `CameraUI.swift` và workflow CI.
- `swiftc -frontend -parse` trên toàn bộ 6 file Swift: **thành công**.
- `git status --short`: **sạch** tại thời điểm audit trước khi tạo báo cáo này.
- Không thể type-check/build iOS tại máy hiện tại vì đây là Windows, không có `xcodebuild`, UIKit/AVFoundation iOS SDK. Workflow CI đã có đường build bằng `macos-26`, Xcode >= 26, XcodeGen và unsigned archive.
- **Không có iPhone để test, và đây là ràng buộc cố định của dự án chứ không phải tạm thời.** Vì vậy các mục sau sẽ **không bao giờ** được xác nhận bằng con đường hiện tại: tele có hoàn toàn im, fps thực, stereo, chất lượng depth mask, mirroring preview, gesture QuickTake sát ngưỡng, cấu trúc asset trong Photos, chấm privacy mic, và toàn bộ nhóm race lifecycle.
- Cách bù đắp đã chốt: một test target chạy trên iOS Simulator trong CI (PR 0 của `REMEDIATION_PLAN.md`), phủ được phần logic thuần — toán fps, hình học crop, ma trận capture policy, ghép time-lapse, persistence. Ước tính 13/20 mục ưu tiên đóng được ở mức `static+CI`; 7 mục còn lại chỉ là "sửa theo phân tích", xem sổ nợ §4.Y của kế hoạch.

## Trạng thái remediation

- **PR 1 — Cổng thao tác và transaction session: đã áp dụng (mức `static`).** Bao phủ P0.4 (serialize đổi mode/flip/chụp/zoom, guard `isBursting` ngay trong `CameraManager.setMode`) và một phần P1.8 (`quickTakeAvailable`/`movieOutputAttached` chỉ publish sau `commitConfiguration` thật, không còn đọc `session.outputs` từ main actor ở `startRecording`). Thêm `CameraManager.canPerform(_:)` làm cổng gác chung cho đổi mode/flip/chụp/QuickTake/zoom, `pendingMode` để mode bấm dở dang không bị rớt, và sửa `flipCamera()` đọc input thật từ `session.inputs` trên `sessionQueue` thay vì dùng `videoInput` có thể đã lỗi thời — khớp thiết kế PR 1 của `REMEDIATION_PLAN.md`.
  - Xác minh đã có: `swiftc -frontend -parse` trên toàn bộ file Swift thành công; `git grep` xác nhận không có `builtInTripleCamera`/`builtInTelephotoCamera`, `zoomStops` không có mốc 3×.
  - **Vòng review sau đó đã sửa tiếp trong cùng lát cắt PR 1:**
    - Tách `sessionBusy` (cổng thao tác) khỏi `isModeTransitioning` (lớp mờ preview). Watchdog nay hai nhịp: 2 giây nhả lớp mờ để preview không kẹt, 4 giây nữa mới mở cổng kèm `errorMessage` và bỏ việc đang chờ. Trước đó watchdog gộp làm một, nên cấu hình chạy quá 2 giây — lần đầu bật camera trước, máy nóng — là cổng mở ra giữa lúc transaction còn đang chạy, đúng thứ bước 9 của kế hoạch cấm.
    - `canPerform(.flip)` và `.reconfigure` thêm `!isBursting`; trước đó lật camera hoặc bật/tắt Live Photo vẫn lọt được vào giữa một mẻ chụp liên tiếp.
    - `capturePhoto` trả `Bool`; vòng lặp burst chỉ tăng `burstCount` khi thật sự đặt hàng được một tấm. Trước đó badge đếm nhảy số trong khi cổng đang chặn và không có ảnh nào.
    - `reconfigure()` bị chặn vì session bận nay được giữ lại thành `pendingReconfigure` thay vì bỏ im lặng — mọi chỗ gọi đều đã `settings.save()` trước, bỏ qua là settings và session nói hai chuyện khác nhau.
    - `beginModeTransition` huỷ luôn hẹn giờ đang đếm: hẹn giờ thuộc cấu hình cũ, để nguyên thì lúc về 0 `capturePhoto` bị chính cổng chặn im lặng.
    - Thêm action `.deviceTweak` gác `focus(at:)` và `setExposureBias`. `setTorch` cố ý KHÔNG gác vì `applyMode`/`flipCamera` gọi nó ngay giữa lúc cổng đóng.
    - UI bỏ bản sao luật cổng: `applyModeSelection`, nút lật, mốc zoom, cử chỉ burst và long-press QuickTake đều hỏi `cam.canPerform(...)` thay vì tự kiểm lại `isRecording/isProcessing/isBursting/isModeTransitioning`.
  - **Chưa có: PR 0 (test target trong CI) chưa được dựng**, nên chưa có unit test hay CI xanh đi kèm PR này — mức xác minh dừng ở `static` (đọc code + parse cú pháp), chưa tới `static+CI` như kế hoạch giả định. Toàn bộ nhóm "Test máy thật — HOÃN" của PR 1 (stress 100 thao tác, race mode/flip/shutter thật) vẫn nằm nguyên trong sổ nợ §4.Y của `REMEDIATION_PLAN.md`, chưa mục nào được đóng.
