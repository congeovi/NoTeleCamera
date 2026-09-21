# Kế hoạch remediation NoTeleCamera sau audit

## 1. Mục tiêu và nguyên tắc thực hiện

Kế hoạch này xử lý đủ **20 mục P0–P3** trong `AUDIT_REPORT.md`, theo thứ tự giảm rủi ro. Mục tiêu cuối cùng không chỉ là “build thành công”, mà là:

1. Không mất video/khung hình khi dừng time-lapse hoặc khi export slo-mo lỗi.
2. Mọi thay đổi session được tuần tự hóa; UI chỉ phản ánh trạng thái AVFoundation đã commit thành công.
3. Mic chỉ hoạt động khi thực sự quay; lifecycle không để callback cũ phá session mới.
4. Các lỗi cấu hình thiết bị được rollback và báo cho người dùng.
5. Giữ nguyên invariant quan trọng nhất: **không có đường chọn `builtInTripleCamera` hoặc `builtInTelephotoCamera`; camera sau thường vẫn là `builtInDualWideCamera`, slo-mo là `builtInWideAngleCamera`.**

Không nên gom tất cả vào một PR. Thứ tự đề xuất bên dưới gồm **PR 0 + 11 PR**; mỗi PR phải
qua CI xanh độc lập trước khi bắt đầu PR tiếp theo.

### Quyết định đã chốt trước khi bắt đầu

| # | Vấn đề | Quyết định | Ảnh hưởng |
|---|---|---|---|
| D1 | Hướng ảnh: `RotationCoordinator` hay ép 90° như `func_req.md:114`? | **Giữ `RotationCoordinator`**, cập nhật spec. Ép 90° làm ảnh chụp ngang bị gắn hướng dọc. | PR 10 |
| D2 | Mic: prewarm khi vào mode Video hay attach lúc bấm quay? | **Attach lúc bấm quay**, đúng spec. Lý do đầy đủ ở đầu PR 4. | PR 4 |
| D3 | Torch khi tráo device sang slo-mo | **Luôn tắt**, đúng `func_req.md:232`. | PR 3 |
| D4 | Sheet Cài đặt có kéo lên full màn không | **Chỉ `.medium`**, đúng `func_req.md:337`. | PR 10 (hoặc tách riêng, 1 dòng) |
| D5 | Phạm vi release | Xem §7 — không mốc nào đạt được chỉ bằng CI. | §7 |

## 2. Quy tắc làm việc dành cho junior dev hoặc AI

Trước mỗi PR:

1. Đọc lại phần code được liệt kê trong task; không sửa symbol chưa đọc.
2. Đọc `docs/ai/50-stack-patterns.md` trước khi chạm vào pipeline capture — phần lớn bẫy AVFoundation nằm ở đó.
3. Tạo branch riêng, ví dụ `fix/session-operation-gate`.
4. Chỉ sửa phạm vi của PR. Không refactor UI hoặc đổi naming ngoài phạm vi.
5. Không thêm `builtInTripleCamera`, `builtInTelephotoCamera`, mốc zoom 3×, hoặc discovery session có thể tự chọn tele.

### 2.1. Môi trường kiểm chứng — KHÔNG có máy thật

Máy phát triển chạy **Windows**. Không có `xcodebuild`, không có iOS SDK, **không có iPhone để test**.
Đây là ràng buộc cố định của dự án, không phải tình trạng tạm thời. Mọi thứ trong kế hoạch này
phải đóng được bằng ba cơ chế sau và chỉ ba cơ chế đó:

| Tầng | Lệnh / nơi chạy | Bắt được gì |
|---|---|---|
| Parse cú pháp | `swiftc -frontend -parse *.swift` trên Windows | lỗi cú pháp thuần |
| Build thật | GitHub Actions `.github/workflows/build.yml` (macos-26, unsigned archive) | lỗi type-check, API sai, availability sai |
| Unit test | test target chạy trên iOS Simulator trong CI — **xem PR 0** | logic thuần: toán fps, hình học crop, ghép time-lapse, persistence |

Không có tầng nào bắt được: race condition thật, fps phần cứng thật, chất lượng depth mask,
mirroring preview, chấm privacy mic, cấu trúc asset trong Photos, hay việc ống tele có
thật sự im hay không.

### 2.2. Kiểm tra invariant chống tele sau mỗi PR

```bash
git grep -n "builtInTripleCamera\|builtInTelephotoCamera"
git grep -n -A4 "var zoomStops"
git diff --check
```

Lệnh một: phải không có kết quả. Lệnh hai: đọc mắt danh sách mốc zoom — grep theo chuỗi
`3.0` là không đủ, vì mốc tele có thể được viết là `3`, `2.99` hay một biến. Trần zoom
`maxDisplayZoom` phải vẫn là `5.0`.

---

## 3. Thứ tự PR và dependency

| PR | Nội dung | Ưu tiên | Phụ thuộc |
|---|---|---:|---|
| 0 | Test target chạy trong CI | hạ tầng | Không |
| 1 | Cổng thao tác và transaction session | P0 | PR 0 |
| 2 | Time-lapse generation, drain, backpressure | P0 | PR 1 |
| 3 | Slo-mo fps chính xác và bảo toàn file gốc | P0 | PR 1 |
| 4 | Audio/mic và recording state đúng sự thật | P1 | PR 1 |
| 5 | Lifecycle generation, location, media reset | P1 | PR 4 |
| 6 | Capability, zoom, fps video, max dimension, ProRAW | P1/P2/P3 | PR 1 |
| 7 | Focus/EV/zoom/torch rollback | P2 | PR 1, PR 6 |
| 8 | Portrait có lỗi rõ ràng và intensity 0 | P2 | PR 1 |
| 9 | Metadata scanning thực sự nghỉ | P2 | PR 4 |
| 10 | Capture policy, aspect và quyết định orientation | P2/P3 | PR 6 |
| 11 | Temp-file recovery và thay `photos-redirect://` | P3 | PR 2–5, PR 10 |

Không làm song song PR 1–5 vì đều chạm `CameraManager.swift` và cùng thay đổi state machine.

---

# PR 0 — Test target chạy trong CI

**Bao phủ audit:** không mục nào trực tiếp. Đây là hạ tầng bù cho việc không có máy thật.

**File chính:** `project.yml`, `.github/workflows/build.yml`, thư mục mới `Tests/`.

## Vì sao cần

Không có iPhone thì các bản vá nặng về toán và về thứ tự — fps quay chậm, hình học crop,
ghép frame time-lapse — không có cách nào biết là đúng hay sai. Nhưng những phần đó **là
logic thuần, chạy được trên iOS Simulator**, mà runner `macos-26` thì có sẵn simulator.
Đây là thứ gần nhất với kiểm chứng thật mà dự án có thể có.

## Các bước thực hiện

1. Dựng hạ tầng và phủ những gì **đã tồn tại**. PR 0 không sửa logic sản phẩm — mỗi PR sau
   tự mang test của mình theo (DoD §5). Ở đây chỉ cần mở đường: tách được phần logic thuần
   ra khỏi `CameraManager` để test không cần `AVCaptureDevice` thật, cụ thể là toán
   duration/fps (nhận `(min, max)` frame-rate range dạng số, trả CMTime + fps thực).
2. Thêm target `NoTeleCameraTests` (`type: bundle.unit-test`) vào `project.yml`.
3. Viết test cho code **hiện có**, để có lưới an toàn trước khi sửa:
   - `SlomoRate.slowdown(forCapturedFps:)`;
   - `MediaProcessing.cropPreservingMetadata` — tỉ lệ ra đúng, orientation 5–8 lật đúng chiều, metadata còn;
   - `CGFloat.evenized` (đang `private`, cần nâng lên `internal` hoặc `@testable import`);
   - `CameraSettings.load()/save()` round-trip và fallback khi giá trị rác;
   - `TimeLapseRecorder.assemble` với vài frame dựng sẵn — `AVAssetWriter` chạy được trên
     simulator. Test này sẽ **fail hoặc lộ hành vi xấu ngay bây giờ**; đó là mục đích.
4. Thêm step vào CI **trước** step archive:

```yaml
- name: Run unit tests
  run: |
    xcodebuild test \
      -project NoTeleCamera.xcodeproj \
      -scheme NoTeleCamera \
      -destination 'platform=iOS Simulator,name=iPhone 17' \
      CODE_SIGNING_ALLOWED=NO
```

Tên simulator phải lấy từ `xcrun simctl list devicetypes` của image, không hardcode mù.

5. Không cố test đường capture thật. Simulator không có camera: `AVCaptureDevice.default(...)`
   trả `nil` và `configureSession` rơi vào nhánh "Không mở được camera." Đó là hành vi đúng
   và có thể test như một smoke test, nhưng không thay được máy thật.

## Tiêu chí nghiệm thu

- CI có step test và step đó xanh.
- Test fail thì CI fail (không `continue-on-error`).
- Ít nhất toán fps và hình học crop có test.

---

# PR 1 — Cổng thao tác và transaction session

**Bao phủ audit:** P0.4, một phần P1.8 và guard `isBursting` của mục 4.

**File chính:** `CameraManager.swift`, `CameraManagerCapture.swift`, `CameraUI.swift`.

## Thiết kế cần chốt

Không thay toàn bộ các `@Published Bool` ngay lập tức. Thêm một lớp điều phối nhỏ làm nguồn quyết định:

```swift
enum CameraOperation {
    case idle
    case reconfiguring(UUID)
    case preparingRecording(UUID)
    case recording(UUID)
    case finalizingRecording(UUID)
    case processing(UUID)
}
```

Có thể giữ `isModeTransitioning`, `isRecording`, `isProcessing` để UI tương thích, nhưng chỉ cập nhật chúng từ transition của `CameraOperation`. Thêm `sessionRevision: UInt64`; tăng revision sau mỗi `commitConfiguration()` thành công.

## Các bước thực hiện

1. Tạo helper `canPerform(_ action: CameraAction) -> Bool` trên main actor. Ít nhất có action: đổi mode, flip, shutter, QuickTake, zoom, reconfigure.
2. Trong `setMode`, thêm guard `!isBursting` và không nhận mode mới khi đang reconfigure. Nếu muốn UX tốt hơn, lưu đúng **một** `pendingMode` cuối cùng; không xếp hàng vô hạn.
3. Trong `reconfigure`, `flipCamera`, `shutterTapped`, `shutterHoldBegan`, `capturePhoto`, `setZoom`, kiểm gate. Trong lúc reconfigure:
   - chặn flip, shutter, QuickTake;
   - zoom có thể bị từ chối và giữ nguyên UI, không cần queue;
   - mode mới có thể thay `pendingMode`.
4. Sửa `flipCamera()` để không capture `videoInput` từ main actor trước khi vào queue. Bên trong `sessionQueue`, lấy input video thật từ `session.inputs`, giống cách `applyMode` đang làm.
5. Chỉ gán `isFront`, `videoInput`, `baseFactor`, capability và settings sau khi cấu hình camera mới thành công. Nếu `canAddInput` thất bại, giữ toàn bộ state cũ và hiện lỗi.
6. Mọi lần đọc/ghi `session.inputs`, `session.outputs`, `connection`, `beginConfiguration/commitConfiguration` phải nằm trên `sessionQueue`.
7. Tạo kiểu kết quả transaction, ví dụ `SessionGraphResult`, chứa input/device/capability/zoom mới. Sau `commitConfiguration`, chuyển kết quả về main actor một lần.
8. `quickTakeAvailable` chỉ được publish từ kết quả thật: `movieOutput` thực sự có trong `session.outputs`, mode là Photo, và Live Photo không chiếm output.
9. `finishModeTransition` chỉ kết thúc generation hiện tại. Watchdog chỉ giải phóng lớp mờ và báo lỗi; watchdog không được tự coi cấu hình là thành công.
10. Disable nút shutter/flip/zoom trong UI khi gate không cho phép, nhưng vẫn giữ guard trong manager vì volume shutter hoặc callback có thể gọi trực tiếp.

## Tiêu chí nghiệm thu

- Bấm đổi mode liên tục rồi flip không tạo hai video input.
- Không chụp hoặc QuickTake trong khi `isModeTransitioning == true`.
- Flip thất bại không đổi icon/front state và không mất input cũ.
- `quickTakeAvailable == true` chỉ khi `movieOutput` thật sự đã được add.
- `setMode` bị chặn khi burst đang chạy.
- Không có truy cập mới tới `session.inputs/outputs` ngoài `sessionQueue`.

## Test máy thật — HOÃN (xem §4)

- Lặp 50 lần: Photo → Slo-mo → flip → Video → Photo.
- Trong lúc preview đang mờ, bấm shutter, zoom, flip liên tục; app không crash, không chụp nhầm camera.
- Sau stress test, kiểm camera sau vẫn có 0,5×/1× và không có 3×.

---

# PR 2 — Time-lapse an toàn: generation, drain và backpressure

**Bao phủ audit:** P0.1 và phần cleanup time-lapse của P3.19.

**File chính:** `CameraManager.swift`, `CameraManagerCapture.swift`, `MediaProcessing.swift`.

## Mô hình dữ liệu

Mỗi lần bấm bắt đầu time-lapse phải có context riêng:

```swift
struct TimeLapseContext {
    let id: UUID
    var phase: Phase       // accepting, draining, assembling, finished
    var nextSequence: Int
    var operationsInFlight: Int
    var successfulFrames: Int
}
```

Mở rộng `PendingCapture` với `timeLapseGeneration: UUID?` và `timeLapseSequence: Int?`. Không dùng duy nhất `timeLapseFrames` để quyết định drain vì biến đó chỉ đếm frame đã hoàn tất.

Nên chuyển `TimeLapseRecorder` thành `actor`, hoặc giữ serial queue nhưng API phải là async/throwing. Không để `append` fire-and-forget.

## Các bước thực hiện

1. Khi start:
   - tạo UUID mới;
   - tạo folder riêng cho generation;
   - đặt phase `.accepting`;
   - reset counter;
   - scheduler capture luôn truyền UUID hiện tại.
2. Trước mỗi request:
   - xác nhận context vẫn `.accepting`;
   - áp backpressure, đề xuất tối đa 2 capture time-lapse đang bay;
   - cấp `sequence` ngay lúc submit;
   - tăng `operationsInFlight` trước khi gọi `capturePhoto`.
3. Nếu session không chạy, cấu hình settings lỗi hoặc watchdog hết hạn, phải kết thúc operation đúng một lần. Dùng helper duy nhất, ví dụ `finishTimeLapseOperation(generation:)`, tránh decrement ở nhiều nhánh.
4. Trong callback:
   - generation khác generation hiện tại: bỏ data, dọn pending, không append vào recorder mới;
   - generation đúng: gọi `await recorder.append(data, sequence:, generation:)`.
5. `append` phải:
   - decode ảnh; nếu decode lỗi thì throw;
   - encode JPEG; nếu encode lỗi thì throw;
   - ghi file bằng `write(options: .atomic)`; không dùng `try?`;
   - chỉ thêm URL vào snapshot sau khi write thành công;
   - trả về kết quả success/failure.
6. Chỉ tăng `successfulFrames`/UI `timeLapseFrames` sau khi append thành công.
7. Khi stop:
   - cancel scheduler;
   - chuyển phase `.draining` trước, để không nhận request mới;
   - không reset recorder;
   - chờ `operationsInFlight == 0` của đúng generation;
   - thêm timeout lớn hơn capture watchdog một khoảng nhỏ, ví dụ watchdog 8 giây thì drain timeout 10 giây;
   - sau drain mới snapshot danh sách URL đã sort theo `sequence`.
8. Nếu sau drain có dưới 2 frame thành công, báo “quá ít khung hình”, dọn folder và kết thúc.
9. `assemble` nhận snapshot bất biến; không đọc `frameURLs` đang thay đổi.
10. Khi gọi `adaptor.append`, kiểm Bool. Nếu false, cancel writer và throw kèm `writer.error`.
11. Nếu decode image/pixel buffer của một frame lỗi, chọn chính sách rõ ràng: fail toàn bộ export thay vì âm thầm bỏ frame. Điều này giúp phát hiện file hỏng và giữ counter trung thực.
12. Dùng `defer`/helper cleanup cho tất cả nhánh:
    - xóa output `.mov` dở;
    - xóa frame và folder generation;
    - resume continuation đúng một lần;
    - đưa UI ra khỏi `isProcessing`.
13. Không cho callback cũ gọi `reset()` lên recorder của generation mới.
14. **Kích thước video không được lấy từ frame đầu tiên.** Hiện `assemble` đọc
    `UIImage(contentsOfFile: first.path)` rồi ép mọi frame sau vào đúng kích thước đó
    (`MediaProcessing.swift`, hàm `assemble`). Xoay máy giữa lúc quay tua nhanh là các
    frame sau bị bóp méo. Chọn một chính sách rõ ràng:
    - chốt orientation tại lúc bắt đầu time-lapse và bỏ qua (hoặc xoay lại) frame có
      kích thước khác; hoặc
    - từ chối frame sai kích thước và báo số frame đã bỏ.
    Không im lặng vẽ đè như hiện tại.

## Tiêu chí nghiệm thu

- Stop ngay sau lúc request cuối vừa gửi vẫn đưa frame cuối vào video hoặc chờ watchdog; không export sớm.
- `timeLapseFrames` bằng số file frame ghi thành công, không bằng số request.
- Không có `try? jpeg.write` hoặc bỏ qua kết quả `adaptor.append` trong luồng này.
- Callback generation cũ không xuất hiện trong video generation mới.
- Mọi nhánh lỗi đều thoát processing và không để folder rỗng/file `.mov` dở.

## Test máy thật — HOÃN (xem §4)

1. Interval 0,5 giây, quay 30 giây, stop ở nhiều thời điểm ngẫu nhiên.
2. Start → stop → start lại thật nhanh 20 lần.
3. Stop khi `capturesInFlight > 0`.
4. Đưa app background trong lúc time-lapse; file tạo được hoặc báo lỗi rõ ràng, không treo.
5. Làm đầy gần hết dung lượng để ép write failure; UI phải báo lỗi và cleanup.

---

# PR 3 — Slo-mo đúng fps và không mất file gốc

**Bao phủ audit:** P0.2, P0.3 và lỗi torch của mục 14.

**File chính:** `CameraManager.swift`, `MediaProcessing.swift`.

## Các bước thực hiện

1. Thay:

```swift
CMTime(value: 1, timescale: CMTimeScale(actualFps))
```

bằng **CMTime hữu tỉ mà chính phần cứng khai báo**, lấy thẳng từ frame-rate range:

```swift
guard let range = fmt.videoSupportedFrameRateRanges
        .max(by: { $0.maxFrameRate < $1.maxFrameRate }) else { ... }
let d = range.minFrameDuration        // ví dụ 1001/240000 cho 239,76 fps
activeDev.activeVideoMinFrameDuration = d
activeDev.activeVideoMaxFrameDuration = d
```

> ⚠️ **KHÔNG dùng `CMTime(seconds: 1.0 / fps, preferredTimescale: 60_000)`.** Với 239,76 fps
> thì `1/239,76 × 60000 = 250,25` → làm tròn thành `250` → `60000/250` = **đúng 240 fps**,
> ngắn hơn `minFrameDuration` thật nên nằm NGOÀI dải của `activeFormat`. Gán giá trị ngoài
> dải là `NSInvalidArgumentException` — crash, không phải trả lỗi. Xem comment ở
> `CameraManager.swift` hàm `achievableFps`. Cách này đổi một sai số hiển thị lấy một cú crash.

2. Sau khi gán, **đọc lại `activeDev.activeVideoMinFrameDuration`** rồi tính:

```swift
configuredFPS = 1.0 / activeDev.activeVideoMinFrameDuration.seconds
```

`activeSlomoFps` phải là `configuredFPS` đọc ngược từ thiết bị, không phải số range dự kiến
và cũng không phải số vừa gán. Có unit test cho phép tính này ở PR 0.
3. Nếu lock device hoặc gán format thất bại, rollback format/duration cũ, để `activeSlomoFps = nil` và báo lỗi.
4. Lưu `RecordingContext` ngay khi bắt đầu quay, gồm mode và configured fps. Delegate finish dùng context này; không đọc `settings.mode` có thể đã thay đổi.
5. Factor export = `configuredFPS / targetPlaybackFPS`; target hiện tại là 30 fps. Với 239,76 fps, factor xấp xỉ 7,992, không phải 8 do làm tròn.
6. Tách save video thành API trả kết quả async/completion thay vì tự xóa file vô điều kiện.
7. Chính sách file:
   - export lỗi: **không xóa source**; thử lưu source vào Photos như bản fallback và báo “Không tạo được slow-motion, đã lưu bản gốc”.
   - export thành công nhưng lưu bản slow-motion thất bại: giữ source để retry/fallback; xóa output export dở nếu cần.
   - chỉ xóa source sau khi bản slow-motion đã được Photos xác nhận lưu thành công.
8. Khi swap sang device slo-mo mới, luôn `setTorch(false)` và `torchOn = false`; không tái bật torch từ device cũ.
9. `MediaProcessing.slowDown` phải xóa output tạm nếu export không `.completed`.

## Tiêu chí nghiệm thu

- `activeSlomoFps` phản ánh duration thực sự đã cấu hình.
- Clip 239,76 fps có duration đầu ra theo factor 239,76/30 trong dung sai ±1 frame đầu ra.
- Không có nhánh export lỗi nào xóa source trước khi source hoặc output được lưu an toàn.
- Đổi vào slo-mo luôn tắt torch.

## Test máy thật — HOÃN (xem §4)

- Quay 120 và 240 fps trên camera sau; quay mức fallback trên camera trước.
- So duration source/output bằng AVAsset metadata.
- Ép export lỗi hoặc Photos save lỗi; xác nhận source còn tồn tại hoặc đã được lưu fallback.
- Bật torch ở Video rồi chuyển Slo-mo; torch phải tắt.

---

# PR 4 — Mic chỉ hoạt động lúc quay và state theo callback thật

**Bao phủ audit:** P1.5, lỗi recording state của mục 12/13.

**File chính:** `CameraManager.swift`, `CameraUI.swift`.

## Quyết định đã chốt

> **Mic gắn lúc bấm quay, KHÔNG prewarm khi vào mode.** Theo đúng `func_req.md` §12/§21.
>
> Lý do: Camera gốc của Apple hành xử đúng như vậy (vào tab Video nhạc vẫn phát, chấm cam
> mic chưa sáng; bấm quay mới tắt nhạc). Code hiện tại chuyển `.playAndRecord` ngay khi vào
> mode nên **cắt nhạc người dùng đang nghe dù chưa quay**, và giữ chấm privacy mic suốt lúc
> chỉ đang ngắm — hai lỗi chắc chắn xảy ra, người dùng thấy được.
>
> Lý do biện hộ cho prewarm trong comment code ("mic cần vài trăm ms mới ổn định") được xử lý
> bằng pipeline ở bước 6: attach mic xong rồi mới gọi `startRecording`, nên độ trễ nằm TRƯỚC
> khi file tồn tại và không lọt vào video.
>
> Rủi ro chấp nhận: QuickTake giữ-để-quay có thể hụt tiếng ở đầu clip. Clip tối thiểu 1 giây
> nên tỉ lệ ảnh hưởng nhỏ. **Không đo được vì không có máy thật** — nếu sau này có máy và thấy
> tệ thì lật lại chỉ là một cờ trong `applyMode`. Không đổi quyết định này nếu chưa có số đo.

## Các bước thực hiện

1. Xóa `wantsMic` khỏi `applyMode`; vào Video/Slo-mo không được attach mic hoặc chuyển audio session.
2. Đổi `attachAudioIfNeeded` thành API completion có `Result<Void, AudioSetupError>`.
3. Không đặt `audioAttached = true` trước khi add input. Chỉ đặt true sau khi:
   - tạo audio input thành công;
   - `session.canAddInput(input)` trả true;
   - input đã được add và transaction commit.
4. Nếu lỗi, remove input vừa add (nếu có), trả audio category về `.ambient`, đặt `audioAttached = false`, trả failure.
5. Chỉ mode Video và QuickTake cần mic. Slo-mo bỏ audio ở output cuối nên không attach mic, trừ khi đặc tả được đổi rõ ràng.
6. `startRecording` chuyển sang pipeline:
   - tạo `RecordingContext` UUID;
   - state `.preparingRecording`;
   - attach audio nếu cần;
   - sau success mới gọi `movieOutput.startRecording`;
   - nếu failure, về idle và hiện lỗi/retry được.
7. Implement delegate `fileOutput(_:didStartRecordingTo:from:)`. Chỉ tại callback này mới đặt `isRecording = true` và bắt đầu timer.
8. Trong thời gian preparing, UI hiển thị trạng thái chờ ngắn và disable thao tác xung đột; không hiển thị như đang quay.
9. `didFinishRecording` luôn detach mic cho Video/QuickTake. Không giữ mic giữa hai lần quay.
10. `detachAudio` cũng trả Result hoặc ít nhất completion; audio category chỉ về ambient sau khi input đã remove.
11. QuickTake gesture race sẽ được giảm bằng operation state: tap end chỉ chụp ảnh nếu state chưa từng vào `.preparingRecording`/`.recording`. Thêm gesture-local flag như `didTriggerHold` để `.onEnded` của drag không gọi `shutterTapped` sau khi long press đã thắng.

## Tiêu chí nghiệm thu

- Chỉ vào mode Video không bật mic/audio `playAndRecord`.
- Mic attach lỗi không để `audioAttached == true`; lần bấm sau có thể retry.
- `isRecording` chỉ true sau callback didStart.
- Sau didFinish, session không còn audio input và audio category trở về ambient.
- Giữ 0,45–0,5 giây không vừa chụp ảnh vừa tạo QuickTake.

## Test máy thật — HOÃN (xem §4)

- Mở nhạc, vào Video nhưng chưa quay: nhạc không bị audio policy của app cắt/đổi.
- Quan sát privacy indicator: mic chỉ xuất hiện khi Video/QuickTake thực sự đang quay.
- Bấm record/stop nhanh 20 lần.
- Từ chối quyền mic: Video báo lỗi rõ ràng; chụp ảnh vẫn dùng được.

---

# PR 5 — Lifecycle generation, location và media reset

**Bao phủ audit:** P1.6, P1.7, phần còn lại của mục 21.

**File chính:** `CameraManager.swift`, `CameraUI.swift`.

## Các bước thực hiện

1. Thêm `isAppActive` và `lifecycleGeneration: UInt64` trên main actor.
2. Khi scene active:
   - tăng generation;
   - đặt `isAppActive = true`;
   - start session nếu cần;
   - start location updates;
   - apply mode chỉ sau session sẵn sàng.
3. Khi inactive/background:
   - đặt `isAppActive = false` trước khi stop recording;
   - ghi generation vào `RecordingContext`/pending stop;
   - stop location updates ngay;
   - dừng motion/countdown/burst.
4. `stopSessionIfPending` phải kiểm cả hai điều kiện: app hiện vẫn inactive và pending stop thuộc lifecycle generation phù hợp. Callback clip cũ không được stop session đã restart ở generation mới.
5. Interruption-ended cũng chỉ restart khi `isAppActive == true`.
6. Tạo `validatedLocation(at:)`:
   - `horizontalAccuracy >= 0`;
   - age đề xuất ≤ 15 giây;
   - accuracy đề xuất ≤ 100 m;
   - nếu không đạt thì trả nil.
7. Snapshot location đã validate tại thời điểm bắt đầu capture/recording; không đọc location mới khi callback save về muộn.
8. Với `.mediaServicesWereReset`:
   - thử start graph hiện tại;
   - nếu session không chạy lại hoặc input/output thiếu, gọi đường rebuild có kiểm soát;
   - rebuild phải đi qua operation gate và không add observer lần hai.
9. Khi inactive, media reset/interruption callback không được tự start session.
10. **Xử lý `scenePhase == .inactive`.** Hiện `CameraUI.swift` chỉ bắt `.active` và
    `.background`, còn `.inactive` rơi vào `default: break` — kéo Control Center, kéo
    thanh thông báo hay vào app switcher thì session vẫn chạy và mic (nếu đang quay) vẫn
    thu. Mục 21 của audit ghi là đã xử lý scenePhase, thực tế mới xử lý hai trong ba pha.
    Chính sách đề xuất: `.inactive` không tắt session (người dùng quay lại ngay), nhưng
    phải dừng burst/countdown và ghi nhận trạng thái; `.background` giữ nguyên hành vi
    hiện tại.

## Tiêu chí nghiệm thu

- Background → active trước lúc didFinish cũ về: callback cũ không dừng preview mới.
- Location updates dừng ở background và chạy lại ở active.
- GPS quá cũ/sai số cao không được gắn vào asset.
- Media reset khi active có fallback rebuild; khi background không tự bật camera.

---

# PR 6 — Capability và negotiation chính xác

**Bao phủ audit:** P1.8, P2.12, P2.13, P3.17, P3.18.

**File chính:** `CameraManager.swift`, `CameraManagerCapture.swift`.

## Các bước thực hiện

1. Tạo helper chọn max photo dimension bằng diện tích:

```swift
max(by: { lhs, rhs in
    Int64(lhs.width) * Int64(lhs.height) < Int64(rhs.width) * Int64(rhs.height)
})
```

Dùng helper ở configure, apply mode và flip; bỏ `.last`.
2. `zoomStops` lấy tập mong muốn theo mode, sau đó filter bằng min/max display zoom thực tế. Fallback wide đơn không được hiện 0,5×.
3. Snapshot `baseFactor`, min/max và device ID trước khi enqueue zoom. Sau lock thành công, đọc `device.videoZoomFactor`, quy đổi ngược và mới publish `displayZoom`.
4. Nếu device đã đổi trước lúc block zoom chạy, bỏ request; không áp factor của device cũ lên device mới.
5. Refactor `applyFrameRate` trả `Result<configuredFPS, FrameRateError>`.
6. Nếu active format không hỗ trợ fps yêu cầu, tìm format phù hợp với camera, kích thước/chất lượng và fps; nếu không có thì báo lỗi rõ, không im lặng.
7. Sau set duration, đọc lại và publish fps thực. UI quality phải phản ánh fallback nếu có.
8. Capability (`supportsLivePhoto`, `supportsDepth`, `supportsProRAW`, `quickTakeAvailable`) chỉ publish từ transaction đã commit.
9. ProRAW processed codec: chọn HEVC nếu `availablePhotoCodecTypes` chứa `.hevc`, nếu không chọn JPEG/default; không hard-code HEVC.

## Tiêu chí nghiệm thu

- Device min zoom 1× không hiện nút 0,5×.
- Nút zoom chỉ cập nhật sau khi hardware config thành công.
- 1080p60 không hỗ trợ thì app chọn format hợp lệ hoặc báo lỗi.
- Max photo dimension là kích thước có diện tích lớn nhất.
- ProRAW vẫn chụp được khi processed HEVC không khả dụng.

---

# PR 7 — Rollback focus, EV, zoom và torch

**Bao phủ audit:** P2.10, P2.11 và phần lỗi mục 3.

**File chính:** `CameraManager.swift`.

## Các bước thực hiện

1. Thêm state riêng `hasTapFocus` hoặc `focusControlState`; không dùng `focusPoint != nil` để suy ra hardware còn ở tap-focus.
2. UI focus indicator có thể tự ẩn, nhưng `hasTapFocus` vẫn true đến khi subject area change, unlock, flip hoặc focus mới.
3. `subjectAreaDidChange` guard theo `hasTapFocus || exposureBias != 0`, không theo indicator. Luôn restore continuous AF/AE khi cần.
4. Tạo helper cấu hình device trả `Result`, chạy trên sessionQueue rồi commit UI trên main actor.
5. `focus`: chỉ xác nhận state hardware sau lock thành công; failure rollback indicator/bias và báo lỗi ngắn.
6. `lockFocusAndExposure`: không set `isLocked = true` vĩnh viễn trước lock; failure trả state trước đó.
7. `setExposureBias`: chỉ cập nhật `lastPushedBias`/`exposureBias` sau khi device nhận config; failure rollback giá trị UI.
8. `setTorch`: chỉ đổi `torchOn` sau lock và sau khi đọc lại `device.torchMode`; failure giữ state cũ.
9. Zoom rollback dùng implementation PR 6.
10. Mọi completion cũ phải kiểm device ID/session revision để không rollback state của device mới.

## Tiêu chí nghiệm thu

- Ô focus ẩn rồi lia máy vẫn đưa camera về continuous AF/AE.
- Lock/config failure không để badge AE/AF, EV, zoom hoặc torch báo thành công giả.
- Flip trong lúc callback config cũ về không làm state camera mới nhảy lùi.

---

# PR 8 — Portrait không âm thầm degrade

**Bao phủ audit:** P2.9.

**File chính:** `CameraManagerCapture.swift`, `MediaProcessing.swift`, `CameraUI.swift`.

## Các bước thực hiện

1. Khi người dùng ở Portrait nhưng output chưa bật depth, không tạo pending `.normal` âm thầm. Báo “Depth chưa sẵn sàng” và cho retry sau reconfigure.
2. Đổi `PortraitRenderer.render` từ optional mơ hồ sang `Result<Data, PortraitRenderError>` hoặc throwing API.
3. Phân biệt: thiếu depth, convert disparity lỗi, mask lỗi, filter/render lỗi.
4. Với intensity `0`, trả nguyên `processed` data, không blur, không encode lại.
5. Với intensity > 0, radius/gain có thể scale từ 0 thay vì minimum 6/2. Kiểm tra mức thấp không tạo blur bắt buộc.
6. Nếu renderer lỗi, báo rõ. Chính sách đề xuất để không mất ảnh: vẫn lưu ảnh thường nhưng toast “Không tạo được xoá phông; đã lưu ảnh gốc”. Không được im lặng.
7. Snapshot intensity vào capture policy khi shutter; thay đổi slider sau đó không ảnh hưởng ảnh đang xử lý.

## Tiêu chí nghiệm thu

- Intensity 0 cho ảnh không blur.
- Depth/render fail luôn có thông báo.
- Ảnh gốc vẫn được bảo toàn theo chính sách đã chọn.

---

# PR 9 — Metadata scanner nghỉ thật và hiện đúng type

**Bao phủ audit:** P2.14.

**File chính:** `CameraManager.swift`, `CaptureTypes.swift`, `CameraUI.swift`.

## Các bước thực hiện

1. Tạo mapping đầy đủ: QR, EAN-13, EAN-8, Code 128, PDF417, Data Matrix.
2. Thêm `setMetadataScanningEnabled(_:)` chạy trên sessionQueue:
   - bật/tắt `metadataOutput.connection(with: .metadata)?.isEnabled` nếu API hỗ trợ;
   - hoặc set `metadataObjectTypes = []` khi nghỉ và restore danh sách supported khi bật.
3. Gọi helper khi setting đổi, bắt đầu preparing/recording, kết thúc recording, background/active.
4. Delegate vẫn giữ guard phòng thủ, nhưng không còn là cơ chế nghỉ duy nhất.
5. Khi set `scannedCode`, bọc mutation trong `withAnimation`; banner dùng transition đã khai báo.
6. Khi tắt scan, xóa banner hiện tại.

## Tiêu chí nghiệm thu

- Recording/off làm metadata connection ngừng xử lý.
- Banner hiện đúng tên từng symbology.
- Banner trượt thực sự khi xuất hiện/biến mất.

---

# PR 10 — Capture policy thống nhất và chốt orientation

**Bao phủ audit:** P2.15, P3.16 và độ bền metadata mục 17.

**File chính:** `CaptureTypes.swift`, `CameraManager.swift`, `CameraManagerCapture.swift`, `MediaProcessing.swift`, `func_req.md`.

## Thiết kế

Tạo `PhotoCapturePolicy` bất biến tại thời điểm shutter, gồm ít nhất: aspect, shouldCrop, format, live/depth/raw, orientation angle, mirror, portrait intensity và location snapshot. Lưu policy trong `PendingCapture`.

## Các bước thực hiện

> **Đây là bug, không phải việc dọn dẹp.** Hai nguồn hiện tại thật sự cho kết quả khác nhau
> ở một ca có thể chạm tới: Live Photo bật **và** EV ≠ 0 → capture đi đường AE bracket →
> bracket loại trừ Live Photo nên `liveMovie == nil` → `shouldCrop` trong `savePhoto` thành
> `true` → ảnh bị cắt về 16:9, trong khi `aspectCropSkipped` đã báo preview và dòng nhắc
> trong Cài đặt rằng ảnh sẽ ra 4:3. Người dùng nhận một tấm ảnh khác khung với cái họ ngắm.
> Vì vậy P2.15 phải được xử lý như lỗi kết quả sai, không phải hạng mục gọn gàng.

1. Viết một hàm duy nhất tạo policy từ settings + capability thực tế. Policy phải biết
   capture này có đi đường bracket hay không, vì bracket thay đổi cả live/raw/depth.
2. Preview `outputAspectRatio`, cảnh báo Settings và save path đều đọc cùng logic policy. Save không tự suy lại bằng `raw == nil && liveMovie == nil`.
2b. Thêm unit test (PR 0) cho ma trận: {HEIF, ProRAW} × {Live on, off} × {EV 0, EV ≠ 0} ×
   {4:3, 16:9, 1:1} → policy trả về `shouldCrop` và aspect nào. Đây là phần thuần logic,
   test được trên simulator.
3. Nếu AVFoundation hạ Live/RAW ở callback, cập nhật policy theo kết quả resolved nhưng qua một helper duy nhất.
4. Trước crop, kiểm `CGImageSourceGetCount`. Nếu HEIF có auxiliary image/gain map mà pipeline hiện không thể bảo toàn, không tuyên bố “giữ toàn bộ”; chọn một trong hai:
   - triển khai copy đầy đủ auxiliary data; hoặc
   - ghi rõ giới hạn và cảnh báo/fallback không crop.
5. Không fallback âm thầm từ HEIF sang JPEG khi mục tiêu là giữ định dạng. Nếu fallback cần thiết, báo/log lý do.
6. Chốt orientation bằng decision record:
   - **Khuyến nghị:** giữ `RotationCoordinator`, vì đúng theo hướng cầm máy và tốt hơn hard-code 90°; cập nhật §5 `func_req.md`.
   - Chỉ quay lại 90° nếu product owner thật sự yêu cầu mọi file luôn portrait.
7. Thêm test portrait/landscape cho ảnh, video, front mirror, crop 4:3/16:9/1:1.

## Tiêu chí nghiệm thu

- Preview và file dùng cùng một capture policy.
- Settings đổi sau shutter không làm đổi crop/intensity/location của ảnh đang xử lý.
- `func_req.md` và code orientation không còn mâu thuẫn.
- Không tuyên bố giữ gain map nếu thực tế bị mất.

---

# PR 11 — Quản lý temp artifact và bỏ URL scheme không được hỗ trợ

**Bao phủ audit:** P3.19, P3.20 và cleanup mục 20.

**File chính:** `CameraManager.swift`, `CameraManagerCapture.swift`, `MediaProcessing.swift`, `CameraUI.swift`; có thể thêm `TemporaryMediaStore.swift`.

## Các bước thực hiện

1. Tạo `TemporaryMediaStore` quản lý prefix/folder của app: `rec_`, `slomo_`, `timelapse_`, `live_`.
2. Mọi nơi tạo temp URL đi qua store; mỗi artifact có loại và ownership rõ ràng.
3. Chỉ xóa khi:
   - Photos xác nhận save thành công;
   - artifact đã được thay thế bởi output an toàn;
   - hoặc operation bị hủy và không cần recovery.
4. Live Photo save failure phải xóa paired movie nếu không có chiến lược retry; success với `shouldMoveFile` cũng xác nhận file không còn trước khi cleanup.
5. Time-lapse recorder xóa cả folder, không chỉ các file có trong mảng.
6. Khi app start, sweep artifact cũ quá ngưỡng, ví dụ 24 giờ. Không xóa file vừa tạo hoặc file được đánh dấu recoverable.
7. Với source slo-mo cần recovery, lưu metadata nhỏ hoặc giữ đến lần start sau; app có thể hỏi lưu fallback/retry.
8. Bỏ `photos-redirect://`.
9. Chọn giải pháp Apple-supported:
   - phương án tối thiểu, ít quyền: thumbnail mở preview full-screen nội bộ và share sheet;
   - nếu cần duyệt thư viện: dùng `PhotosPicker`;
   - nếu cần truy cập asset vừa tạo: xin quyền `.readWrite`, lưu `localIdentifier`, fetch bằng PhotoKit và hiển thị nội bộ.
10. Không dùng private/undocumented URL scheme khác để thay thế.

## Tiêu chí nghiệm thu

- Không còn chuỗi `photos-redirect://`.
- Save failure không xóa bản duy nhất của video.
- Restart app dọn được artifact cũ nhưng không xóa recovery đang chờ.
- Time-lapse không để folder rỗng.

---

## 4. Ma trận kiểm thử hồi quy — và phần không kiểm được

Dự án **không có máy thật** (§2.1). Ma trận dưới đây vì vậy chia làm hai: phần CI chạy
được, và phần phải hoãn. Phần hoãn **không được xoá** — nó là sổ nợ rủi ro, và là việc
đầu tiên phải làm nếu sau này có iPhone 13 Pro.

### Z. Những gì CI thực sự kiểm được

| Hạng mục | Cơ chế | Bao phủ audit |
|---|---|---|
| Toán duration/fps quay chậm, đặc biệt ca 239,76 | unit test (PR 0) | P0.2 |
| Hình học crop + orientation 5–8 + giữ metadata | unit test (PR 0) | P2.15, P3.16 |
| Ma trận capture policy (aspect × live × raw × EV) | unit test (PR 0) | P2.15 |
| Ghép time-lapse: thứ tự sequence, <2 frame, write lỗi, cleanup | unit test (PR 0) | P0.1, P3.19 |
| `CameraSettings` round-trip và fallback giá trị rác | unit test (PR 0) | mục 22 |
| Chọn max photo dimension theo diện tích | unit test (PR 0) | P3.17 |
| Toàn bộ code compile trên SDK iOS 26 | CI archive | tất cả |
| Không có API chọn triple/tele | grep §2.2 | invariant |

### Y. Những gì KHÔNG kiểm được — sổ nợ rủi ro

Mỗi PR bên trên có một mục "Test máy thật — HOÃN". Gom lại:

| Rủi ro tồn đọng | PR | Vì sao không thay thế được |
|---|---:|---|
| Ống tele 77 mm có thật sự im không | — | mục tiêu tối cao của app, chỉ tai người nghe được |
| Race mode/flip/shutter dưới stress 100 thao tác | 1 | không mô phỏng được timing phần cứng |
| Stop time-lapse đúng lúc capture đang bay | 2 | cần photo output thật |
| fps thật của phần cứng, duration clip ra | 3 | simulator không có format tốc độ cao |
| Chấm privacy mic, nhạc có bị cắt không | 4 | hành vi hệ thống, không quan sát được từ test |
| Background/active race, media-services reset | 5 | không kích hoạt được trong CI |
| Mirroring preview, chất lượng depth mask | 8 | cần camera thật |
| Gesture QuickTake sát ngưỡng 0,45 s | 4 | cần tay người |
| Cấu trúc asset ProRAW/Live Photo trong Photos | 6, 11 | cần thư viện Photos thật |

**Hệ quả với quyết định phát hành:** không có máy thật thì **không được coi bất kỳ PR nào là
đã xác minh hành vi**, chỉ là "đã sửa theo phân tích tĩnh + CI xanh". App không nên lên
TestFlight/App Store trước khi chạy hết mục Y trên một iPhone 13 Pro.

### A. Invariant camera/tele — HOÃN

- Camera sau Photo/Video/Portrait/Time-lapse dùng Dual Wide hoặc fallback Wide.
- Slo-mo dùng Wide 1×.
- Không có mốc 3×.
- Test 0,5×, 1×, 2×, pinch tới 5×.
- Quay video rồi nghe/quan sát xác nhận tele 77 mm không bị kích hoạt trên iPhone 13 Pro.

### B. Stress session — HOÃN

- 100 thao tác hỗn hợp mode/flip/zoom/shutter.
- Không có hai video input, không preview đen, không state UI sai.
- Background/active ở từng phase: idle, preparing, recording, finalizing, processing.

### C. Media — HOÃN

- Photo HEIF, ProRAW, Live Photo, Portrait 0/0,5/1.
- Video 1080p30/60, 4K30, front/rear, stereo.
- Slo-mo 120/240 và fallback; kiểm duration.
- Time-lapse 0,5/1/3 giây; stop khi capture đang bay; ít hơn 2 frame.

### D. Failure injection — HOÃN

- Từ chối mic/location/Photos.
- Thiếu dung lượng.
- `canAddInput`/format không hỗ trợ.
- Interruption và media-services reset.
- Photos save failure và export failure.

### E. Storage/privacy — HOÃN

- Mic indicator chỉ lúc quay có âm thanh.
- Location stale không được lưu.
- Không còn temp file sau success.
- File duy nhất luôn còn lại sau failure.

---

## 5. Definition of Done cho từng PR

Một PR chỉ hoàn thành khi có đủ:

- [ ] `swiftc -frontend -parse` trên toàn bộ file Swift: thành công.
- [ ] **CI `.github/workflows/build.yml` xanh** — gồm step unit test (từ PR 0) và step archive.
- [ ] `git diff --check` sạch.
- [ ] Review invariant chống tele theo §2.2.
- [ ] Logic mới thuộc diện test được (toán, hình học, thứ tự) **có unit test đi kèm trong cùng PR**.
- [ ] Không có `try?` mới ở đường lưu/export/config quan trọng nếu lỗi cần phản hồi.
- [ ] UI state chỉ được publish sau thành công hoặc có rollback rõ.
- [ ] Temp file có owner và cleanup ở success/failure/cancel.
- [ ] `func_req.md` được cập nhật nếu hành vi có chủ đích thay đổi.
- [ ] `AUDIT_REPORT.md` được đánh dấu lại, ghi rõ mức xác minh: **`static+CI`** (mặc định) hay
      `device` (chỉ khi thật sự chạy trên iPhone 13 Pro, kèm model máy/iOS).
- [ ] Mục "Test máy thật — HOÃN" của PR được chép vào sổ nợ §4.Y nếu có case mới.

> **Không có checkbox "test máy thật" trong DoD**, vì không có máy. Đổi lại, DoD bắt buộc
> phải ghi nhận mức xác minh thật sự đạt được — một PR đóng ở mức `static+CI` là hợp lệ,
> nhưng không được nói hay hiểu là đã kiểm chứng hành vi.

## 6. Bảng truy vết đủ 20 mục ưu tiên của audit

Cột cuối ghi mức xác minh **cao nhất đạt được mà không có máy thật**. `device` nghĩa là
mục đó chỉ đóng được bằng sổ nợ §4.Y.

| Audit | PR xử lý | Bằng chứng đạt được ngay | Mức |
|---|---:|---|---|
| P0.1 Time-lapse drain/generation/backpressure | 2 | unit test thứ tự sequence, <2 frame, write lỗi, cleanup | `static+CI` một phần; stress stop là `device` |
| P0.2 Slo-mo CMTime/fps | 3 | unit test toán duration, ca 239,76 | `static+CI` |
| P0.3 Không xóa source khi export lỗi | 3, 11 | unit test nhánh export lỗi giữ file | `static+CI` |
| P0.4 Serialize mode/flip/shutter/zoom | 1 | review state machine + CI | `device` |
| P1.5 Mic/audio đúng thời điểm | 4 | review: `applyMode` không còn `wantsMic` | `device` |
| P1.6 Lifecycle generation | 5 | review generation guard | `device` |
| P1.7 Location lifecycle/quality | 5 | unit test `validatedLocation(at:)` | `static+CI` |
| P1.8 Capability sau commit/sessionQueue | 1, 6 | grep: không đọc `session.inputs/outputs` ngoài queue | `static+CI` |
| P2.9 Portrait failure/intensity 0 | 8 | unit test intensity 0 trả nguyên data | `static+CI`; chất lượng mask là `device` |
| P2.10 Restore continuous AF/AE | 7 | review `hasTapFocus` tách khỏi indicator | `device` |
| P2.11 Rollback device UI state | 7 | review đường `Result` + rollback | `device` |
| P2.12 Zoom stops theo device | 6 | unit test filter stops theo min/max | `static+CI` |
| P2.13 Video fps negotiation | 6 | unit test chọn format theo fps | `static+CI` |
| P2.14 Scanner nghỉ/type/animation | 9 | unit test mapping symbology → nhãn | `static+CI`; quét thật là `device` |
| P2.15 Aspect source of truth | 10 | unit test ma trận policy (gồm ca Live+EV) | `static+CI` |
| P3.16 Orientation decision | 10 | spec cập nhật + unit test hình học crop | `static+CI` |
| P3.17 Max dimensions theo diện tích | 6 | unit test helper chọn theo diện tích | `static+CI` |
| P3.18 ProRAW codec fallback | 6 | review nhánh fallback codec | `device` |
| P3.19 Temp artifact cleanup/recovery | 2, 3, 11 | unit test sweep + cleanup theo nhánh lỗi | `static+CI` |
| P3.20 Bỏ undocumented Photos URL | 11 | `git grep photos-redirect` không còn kết quả | `static+CI` |

**Đọc bảng này thế nào:** 13/20 mục đóng được thật sự bằng CI + unit test. 7 mục còn lại —
gần như toàn bộ nhóm race và lifecycle — chỉ "sửa theo phân tích", chưa kiểm chứng. Đó
chính xác là lý do §4.Y tồn tại.

## 7. Ước lượng và mốc phát hành

Ước lượng dưới đây là cho chế độ **không có máy thật**: viết code + unit test + CI, không
có vòng test thủ công trên iPhone.

- PR 0: 2–3 ngày (dựng test target, tách logic thuần, sửa CI).
- PR 1: 3–5 ngày.
- PR 2: 4–6 ngày.
- PR 3: 2–3 ngày.
- PR 4: 3–4 ngày.
- PR 5: 3–4 ngày.
- PR 6–7: 4–6 ngày.
- PR 8–10: 4–6 ngày.
- PR 11: 2–3 ngày.

Tổng: khoảng **4–6 tuần** cho một junior, hoặc **2–3 tuần** nếu AI viết code và một dev có
kinh nghiệm review. Bỏ vòng test máy thật không làm nhanh hơn đáng kể, vì phần lớn thời
gian nằm ở việc viết đúng và ở PR 0.

### Mốc phát hành

| Mốc | Gồm | Trạng thái xác minh |
|---|---|---|
| Nội bộ / dev build | PR 0–3 | `static+CI` — sửa xong nhóm mất dữ liệu |
| Ứng viên beta | PR 0–7 | `static+CI` |
| **TestFlight / App Store** | PR 0–11 **+ chạy hết §4.Y trên iPhone 13 Pro** | `device` |

**Chốt lại rõ ràng:** không có mốc phát hành nào đạt được chỉ bằng CI. Sổ nợ §4.Y phải
được trả trước khi app đến tay người dùng thật — kể cả khi mọi PR đã xanh. Nếu không bao
giờ có máy thật, thì mốc cuối cùng khả thi là "beta cho chính người sở hữu máy tự dùng và
tự báo lỗi", không phải App Store.
