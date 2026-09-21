//
//  CameraManager.swift
//  NoTeleCamera — Giai đoạn 3 (bản vá nhóm "chụp ảnh & quay video")
//
//  Lõi điều khiển: session, ống kính, zoom, lấy nét, các chế độ ghi hình.
//  Phần chụp ảnh nằm ở CameraManager_Capture.swift.
//
//  SỬA SO VỚI BẢN TRƯỚC (11 mục):
//   1. Dựng AVCapturePhotoSettings ngay trên sessionQueue, đọc cờ thật của
//      photoOutput tại đó → không còn bắn exception khi cờ đổi giữa chừng.
//   2. isConfiguring chặn start() chạy hai lần trong lúc đang xin quyền.
//   3. Watchdog + willBeginCaptureFor/didFinishCaptureFor → nút chụp không
//      còn kẹt vĩnh viễn khi một mảnh dữ liệu không bao giờ về.
//   4. Không chụp khi session chưa chạy (gián đoạn, cuộc gọi đến).
//   5. Hướng ảnh/video lấy từ AVCaptureDevice.RotationCoordinator thay vì
//      ép cứng 90°.
//   6. Mic gắn khi VÀO chế độ quay, không gắn lúc bấm nút → hết khựng và
//      hết mất tiếng ở đầu video.
//   7. Báo cho VolumeShutter tạm nghỉ quanh lúc đổi audio category.
//   9. QuickTake có thời lượng tối thiểu 1 giây.
//  10. Thumbnail video dựng bất đồng bộ, không chặn main thread.
//  11. Burst có backpressure: tối đa 4 ảnh đang bay, nhịp 120ms.
//
//  (8 nằm trong CameraUI.swift — VolumeShutter.)
//
 
import AVFoundation
import CoreLocation
import CoreMotion
import Photos
import SwiftUI
 
extension Notification.Name {
    /// Phát ngay trước khi app đổi AVAudioSession category. VolumeShutter
    /// nghe cái này để bỏ qua cú nhảy outputVolume do việc đổi category gây
    /// ra — nếu không, chuyển sang playAndRecord lúc bắt đầu quay sẽ bị hiểu
    /// là một lần bấm phím âm lượng và dừng quay ngay lập tức.
    static let cameraAudioSessionWillChange = Notification.Name("NoTeleCamera.audioSessionWillChange")
}
 
@MainActor
final class CameraManager: NSObject, ObservableObject {
 
    // MARK: Trạng thái hiển thị
 
    @Published var settings = CameraSettings()
    @Published var displayZoom: CGFloat = 1.0
    @Published var torchOn = false
    @Published var exposureBias: Float = 0.0
    @Published var isLocked = false
    @Published var lastThumbnail: UIImage?
    @Published var focusPoint: CGPoint?
    @Published var isCapturing = false
    /// Tăng mỗi lần bấm máy thật sự (kể cả burst) để UI bắn hiệu ứng nháy
    /// trắng như Camera gốc — không dùng isCapturing vì nó giữ true suốt
    /// quá trình xử lý, còn nháy thì chỉ cần một cái chớp ngay lúc bấm.
    @Published var shutterFlashTrigger = 0
    @Published var isFront = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    /// fps thực sự đang được cấu hình trên camera ở chế độ quay chậm, `nil`
    /// nếu camera hiện tại không quay chậm được.
    ///
    /// Tách khỏi `settings.slomoRate` vì hai thứ khác nhau: `slomoRate` là mức
    /// người dùng CHỌN và được lưu lại, còn đây là mức máy CHẤP NHẬN. Camera
    /// trước thường chỉ đạt 120fps; nếu hạ luôn `slomoRate` rồi `save()` thì
    /// lật về camera sau vẫn kẹt 120fps dù ống đó chạy được 240fps.
    /// Hệ số kéo giãn thời gian lúc xuất video phải lấy theo giá trị này.
    @Published private(set) var activeSlomoFps: Double?

    /// Góc xoay áp cho ảnh và video, lấy từ RotationCoordinator.
    /// Ép cứng 90° như bản cũ làm ảnh chụp ngang bị gắn hướng dọc.
    @Published var captureRotationAngle: CGFloat = 90
 
    // Ghi hình
    @Published var isRecording = false
    @Published var isQuickTake = false
    @Published var recordDuration: TimeInterval = 0
    @Published var isProcessing = false          // đang xuất slo-mo / tua nhanh
    @Published var timeLapseFrames = 0
 
    // Hẹn giờ & burst
    @Published var countdown = 0
    @Published var isBursting = false
    @Published var burstCount = 0
 
    // Thước thăng bằng
    @Published var rollAngle: Double = 0
    @Published var isLevel = false
    @Published var orientationAngle: Double = 0
    /// 1 = hiện rõ, 0 = tắt. Mờ dần khi máy chúc lên/xuống quá nhiều.
    @Published var levelPitchFade: Double = 1
 
    // Quét mã
    @Published var scannedCode: ScannedCode?
 
    // Khả năng của máy — dùng để ẩn/hiện nút trên UI
    @Published var supportsProRAW = false
    @Published var supportsLivePhoto = false
    @Published var supportsDepth = false
    @Published var supportsMacro = false
 
    /// Live Photo và movie output loại trừ nhau. Khi Live Photo đang bật ở chế
    /// độ Ảnh thì QuickTake không dùng được — UI cần biết để không hiểu nhầm.
    @Published var quickTakeAvailable = true

    /// True khi `movieOutput` thực sự có mặt trong session ngay sau lần commit
    /// gần nhất — chỉ được gán từ `applyMode`, sau khi cấu hình đã chốt. Chỗ
    /// nào cần biết có quay được không (ví dụ `startRecording`) đọc cờ này
    /// thay vì hỏi thẳng `session.outputs` từ main actor.
    private(set) var movieOutputAttached = false
 
    // MARK: Chuyển chế độ

    /// Session đang được tái cấu hình sau khi đổi chế độ (applyMode) — từ lúc
    /// gọi cho đến khi commitConfiguration, reset zoom và gắn/gỡ mic xong hết.
    /// UI dựa vào cờ này để giữ hiệu ứng mờ trên preview cho đến khi camera
    /// thật sự sẵn sàng chụp/quay, rồi mới cho lớp mờ tan ra.
    @Published var isModeTransitioning = false

    /// Session đang ở giữa một transaction cấu hình CHƯA CHỐT.
    ///
    /// Tách hẳn khỏi `isModeTransitioning`: cờ kia chỉ điều khiển lớp mờ trên
    /// preview và được watchdog nhả sau 2 giây để preview không kẹt mờ. Cờ này
    /// là cổng thao tác thật, chỉ đóng lại khi transaction thực sự xong. Gộp
    /// hai thứ làm một nghĩa là hễ cấu hình chạy quá 2 giây — lần đầu bật
    /// camera trước, máy nóng — watchdog lại mở cổng cho shutter/QuickTake/zoom
    /// chạm vào một session còn đang thiếu input, đúng thứ lớp cổng này sinh ra
    /// để chặn.
    @Published private(set) var sessionBusy = false

    /// Số thứ tự của lần chuyển chế độ đang chạy. Người dùng có thể bấm mode
    /// kế tiếp trong lúc lần trước chưa xong — completion của lần cũ không
    /// được nhả cờ của lần mới.
    private var modeTransitionGeneration = 0

    /// Watchdog: nếu completion vì lý do nào đó không chạy (session bị gián
    /// đoạn, lỗi...), cờ phải tự nhả sau hạn này để preview không kẹt mờ.
    private var modeTransitionWatchdog: Task<Void, Never>?
 
    // MARK: Thành phần AVFoundation
 
    nonisolated let session = AVCaptureSession()
    nonisolated let sessionQueue = DispatchQueue(label: "camera.session")

    nonisolated let photoOutput = AVCapturePhotoOutput()
    nonisolated let movieOutput = AVCaptureMovieFileOutput()
    private nonisolated let metadataOutput = AVCaptureMetadataOutput()
 
    private(set) var videoInput: AVCaptureDeviceInput?
 
    /// Cờ đặt ngay trên main actor. Bản cũ gán `audioInput` trong một
    /// Task @MainActor lồng trong sessionQueue, nên QuickTake quay 1 giây thì
    /// detachAudio chạy lúc nó còn nil → mic không bao giờ được gỡ.
    private var audioAttached = false
    var device: AVCaptureDevice? { videoInput?.device }
 
    private var baseFactor: CGFloat = 1.0
    private let maxDisplayZoom: CGFloat = 5.0
 
    /// Format gốc của camera sau, để khôi phục sau khi thoát chế độ quay chậm.
    private var defaultFormat: AVCaptureDevice.Format?
 
    /// Đã dựng session lần nào chưa — tránh dựng lại khi app quay lại từ nền.
    private var isConfigured = false
 
    /// Đang trong quá trình dựng session. `isConfigured` chỉ được bật ở CUỐI
    /// configureSession, sau một chuỗi await xin quyền; nếu app vào nền rồi
    /// quay lại trong khoảng đó, start() sẽ chạy lần hai → addInput trùng,
    /// observer trùng, settings bị load() đè.
    private var isConfiguring = false
 
    /// Observer session chỉ được đăng ký đúng một lần cho cả vòng đời.
    private var didObserveSession = false
 
    /// Đang đợi file quay ghi xong rồi mới tắt session (app vào nền giữa lúc quay).
    private var stopSessionAfterRecording = false
 
    private var notificationTokens: [NSObjectProtocol] = []
 
    // Hướng máy
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
 
    // MARK: Phụ trợ
 
    private let locationManager = CLLocationManager()
    private let motionManager = CMMotionManager()
    private var recordTimer: Timer?
    private var recordStartedAt: Date?
    private var countdownTask: Task<Void, Never>?
    private var focusHideTask: Task<Void, Never>?
    private var burstTask: Task<Void, Never>?
    private var timeLapseTask: Task<Void, Never>?
    private var quickTakeMinimumTask: Task<Void, Never>?
    private let timeLapseRecorder = TimeLapseRecorder()
 
    /// Bộ nhớ tạm gom các phần của một lần chụp (ảnh thường + RAW + Live Photo).
    var pendingCaptures: [Int64: PendingCapture] = [:]
 
    /// Hẹn giờ cứu hộ cho từng lần chụp. Nếu một mảnh dữ liệu không bao giờ
    /// về (Live Photo bị hệ thống huỷ vì nóng máy / thiếu bộ nhớ / rung quá
    /// mạnh) thì entry nằm lại mãi và nút chụp chết. Watchdog dọn giúp.
    var captureWatchdogs: [Int64: Task<Void, Never>] = [:]
 
    /// Số lần chụp đã gửi đi mà chưa kết thúc. Vừa để mở/khoá nút chụp, vừa
    /// làm backpressure cho burst.
    var capturesInFlight = 0
 
    /// Thời lượng tối thiểu của một đoạn QuickTake. Thả tay sớm hơn thì chờ
    /// cho đủ, không thì thư viện đầy video 0,01 giây.
    private let quickTakeMinimumDuration: TimeInterval = 1.0
 
    var currentLocation: CLLocation? { locationManager.location }
 
    // MARK: - Vòng đời
 
    func start() {
        // Quay lại từ nền: session đã dựng rồi, chỉ cần chạy tiếp.
        guard !isConfigured else {
            sessionQueue.async { [weak self] in
                guard let self, !self.session.isRunning else { return }
                self.session.startRunning()
            }
            // Áp lại chế độ: mic của chế độ quay đã bị gỡ lúc vào nền.
            applyMode(settings.mode)
            startMotion()
            return
        }
 
        // Chặn lần gọi thứ hai chen vào giữa lúc đang xin quyền.
        guard !isConfiguring else { return }
        isConfiguring = true
 
        settings = CameraSettings.load()
        if !didObserveSession {
            didObserveSession = true
            observeSession()
        }
 
        Task {
            guard await requestCameraPermission() else {
                isConfiguring = false
                errorMessage = "Chưa được cấp quyền camera. Vào Cài đặt để bật."
                return
            }
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            locationManager.requestWhenInUseAuthorization()
            locationManager.startUpdatingLocation()
 
            let startMode = settings.mode
            let startLivePhotoOn = settings.livePhotoOn
            sessionQueue.async { [weak self] in
                self?.configureSession(startMode: startMode, startLivePhotoOn: startLivePhotoOn)
                self?.session.startRunning()
            }
            startMotion()
        }
    }
 
    func stop() {
        stopMotion()
        cancelCountdown()
        burstEnded()
        // Việc bấm dở trước khi vào nền không còn nghĩa gì lúc quay lại.
        pendingMode = nil
        pendingReconfigure = false
 
        // Đang quay: dừng ghi trước, đợi delegate ghi xong file rồi mới tắt
        // session. Tắt ngay sẽ làm hỏng file.
        if isRecording {
            stopSessionAfterRecording = true
            stopRecording()
            return
        }
 
        // Trả mic và trả audio session về ambient khi rời màn hình.
        detachAudio()
 
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }
 
    private func requestCameraPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }
 
    // MARK: - Hướng máy
 
    /// iOS 17 có sẵn bộ theo dõi hướng cho camera. Dùng nó thay cho việc ép
    /// `videoRotationAngle = 90`: app khoá dọc nên `interfaceOrientation`
    /// luôn là portrait, còn người dùng thì vẫn xoay máy để chụp ngang.
    private func startRotationCoordinator(for device: AVCaptureDevice) {
        rotationObservation?.invalidate()
        let coord = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coord
        captureRotationAngle = coord.videoRotationAngleForHorizonLevelCapture
        rotationObservation = coord.observe(
            \.videoRotationAngleForHorizonLevelCapture, options: [.new]
        ) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            Task { @MainActor in self?.captureRotationAngle = angle }
        }
    }
 
    // MARK: - Gián đoạn & lỗi runtime
 
    /// Cuộc gọi đến, app khác chiếm camera, hoặc media services bị reset đều
    /// làm preview đen vĩnh viễn nếu không xử lý.
    private func observeSession() {
        let nc = NotificationCenter.default
 
        notificationTokens.append(
            nc.addObserver(forName: .AVCaptureSessionRuntimeError,
                           object: session, queue: .main) { [weak self] note in
                let err = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
                let code = err?.code
                let text = err?.localizedDescription ?? "không rõ"
                Task { @MainActor in
                    guard let self else { return }
                    // Lỗi runtime giữa chừng cũng bỏ rơi mọi lần chụp đang bay.
                    self.abortAllCaptures()
                    if code == .mediaServicesWereReset {
                        self.sessionQueue.async {
                            if !self.session.isRunning { self.session.startRunning() }
                        }
                    } else {
                        self.errorMessage = "Camera gặp lỗi: \(text)"
                    }
                }
            }
        )
 
        notificationTokens.append(
            nc.addObserver(forName: .AVCaptureSessionWasInterrupted,
                           object: session, queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
                Task { @MainActor in
                    guard let self else { return }
                    if self.isRecording { self.stopRecording() }
                    self.abortAllCaptures()
                    if let reason = raw.flatMap({ AVCaptureSession.InterruptionReason(rawValue: $0) }) {
                        switch reason {
                        case .videoDeviceInUseByAnotherClient:
                            self.statusMessage = "Camera đang được app khác dùng."
                        case .audioDeviceInUseByAnotherClient:
                            self.statusMessage = "Mic đang được app khác dùng."
                        case .videoDeviceNotAvailableWithMultipleForegroundApps:
                            self.statusMessage = "Camera tạm dừng khi chia đôi màn hình."
                        default:
                            self.statusMessage = "Camera tạm bị gián đoạn."
                        }
                    } else {
                        self.statusMessage = "Camera tạm bị gián đoạn."
                    }
                }
            }
        )
 
        notificationTokens.append(
            nc.addObserver(forName: .AVCaptureSessionInterruptionEnded,
                           object: session, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.statusMessage = nil
                    self.sessionQueue.async {
                        if !self.session.isRunning { self.session.startRunning() }
                    }
                }
            }
        )

        // object: nil vì device đổi mỗi lần lật camera trước/sau, không gắn cứng
        // được một object lúc đăng ký. Lọc lại trong handler để không ăn thông
        // báo của thiết bị khác (ví dụ camera vừa bị gỡ khỏi session).
        notificationTokens.append(
            nc.addObserver(forName: AVCaptureDevice.subjectAreaDidChangeNotification,
                           object: nil, queue: .main) { [weak self] note in
                let sender = note.object as? AVCaptureDevice
                Task { @MainActor in
                    guard let self, sender === self.device else { return }
                    self.subjectAreaDidChange()
                }
            }
        )
    }
 
    deinit {
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
        rotationObservation?.invalidate()
    }
 
    /// Gom các công tắc quyết định độ trễ màn trập. Phải gọi lại sau MỖI lần
    /// cấu hình session vì bật Live Photo hoặc depth sẽ làm chúng hết được hỗ
    /// trợ, và AVFoundation không tự bật lại khi tắt hai thứ đó đi.
    ///
    /// • zeroShutterLag: máy giữ sẵn một vòng đệm khung hình và lấy các khung
    ///   TRƯỚC thời điểm bấm. Không có nó thì máy mới bắt đầu gom khung SAU khi
    ///   bấm — tay đã nhấc lên, ảnh nhoè, phải đứng yên vài giây mới được ảnh nét.
    ///   Đây là thứ làm app gốc chụp "bấm là xong".
    /// • responsiveCapture: cho phép trả về ngay và xử lý ở nền, chụp liên tiếp
    ///   không phải chờ ảnh trước xử lý xong. Yêu cầu zeroShutterLag đã bật.
    /// • fastCapturePrioritization: tự hạ chất lượng khi người dùng bấm liên
    ///   tục. Yêu cầu responsiveCapture đã bật.
    private nonisolated static func tuneForLowLatency(_ output: AVCapturePhotoOutput) {
        if output.isZeroShutterLagSupported {
            output.isZeroShutterLagEnabled = true
        }
        if output.isResponsiveCaptureSupported {
            output.isResponsiveCaptureEnabled = true
            if output.isFastCapturePrioritizationSupported {
                output.isFastCapturePrioritizationEnabled = true
            }
        }
    }

    // MARK: - Chọn camera phù hợp chế độ

    /// Chọn camera phù hợp cho từng chế độ:
    /// - Camera trước luôn là .builtInWideAngleCamera.
    /// - Camera sau ở chế độ quay chậm (Slo-mo) PHẢI dùng .builtInWideAngleCamera
    ///   vì camera ảo .builtInDualWideCamera không hỗ trợ các định dạng tốc độ cao
    ///   (120/240 fps). Ống 1x này hoàn toàn không cấp điện cho ống tele, đúng tôn chỉ NoTele.
    /// - Camera sau ở các chế độ khác ưu tiên .builtInDualWideCamera để dùng được 0.5x
    ///   siêu rộng và macro mà vẫn chặn triệt để ống tele.
    ///
    /// `nonisolated` vì `configureSession` chạy ngoài main actor và mọi nhánh
    /// gọi còn lại đều nằm trong khối `sessionQueue.async`.
    nonisolated static func bestDevice(for mode: CaptureMode, isFront: Bool) -> AVCaptureDevice? {
        if isFront {
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        }
        if mode == .slomo {
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        }
        return AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    // MARK: - Dựng session
 
    private nonisolated func configureSession(startMode: CaptureMode, startLivePhotoOn: Bool) {
        session.beginConfiguration()
        session.sessionPreset = .photo
 
        // ★★★ ĐIỂM MẤU CHỐT ★★★
        // builtInDualWideCamera = [ống siêu rộng 0.5x + ống chính 1x].
        // Thiết bị ảo này KHÔNG chứa ống tele, nên OIS tele không bao giờ
        // được cấp điện — đây là lý do tồn tại của cả app.
        // Riêng chế độ quay chậm cần camera vật lý builtInWideAngleCamera để có 120/240fps.
        let cam = Self.bestDevice(for: startMode, isFront: false)
 
        guard let cam,
              let input = try? AVCaptureDeviceInput(device: cam),
              session.canAddInput(input) else {
            session.commitConfiguration()
            Task { @MainActor in
                self.isConfiguring = false
                self.errorMessage = "Không mở được camera."
            }
            return
        }
        session.addInput(input)
 
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        // .balanced thay vì .quality: .quality cho phép hệ thống kéo dài cửa sổ
        // gom khung hình (Night mode phơi sáng dài) nên ảnh dễ nhoè nếu tay
        // chưa kịp đứng yên. .balanced vẫn giữ Deep Fusion / Smart HDR nhưng
        // chặn trần thời gian — đây cũng là mặc định của AVCapturePhotoOutput.
        photoOutput.maxPhotoQualityPrioritization = .balanced
        if let maxDim = cam.activeFormat.supportedMaxPhotoDimensions.last {
            photoOutput.maxPhotoDimensions = maxDim
        }
        Self.tuneForLowLatency(photoOutput)
 
        // ProRAW — chỉ có trên máy Pro. Phải bật ở output trước khi dùng.
        let proRAW = photoOutput.isAppleProRAWSupported
        if proRAW { photoOutput.isAppleProRAWEnabled = true }
 
        // Đọc khả năng Live Photo và depth TRƯỚC khi thêm movie output, vì
        // movie output sẽ che mất chúng. Việc bật/tắt để applyMode lo.
        let livePhoto = photoOutput.isLivePhotoCaptureSupported
        let depth = photoOutput.isDepthDataDeliverySupported
 
        // Movie output thêm sẵn để QuickTake không phải dựng lại session,
        // TRỪ KHI chế độ khởi động đã cần Live Photo/Depth — hai thứ này
        // không sống chung được với movie output. Thêm rồi để applyMode gỡ
        // ngay sau startRunning() sẽ cấu hình lại một session đang chạy,
        // gây nháy hình preview và đôi khi làm AVFoundation renegotiate lại
        // activeFormat, reset videoZoomFactor về 0.5x (ống siêu rộng).
        let needsPhotoOnlyAtStart = (startMode == .photo && startLivePhotoOn && livePhoto)
            || (startMode == .portrait && depth)
        if !needsPhotoOnlyAtStart, session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
 
        // Quét mã QR / mã vạch.
        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
            let wanted: [AVMetadataObject.ObjectType] = [.qr, .ean13, .ean8, .code128, .pdf417, .dataMatrix]
            metadataOutput.metadataObjectTypes = wanted.filter {
                metadataOutput.availableMetadataObjectTypes.contains($0)
            }
        }
 
        session.commitConfiguration()
 
        let switchOver = CGFloat(cam.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue ?? 1.0)
        try? cam.lockForConfiguration()
        cam.videoZoomFactor = switchOver
        if cam.isSubjectAreaChangeMonitoringEnabled == false {
            cam.isSubjectAreaChangeMonitoringEnabled = true
        }
        cam.unlockForConfiguration()
 
        // Máy có ống siêu rộng thì mới có macro (13 Pro lấy nét gần bằng ống này).
        let hasUltraWide = cam.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        let format = cam.activeFormat
 
        Task { @MainActor in
            self.videoInput = input
            self.baseFactor = switchOver
            self.displayZoom = 1.0
            self.defaultFormat = format
            self.supportsProRAW = proRAW
            self.supportsLivePhoto = livePhoto
            self.supportsDepth = depth
            self.supportsMacro = hasUltraWide
            self.isConfigured = true
            self.isConfiguring = false
            self.startRotationCoordinator(for: cam)
            // Áp chế độ đã ghi nhớ — gọi ở đây để chắc chắn chạy sau khi
            // videoInput đã được gán.
            self.applyMode(self.settings.mode)
        }
    }
 
    // MARK: - Audio session
 
    /// Chỉ chuyển sang playAndRecord khi thật sự cần mic. Ngoài ra để ambient
    /// để không cắt nhạc người dùng đang nghe và không giữ mic.
    ///
    /// Phát notification trước khi đổi: đổi category làm `outputVolume` nhảy
    /// (ringer volume ↔ media volume), mà VolumeShutter đang nghe đúng giá trị
    /// đó và sẽ hiểu nhầm là một lần bấm phím chụp.
    private nonisolated static func setAudioSession(recording: Bool) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .cameraAudioSessionWillChange, object: nil)
        }
        let s = AVAudioSession.sharedInstance()
        if recording {
            try? s.setCategory(.playAndRecord, mode: .videoRecording,
                               options: [.defaultToSpeaker, .allowBluetooth])
        } else {
            try? s.setCategory(.ambient, options: [.mixWithOthers])
        }
        try? s.setActive(true, options: .notifyOthersOnDeactivation)
    }
 
    /// Gắn mic. Gọi khi VÀO chế độ quay, không phải lúc bấm nút ghi: tái cấu
    /// hình session lúc đang chạy làm luồng hình khựng một nhịp và mic cần
    /// vài trăm mili giây mới ổn định — đó là lý do đoạn đầu video hay mất
    /// tiếng hoặc giật.
    ///
    /// `onDone` được gọi trên main actor khi mọi thứ đã xong (kể cả trường
    /// hợp không có gì phải gắn) — applyMode dùng nó để biết chính xác lúc
    /// nào camera sẵn sàng hoàn toàn.
    private func attachAudioIfNeeded(onDone: (() -> Void)? = nil) {
        guard !audioAttached else { Task { @MainActor in onDone?() } ; return }
        audioAttached = true
        sessionQueue.async { [weak self] in
            guard let self else { return }
            Self.setAudioSession(recording: true)
            guard let mic = AVCaptureDevice.default(for: .audio),
                  let input = try? AVCaptureDeviceInput(device: mic) else {
                Task { @MainActor in onDone?() }
                return
            }
            self.session.beginConfiguration()
            if self.session.canAddInput(input) {
                self.session.addInput(input)
                // AVFoundation mặc định thu mono; phải xin stereo rõ ràng (iOS 18+).
                #if compiler(>=6.0)
                if #available(iOS 18.0, *) {
                    if input.isMultichannelAudioModeSupported(.stereo) {
                        input.multichannelAudioMode = .stereo
                    }
                }
                #endif
            }
            self.session.commitConfiguration()
            Task { @MainActor in onDone?() }
        }
    }
 
    /// Gỡ mọi input âm thanh đang có trong session. Lấy session làm nguồn sự
    /// thật thay vì giữ tham chiếu riêng, và vì hai hàm này cùng chạy trên
    /// sessionQueue nối tiếp nên thứ tự gắn-rồi-gỡ luôn đúng.
    ///
    /// `onDone` được gọi trên main actor khi mọi thứ đã xong (kể cả trường
    /// hợp không có gì phải gỡ).
    func detachAudio(onDone: (() -> Void)? = nil) {
        guard audioAttached else { Task { @MainActor in onDone?() } ; return }
        audioAttached = false
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            for input in self.session.inputs {
                if let di = input as? AVCaptureDeviceInput, di.device.hasMediaType(.audio) {
                    self.session.removeInput(di)
                }
            }
            self.session.commitConfiguration()
            Self.setAudioSession(recording: false)
            Task { @MainActor in onDone?() }
        }
    }
 
    // MARK: - Cổng thao tác

    /// Đổi mode, flip, chụp, QuickTake và zoom đều đụng chung `session`/device
    /// đang cấu hình dở dang. Bấm chồng các thao tác này lên nhau là nguồn của
    /// phần lớn race đã ghi trong audit (hai video input, chụp trên camera đã
    /// bị gỡ, QuickTake báo sẵn sàng dù movie output chưa kịp thêm). Đây là
    /// nơi DUY NHẤT quyết định một thao tác có được phép chạy ngay bây giờ
    /// không — volume shutter và mọi lối gọi trực tiếp khác cũng phải qua đây,
    /// không chỉ nút bấm trên UI.
    enum CameraAction {
        case changeMode, flip, shutter, quickTake, zoom, reconfigure
        /// Chạm lấy nét, kéo EV — chỉnh trực tiếp trên device đang dùng. Không
        /// dựng lại session nhưng vẫn `lockForConfiguration` lên đúng cái
        /// device mà `applyMode`/`flipCamera` có thể đang tráo.
        case deviceTweak
    }

    func canPerform(_ action: CameraAction) -> Bool {
        switch action {
        case .changeMode:
            // KHÔNG xét `sessionBusy` ở đây: đang bận thì `setMode` vẫn nhận
            // và giữ lại thành `pendingMode`, chứ không vứt thao tác đi.
            return !isRecording && !isProcessing && !isBursting
        case .flip, .reconfigure:
            // `isBursting` phải có mặt ở cả hai: dựng lại session giữa một mẻ
            // chụp liên tiếp là mẻ đó mất cấu hình giữa chừng, đúng lý do
            // `setMode` đã chặn burst.
            return !isRecording && !isProcessing && !isBursting && !sessionBusy
        case .shutter, .zoom, .deviceTweak:
            return !sessionBusy
        case .quickTake:
            return !sessionBusy && !isRecording && !isBursting
        }
    }

    // MARK: - Đổi chế độ

    /// Chế độ cuối cùng người dùng chọn trong lúc một lần chuyển chế độ khác
    /// còn đang chạy dở. Chỉ giữ ĐÚNG MỘT giá trị — bấm liên tiếp trong lúc
    /// đang transitioning không xếp hàng vô hạn, chỉ mode cuối cùng được áp
    /// sau khi lần hiện tại xong.
    private var pendingMode: CaptureMode?

    /// Có một `reconfigure()` bị hoãn vì session đang bận. Mọi chỗ gọi
    /// `reconfigure()` đều đã `settings.save()` TRƯỚC khi gọi, nên bỏ qua yêu
    /// cầu là để settings và session nói hai chuyện khác nhau — nút Live Photo
    /// sáng lên trong khi movie output vẫn còn nguyên trong session.
    private var pendingReconfigure = false

    func setMode(_ new: CaptureMode) {
        guard new != settings.mode, canPerform(.changeMode) else { return }
        // Đang chuyển chế độ dở dang: không chen ngang vào giữa transaction
        // session hiện tại, chỉ ghi nhớ để áp ngay khi nó xong. Xét
        // `sessionBusy` chứ không phải lớp mờ — lớp mờ có thể đã tan vì
        // watchdog trong khi cấu hình vẫn đang chạy.
        guard !sessionBusy else {
            pendingMode = new
            return
        }
        pendingMode = nil
        settings.mode = new
        settings.save()
        if new != .video && new != .slomo { setTorch(false) }
        applyMode(new)
    }

    /// Dựng lại session cho những thay đổi KHÔNG kèm đổi chế độ — bật/tắt Live
    /// Photo, đổi chất lượng video. Trước đây các chỗ này gọi setMode với chính
    /// chế độ hiện tại nên bị guard chặn và không có tác dụng gì.
    func reconfigure() {
        if canPerform(.reconfigure) {
            applyMode(settings.mode)
            return
        }
        // Không chạy được ngay. Chỉ kẹt vì session đang bận — tức bỏ
        // `sessionBusy` ra thì cổng mở — thì giữ lại và áp khi transaction hiện
        // tại xong. Kẹt vì đang quay / đang xuất file / đang chụp liên tiếp thì
        // bỏ hẳn: hoãn sang lúc đó là dựng lại session giữa việc khác.
        if !isRecording, !isProcessing, !isBursting { pendingReconfigure = true }
    }

    private func applyMode(_ mode: CaptureMode) {
        // Lấy device trên main actor TRƯỚC khi nhảy sang sessionQueue.
        // Bản cũ dùng MainActor.assumeIsolated bên trong sessionQueue, mà
        // assumeIsolated trap khi không thực sự ở main actor → crash.
        guard let dev = device else { return }

        // Đánh dấu bắt đầu một lần chuyển chế độ: UI mở hiệu ứng mờ trên
        // preview và giữ cho đến khi completion của CHÍNH lần này chạy xong.
        let transitionGen = beginModeTransition()
 
        let quality = settings.videoQuality
        let slomo = settings.slomoRate
        // isFront cũng phải chốt ở đây. Đọc self.isFront bên trong
        // sessionQueue là đọc state của main actor từ luồng nền — trình biên
        // dịch không chặn vì closure của DispatchQueue.async thừa kế isolation
        // một cách tĩnh, nhưng nó vẫn chạy ngoài main actor.
        let front = isFront
        let wantsDepth = (mode == .portrait) && supportsDepth
        let wantsLive = (mode == .photo) && settings.livePhotoOn && supportsLivePhoto
        let defFormat = defaultFormat
        // Mic chuẩn bị sẵn cho hai chế độ quay có tiếng.
        let wantsMic = (mode == .video || mode == .slomo)
 
        // quickTakeAvailable/movieOutputAttached KHÔNG được gán ở đây nữa —
        // đó là dự đoán trước khi cấu hình thật sự chạy. Nếu addOutput
        // movieOutput bên dưới thất bại thì UI vẫn tưởng QuickTake dùng được.
        // Cả hai chỉ được gán trong Task@MainActor sau commitConfiguration,
        // đọc thẳng từ session.outputs thật.
        // Rời quay chậm thì mức fps đã đo được không còn ý nghĩa.
        if mode != .slomo { activeSlomoFps = nil }

        // Macro chỉ sống ở chế độ Ảnh, camera sau. Rời khỏi đó mà không tắt thì
        // `autoFocusRangeRestriction = .near` còn nguyên trên device và mọi chế
        // độ sau đều lấy nét ở dải gần — nhìn như camera hỏng lấy nét.
        if settings.macroOn && (mode != .photo || front) {
            settings.macroOn = false
            settings.save()
            applyMacroIfNeeded()
        }
 
        sessionQueue.async { [weak self] in
            guard let self else { return }

            // Input video đang thực sự nằm trong session, hỏi thẳng session
            // chứ không đọc self.videoInput: thuộc tính đó chỉ được gán trong
            // Task @MainActor ở cuối hàm, không đồng bộ với sessionQueue. Bấm
            // hai chế độ liên tiếp là lần chạy sau đọc trúng input cũ →
            // removeInput một input không còn trong session rồi addInput
            // device thứ hai → session có hai video input và hỏng cấu hình.
            let currentInput = self.session.inputs
                .compactMap { $0 as? AVCaptureDeviceInput }
                .first { $0.device.hasMediaType(.video) }

            var activeDev = currentInput?.device ?? dev
            var swappedInput: AVCaptureDeviceInput?

            self.session.beginConfiguration()

            // Đổi camera nếu chế độ yêu cầu (ví dụ: quay chậm cần camera vật lý góc rộng 1x
            // thay vì camera ảo dual wide).
            if let targetDev = Self.bestDevice(for: mode, isFront: front),
               targetDev.uniqueID != activeDev.uniqueID,
               let newInput = try? AVCaptureDeviceInput(device: targetDev) {
                if let currentInput { self.session.removeInput(currentInput) }
                if self.session.canAddInput(newInput) {
                    self.session.addInput(newInput)
                    activeDev = targetDev
                    swappedInput = newInput
                } else if let currentInput {
                    self.session.addInput(currentInput)
                }
            }

            switch mode {
            case .slomo:
                // Quay chậm cần chọn activeFormat riêng → preset phải là inputPriority.
                if let (fmt, actualFps) = Self.bestHighFrameRateFormat(for: activeDev, preferredFps: slomo.fps) {
                    self.session.sessionPreset = .inputPriority
                    try? activeDev.lockForConfiguration()
                    activeDev.activeFormat = fmt
                    let d = CMTime(value: 1, timescale: CMTimeScale(actualFps))
                    activeDev.activeVideoMinFrameDuration = d
                    activeDev.activeVideoMaxFrameDuration = d
                    activeDev.unlockForConfiguration()

                    Task { @MainActor in
                        self.activeSlomoFps = actualFps
                        // Chỉ báo cho người dùng biết máy đang chạy mức thấp
                        // hơn mức đã chọn. KHÔNG sửa và lưu settings.slomoRate:
                        // camera trước chỉ 120fps, hạ luôn mức đã lưu thì lật
                        // về camera sau vẫn kẹt 120fps.
                        // So sánh có dung sai: phần cứng hay khai 239,76 fps
                        // cho mức 240, đó không phải là bị hạ mức.
                        if slomo.fps - actualFps > 1.0 {
                            self.statusMessage = "Camera này chỉ quay chậm được ở mức \(Int(actualFps.rounded())) fps."
                        }
                    }
                } else {
                    Task { @MainActor in
                        self.activeSlomoFps = nil
                        self.errorMessage = "Camera này không hỗ trợ quay chậm (yêu cầu tối thiểu 120 fps)."
                    }
                }

            case .video, .timelapse:
                // Khôi phục format gốc nếu vừa thoát quay chậm.
                //
                // Điều kiện formats.contains không thừa: quay chậm ở camera
                // SAU chạy trên builtInWideAngleCamera, còn defaultFormat là
                // format của builtInDualWideCamera — ép format của device này
                // sang device kia là AVFoundation ném exception. Nhánh này
                // thực chất chỉ còn cần cho camera TRƯỚC, nơi cả hai chế độ
                // dùng chung một device nên activeFormat thật sự bị bẩn.
                if let defFormat, activeDev.formats.contains(defFormat), activeDev.activeFormat != defFormat {
                    try? activeDev.lockForConfiguration()
                    activeDev.activeFormat = defFormat
                    activeDev.unlockForConfiguration()
                }
                let preset = (mode == .video) ? quality.preset : AVCaptureSession.Preset.hd1920x1080
                // Gán lại preset dù giá trị không đổi (vd. video→timelapse
                // cùng 1080p) vẫn khiến AVFoundation renegotiate và nháy
                // hình vô ích — chỉ gán khi thực sự khác.
                if self.session.sessionPreset != preset, self.session.canSetSessionPreset(preset) {
                    self.session.sessionPreset = preset
                }
                if mode == .video { Self.applyFrameRate(quality.fps, to: activeDev) }

            case .photo, .portrait:
                if let defFormat, activeDev.formats.contains(defFormat), activeDev.activeFormat != defFormat {
                    try? activeDev.lockForConfiguration()
                    activeDev.activeFormat = defFormat
                    activeDev.unlockForConfiguration()
                }
                // Photo↔portrait giữ nguyên preset .photo — tránh gán lại để
                // khỏi renegotiate không cần thiết.
                if self.session.sessionPreset != .photo, self.session.canSetSessionPreset(.photo) {
                    self.session.sessionPreset = .photo
                }
            }
 
            // Live Photo VÀ depth đều không sống chung với movie output.
            // Bản cũ chỉ gỡ movie output cho Live Photo, nên ở chế độ Chân
            // dung isDepthDataDeliverySupported trả về false, nhánh bật depth
            // bị bỏ qua im lặng và ảnh ra y hệt ảnh thường.
            let needsPhotoOnly = wantsLive || wantsDepth
            let hasMovie = self.session.outputs.contains(self.movieOutput)
            if needsPhotoOnly {
                if hasMovie { self.session.removeOutput(self.movieOutput) }
            } else if !hasMovie, self.session.canAddOutput(self.movieOutput) {
                self.session.addOutput(self.movieOutput)
            }
 
            // Hạ responsive capture TRƯỚC khi bật Live Photo: hai thứ này loại
            // trừ nhau, bật Live Photo trong lúc responsive còn bật là
            // AVFoundation ném exception chứ không trả lỗi. tuneForLowLatency ở
            // cuối khối sẽ bật lại nếu lúc đó vẫn còn được hỗ trợ.
            if self.photoOutput.isFastCapturePrioritizationEnabled {
                self.photoOutput.isFastCapturePrioritizationEnabled = false
            }
            if self.photoOutput.isResponsiveCaptureEnabled {
                self.photoOutput.isResponsiveCaptureEnabled = false
            }

            if self.photoOutput.isLivePhotoCaptureSupported {
                self.photoOutput.isLivePhotoCaptureEnabled = wantsLive
            }
 
            // Depth chỉ bật ở chế độ Chân dung — bật thừa sẽ giới hạn format.
            if self.photoOutput.isDepthDataDeliverySupported {
                self.photoOutput.isDepthDataDeliveryEnabled = wantsDepth
            }
 
            // activeFormat có thể vừa đổi (quay chậm ↔ thường) nên kích thước
            // ảnh tối đa phải đọc lại, nếu không chụp ở format mới sẽ lỗi.
            if let maxDim = activeDev.activeFormat.supportedMaxPhotoDimensions.last {
                self.photoOutput.maxPhotoDimensions = maxDim
            }

            // Bật/tắt Live Photo và depth làm thay đổi khả năng hỗ trợ của
            // zero shutter lag / responsive capture, nên phải chốt lại mỗi lần
            // cấu hình — nếu không, thoát Live Photo xong là mất ZSL vĩnh viễn.
            Self.tuneForLowLatency(self.photoOutput)
 
            self.session.commitConfiguration()

            // Nguồn sự thật cho quickTakeAvailable: đọc THẲNG session ngay
            // sau khi commit, không suy từ `wantsLive`/`wantsDepth` — nếu
            // addOutput(movieOutput) phía trên thất bại vì lý do nào đó thì
            // hai biến kia vẫn nói "sẽ có movie output" trong khi thực tế không.
            let movieAttached = self.session.outputs.contains(self.movieOutput)

            // Đổi chế độ ảnh ↔ video có thể khiến AVFoundation renegotiate
            // activeFormat và tự ý đặt lại videoZoomFactor (thường về mức
            // 0,5x của ống siêu rộng). Ép lại về mốc 1x ngay tại đây để zoom
            // hiển thị luôn về 1.0 sau khi chuyển chế độ, không kẹt ở 0.5.
            let switchOver = CGFloat(activeDev.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue ?? 1.0)
            try? activeDev.lockForConfiguration()
            activeDev.videoZoomFactor = switchOver
            if activeDev.isSubjectAreaChangeMonitoringEnabled == false {
                activeDev.isSubjectAreaChangeMonitoringEnabled = true
            }
            activeDev.unlockForConfiguration()

            Task { @MainActor in
                self.movieOutputAttached = movieAttached
                // QuickTake cần cả movie output thật sự có mặt LẪN đang ở chế
                // độ Ảnh — Live Photo bật thì movie output đã bị gỡ ở trên nên
                // `movieAttached` tự nhiên là false, không cần kiểm wantsLive.
                self.quickTakeAvailable = movieAttached && (mode == .photo)
                if let swappedInput {
                    self.videoInput = swappedInput
                    self.startRotationCoordinator(for: activeDev)
                    // Chỉ macro phụ thuộc device cụ thể: ống 1x đơn không có
                    // ống siêu rộng nên không macro được.
                    //
                    // KHÔNG đọc lại supportsLivePhoto / supportsDepth /
                    // supportsProRAW ở đây. Lúc này movieOutput đã nằm trong
                    // session và nó che mất isLivePhotoCaptureSupported cùng
                    // isDepthDataDeliverySupported (xem configureSession và
                    // flipCamera — cả hai đều gỡ movieOutput ra trước khi đọc).
                    // Đọc ở đây là nhận false, khiến nút Live Photo biến mất
                    // và chế độ Chân dung mất depth vĩnh viễn sau một vòng
                    // vào/ra quay chậm. Ba cờ này là năng lực của VỊ TRÍ
                    // camera, chỉ đổi khi lật trước/sau — flipCamera đã lo.
                    self.supportsMacro = activeDev.constituentDevices.contains {
                        $0.deviceType == .builtInUltraWideCamera
                    }
                    // Đổi device là mọi trạng thái gắn với device cũ hết hiệu
                    // lực: torchMode là thuộc tính của từng AVCaptureDevice nên
                    // device mới luôn khởi đầu ở .off, còn EV/khoá AE-AF thì
                    // thuộc về ống kính cũ.
                    self.exposureBias = 0
                    self.lastPushedBias = 0
                    self.isLocked = false
                    self.focusPoint = nil
                    if self.torchOn {
                        if activeDev.hasTorch { self.setTorch(true) } else { self.torchOn = false }
                    }
                }
                self.baseFactor = switchOver
                self.applyMacroIfNeeded()
                self.displayZoom = 1.0
                if wantsMic {
                    self.attachAudioIfNeeded {
                        self.finishModeTransition(generation: transitionGen)
                    }
                } else if !self.isRecording {
                    self.detachAudio {
                        self.finishModeTransition(generation: transitionGen)
                    }
                } else {
                    self.finishModeTransition(generation: transitionGen)
                }
            }
        }
    }
 
    // MARK: Hiệu ứng chuyển chế độ

    /// Bắt đầu một lần chuyển chế độ: đóng CẢ HAI cờ — lớp mờ cho UI
    /// (`isModeTransitioning`) và cổng thao tác (`sessionBusy`) — rồi hẹn
    /// watchdog hai nhịp đề phòng completion bị mất (session bị gián đoạn,
    /// lỗi...). Trả về số thứ tự của lần này để completion đối chiếu khi gọi
    /// `finishModeTransition`.
    private func beginModeTransition() -> Int {
        modeTransitionGeneration += 1
        let gen = modeTransitionGeneration
        isModeTransitioning = true
        sessionBusy = true
        // Hẹn giờ đang đếm thuộc về cấu hình cũ. Để nguyên thì lúc nó về 0,
        // `capturePhoto` lại bị chính cổng này chặn im lặng — người dùng đợi
        // hết giờ và không có tấm ảnh nào, cũng không có lời báo nào.
        cancelCountdown()
        modeTransitionWatchdog?.cancel()
        modeTransitionWatchdog = Task { [weak self] in
            // Nhịp 1 — chỉ nhả LỚP MỜ. Cấu hình rất có thể vẫn đang chạy trên
            // sessionQueue (lần đầu bật camera trước, máy nóng), nên tuyệt đối
            // không mở cổng thao tác ở đây.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.releaseModeBlur(generation: gen)

            // Nhịp 2 — quá hạn này thì coi như completion đã mất hẳn. Mở cổng
            // để app không kẹt vĩnh viễn, nhưng báo lỗi và BỎ `pendingMode`:
            // watchdog không có quyền coi cấu hình là đã thành công.
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.abandonModeTransition(generation: gen)
        }
        return gen
    }

    /// Nhả lớp mờ trên preview, KHÔNG động tới cổng thao tác.
    private func releaseModeBlur(generation: Int) {
        guard generation == modeTransitionGeneration else { return }
        isModeTransitioning = false
    }

    /// Completion coi như mất hẳn. Mở cổng để app còn dùng được, nhưng nói rõ
    /// là đã hỏng chứ không im lặng như thể mọi thứ ổn.
    private func abandonModeTransition(generation: Int) {
        guard generation == modeTransitionGeneration else { return }
        modeTransitionWatchdog = nil
        isModeTransitioning = false
        sessionBusy = false
        pendingMode = nil
        pendingReconfigure = false
        errorMessage = "Camera không phản hồi khi đổi chế độ. Thử lại."
    }

    /// Nhả cờ chuyển chế độ — chỉ lần chuyển MỚI NHẤT mới có quyền nhả, để
    /// người dùng bấm mode kế tiếp trong lúc lần trước chưa xong không bị lần
    /// cũ làm tắt hiệu ứng sớm.
    private func finishModeTransition(generation: Int) {
        guard generation == modeTransitionGeneration else { return }
        modeTransitionWatchdog?.cancel()
        modeTransitionWatchdog = nil
        isModeTransitioning = false
        sessionBusy = false
        // Chỉ đường này — completion THẬT của transaction — mới được áp việc
        // đang chờ. Watchdog không, vì nó không biết cấu hình đã xong hay chưa.
        if let next = pendingMode, next != settings.mode {
            pendingMode = nil
            // setMode dựng lại session đầy đủ, nuốt luôn phần reconfigure.
            pendingReconfigure = false
            setMode(next)
            return
        }
        pendingMode = nil
        if pendingReconfigure {
            pendingReconfigure = false
            reconfigure()
        }
    }

    /// Tìm format hỗ trợ tốc độ cao, ưu tiên độ phân giải lớn nhất ở mức fps đó.
    private nonisolated static func highFrameRateFormat(for dev: AVCaptureDevice, fps: Double) -> AVCaptureDevice.Format? {
        dev.formats
            .filter { fmt in
                fmt.videoSupportedFrameRateRanges.contains {
                    $0.minFrameRate <= fps && $0.maxFrameRate >= (fps - 1.0)
                }
            }
            .max { a, b in
                let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                return Int(da.width) * Int(da.height) < Int(db.width) * Int(db.height)
            }
    }

    /// fps cao nhất mà format thực sự chạy được, nhưng không vượt mức yêu cầu.
    ///
    /// `highFrameRateFormat` nhận cả format có `maxFrameRate` thấp hơn mức yêu
    /// cầu một chút (239,xx cho yêu cầu 240) vì phần cứng hay khai báo lẻ.
    /// Nhưng `activeVideoMinFrameDuration` thì KHÔNG khoan dung: gán giá trị
    /// nằm ngoài dải của activeFormat là AVFoundation ném NSInvalidArgumentException
    /// chứ không trả lỗi — tức là crash. Nên phải kẹp lại theo dải thật.
    private nonisolated static func achievableFps(_ fmt: AVCaptureDevice.Format, requested: Double) -> Double {
        let maxReal = fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? requested
        return min(requested, maxReal)
    }

    /// Tìm format tốc độ cao tốt nhất cho thiết bị, tự động hạ từ 240fps xuống
    /// 120fps nếu thiết bị chỉ hỗ trợ 120fps.
    private nonisolated static func bestHighFrameRateFormat(for dev: AVCaptureDevice, preferredFps: Double) -> (format: AVCaptureDevice.Format, actualFps: Double)? {
        if let fmt = highFrameRateFormat(for: dev, fps: preferredFps) {
            return (fmt, achievableFps(fmt, requested: preferredFps))
        }
        if preferredFps > 120, let fmt = highFrameRateFormat(for: dev, fps: 120) {
            return (fmt, achievableFps(fmt, requested: 120))
        }
        return nil
    }
 
    private nonisolated static func applyFrameRate(_ fps: Double, to dev: AVCaptureDevice) {
        guard (try? dev.lockForConfiguration()) != nil else { return }
        let ok = dev.activeFormat.videoSupportedFrameRateRanges.contains {
            fps >= $0.minFrameRate && fps <= $0.maxFrameRate
        }
        if ok {
            let d = CMTime(value: 1, timescale: CMTimeScale(fps))
            dev.activeVideoMinFrameDuration = d
            dev.activeVideoMaxFrameDuration = d
        }
        dev.unlockForConfiguration()
    }
 
    // MARK: - Macro
 
    /// 13 Pro chụp macro bằng ống siêu rộng lấy nét gần.
    /// Bật macro = ép về 0,5× và giới hạn dải lấy nét về phía gần.
    func setMacro(_ on: Bool) {
        // Tắt thì luôn cho qua (setZoom gọi vào đây để huỷ macro khi zoom ra).
        // Bật thì phải đúng chỗ — xem `macroAvailable`. Công tắc trong Cài đặt
        // là lối duy nhất còn lại để bật macro, nên chốt chặn phải ở đây chứ
        // không chỉ ở điều kiện hiển thị của UI.
        guard !on || macroAvailable else { return }
        settings.macroOn = on
        settings.save()
        if on { setZoom(0.5) }
        applyMacroIfNeeded()
    }
 
    private func applyMacroIfNeeded() {
        // Không chặn theo `supportsMacro`: đường TẮT cũng đi qua đây, mà máy
        // không hỗ trợ macro thì cũng phải gỡ được `.near` nếu nó đã bị đặt.
        guard let device else { return }
        let on = settings.macroOn && macroAvailable
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = on ? .near : .none
            }
            device.unlockForConfiguration()
        }
    }
 
    // MARK: - Đổi camera trước / sau
 
    func flipCamera() {
        guard canPerform(.flip), videoInput != nil else { return }
        let goingFront = !isFront
        let mode = settings.mode

        // Mở cổng transitioning NGAY từ đây — bản cũ chỉ mở nó ở applyMode
        // cuối hàm, nên suốt lúc removeInput/addInput đang chạy dở, gate vẫn
        // cho shutter/QuickTake/zoom lọt qua và có thể chạm vào một session
        // đang thiếu video input.
        let transitionGen = beginModeTransition()

        // Tắt torch của camera đang rời đi trước, không đổi isFront ở đây —
        // isFront chỉ được gán SAU khi camera mới thật sự vào session, để
        // flip thất bại không để icon/mirror hiện sai trạng thái.
        setTorch(false)
        // Ảnh đang bay thuộc về camera cũ — bỏ hết, đừng để kẹt nút chụp.
        abortAllCaptures()

        sessionQueue.async { [weak self] in
            guard let self else { return }

            // Không dùng videoInput đọc trên main actor trước khi vào hàng
            // đợi: nếu một applyMode khác vừa được enqueue trước flip trên
            // cùng sessionQueue, input thật trong session lúc block này chạy
            // có thể đã khác input mà main actor thấy lúc gọi flipCamera().
            // Hỏi thẳng session, giống cách applyMode đã làm.
            guard let currentInput = self.session.inputs
                .compactMap({ $0 as? AVCaptureDeviceInput })
                .first(where: { $0.device.hasMediaType(.video) }) else {
                Task { @MainActor in self.finishModeTransition(generation: transitionGen) }
                return
            }

            let newCam = Self.bestDevice(for: mode, isFront: goingFront)
            guard let newCam, let newInput = try? AVCaptureDeviceInput(device: newCam) else {
                Task { @MainActor in
                    self.errorMessage = "Không mở được camera."
                    self.finishModeTransition(generation: transitionGen)
                }
                return
            }

            self.session.beginConfiguration()
            self.session.removeInput(currentInput)
            guard self.session.canAddInput(newInput) else {
                // Rollback đầy đủ: giữ nguyên input cũ, không đụng tới bất kỳ
                // state UI nào (isFront/videoInput/capability vẫn của camera cũ).
                self.session.addInput(currentInput)
                self.session.commitConfiguration()
                Task { @MainActor in
                    self.errorMessage = "Không chuyển được camera."
                    self.finishModeTransition(generation: transitionGen)
                }
                return
            }
            self.session.addInput(newInput)

            // Movie output che mất isLivePhotoCaptureSupported và
            // isDepthDataDeliverySupported, nên phải gỡ ra trước khi đọc
            // khả năng của camera mới. applyMode bên dưới sẽ gắn lại nếu cần.
            if self.session.outputs.contains(self.movieOutput) {
                self.session.removeOutput(self.movieOutput)
            }

            let proRAW = self.photoOutput.isAppleProRAWSupported
            if proRAW { self.photoOutput.isAppleProRAWEnabled = true }
            let livePhoto = self.photoOutput.isLivePhotoCaptureSupported
            let depth = self.photoOutput.isDepthDataDeliverySupported
            let hasUltraWide = newCam.constituentDevices.contains {
                $0.deviceType == .builtInUltraWideCamera
            }

            if let maxDim = newCam.activeFormat.supportedMaxPhotoDimensions.last {
                self.photoOutput.maxPhotoDimensions = maxDim
            }
            self.session.commitConfiguration()

            let switchOver = CGFloat(newCam.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue ?? 1.0)
            try? newCam.lockForConfiguration()
            newCam.videoZoomFactor = switchOver
            if newCam.isSubjectAreaChangeMonitoringEnabled == false {
                newCam.isSubjectAreaChangeMonitoringEnabled = true
            }
            newCam.unlockForConfiguration()

            let newFormat = newCam.activeFormat

            Task { @MainActor in
                // Từ đây trở xuống cấu hình mới ĐÃ commit thành công — giờ
                // mới là lúc an toàn để đổi state UI.
                self.isFront = goingFront
                self.videoInput = newInput
                self.baseFactor = switchOver
                self.displayZoom = 1.0
                self.exposureBias = 0
                self.lastPushedBias = 0
                self.isLocked = false
                self.focusPoint = nil
                // Camera trước có bộ format riêng — defaultFormat cũ không còn
                // đúng, giữ lại sẽ làm applyMode ép nhầm format.
                self.defaultFormat = newFormat

                // Khả năng của hai camera khác nhau; giữ giá trị đọc từ camera
                // sau sẽ làm UI hiện nút cho thứ camera trước không có.
                self.supportsProRAW = proRAW
                self.supportsLivePhoto = livePhoto
                self.supportsDepth = depth
                self.supportsMacro = hasUltraWide

                if goingFront && self.settings.macroOn {
                    self.settings.macroOn = false
                    self.settings.save()
                }

                self.startRotationCoordinator(for: newCam)

                // Preset, format, Live Photo, depth đều phải áp lại cho camera
                // mới — bản cũ giữ nguyên cấu hình của camera cũ. applyMode tự
                // mở một generation transitioning mới và sẽ đóng sổ nó khi
                // xong; generation của flip (transitionGen) không cần tự đóng
                // vì chưa từng gọi finishModeTransition ở nhánh thành công.
                self.applyMode(self.settings.mode)
            }
        }
    }
 
    // MARK: - Zoom
 
    func setZoom(_ target: CGFloat) {
        // Đang đổi mode/camera thì `device`/`baseFactor` có thể đang giữa lúc
        // đổi — từ chối và giữ nguyên UI thay vì áp zoom lên device sắp đổi.
        guard canPerform(.zoom), let device else { return }
        let minDisplay = device.minAvailableVideoZoomFactor / baseFactor
        let hardMax = device.maxAvailableVideoZoomFactor / baseFactor
        let clamped = min(max(target, minDisplay), min(maxDisplayZoom, hardMax))
 
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            device.videoZoomFactor = clamped * self.baseFactor
            device.unlockForConfiguration()
        }
        displayZoom = clamped
 
        // Zoom ra khỏi 0,5× thì macro không còn ý nghĩa.
        if settings.macroOn && clamped > 0.6 { setMacro(false) }
    }
 
    func pinchZoom(scale: CGFloat, from initial: CGFloat) {
        setZoom(initial * scale)
    }
 
    /// Các mốc zoom. Không bao giờ có 3× — đó là ống tele.
    var zoomStops: [CGFloat] {
        if isFront { return [1.0] }
        if settings.mode == .portrait || settings.mode == .slomo { return [1.0, 2.0] }
        return [0.5, 1.0, 2.0]
    }

    /// Tỉ lệ rộng/cao của khung file THẬT SỰ ghi ra khi cầm máy dọc. UI khoá
    /// khung preview theo số này để mắt thấy đúng vùng ảnh/video sẽ có.
    ///
    /// Ba nhánh dưới đây phải khớp với đường ghi file:
    ///  • mọi chế độ quay (video / quay chậm / tua nhanh) đều ghi ở 16:9 —
    ///    tỉ lệ khung đang chọn trong Cài đặt không áp cho video;
    ///  • Live Photo và ProRAW không cắt được (xem `savePhoto` trong
    ///    CameraManagerCapture), nên ảnh vẫn ra 4:3 dù người dùng chọn khung
    ///    khác — preview phải đứng cùng chỗ với file, đừng hứa hão.
    var outputAspectRatio: CGFloat {
        if settings.mode.isRecordingMode { return 9.0 / 16.0 }
        if aspectCropSkipped { return 3.0 / 4.0 }
        return settings.aspect.value
    }

    /// `savePhoto` có bỏ qua bước cắt tỉ lệ không — nguồn sự thật DUY NHẤT cho
    /// quy tắc "Live Photo / ProRAW ⇒ ảnh vẫn ra 4:3". Khung preview, nút tỉ lệ
    /// trên thanh trên và dòng nhắc trong Cài đặt đều đọc từ đây, để ba chỗ
    /// không trôi khỏi nhau.
    var aspectCropSkipped: Bool {
        guard settings.mode == .photo else { return false }
        if settings.livePhotoOn, supportsLivePhoto { return true }
        if settings.photoFormat == .proRAW, supportsProRAW { return true }
        return false
    }

    /// Vì sao khung đang chọn chưa áp được — `nil` khi khung đang chọn đúng là
    /// khung file sẽ ghi ra (kể cả trường hợp bị khoá nhưng vốn đã chọn 4:3).
    var aspectCropSkippedReason: String? {
        guard aspectCropSkipped, settings.aspect != .r4x3 else { return nil }
        if settings.livePhotoOn, supportsLivePhoto {
            return "Live Photo đang bật nên ảnh vẫn lưu ở 4:3: cắt tỉ lệ sẽ phá cặp Live Photo. Tắt Live Photo nếu muốn khung \(settings.aspect.rawValue)."
        }
        return "ProRAW đang bật nên ảnh vẫn lưu ở 4:3: cắt tỉ lệ không áp được cho RAW. Chuyển định dạng về HEIF nếu muốn khung \(settings.aspect.rawValue)."
    }

    /// Macro chỉ có nghĩa ở ống siêu rộng của camera sau, chế độ Ảnh (§9).
    ///
    /// Phải kiểm cả `mode`, không chỉ `supportsMacro`. `supportsMacro` là năng
    /// lực của DEVICE: ở Video và Tua nhanh vẫn là thiết bị kép nên nó còn
    /// `true`, và chỉ dựa vào nó thì macro bật thật giữa lúc quay. Ở Quay chậm
    /// thì device có được tráo sang ống 1× và cờ được đọc lại, nhưng phải chờ
    /// hết vòng cấu hình bất đồng bộ của `applyMode` — trong khoảng đó cờ vẫn
    /// là giá trị cũ.
    var macroAvailable: Bool {
        supportsMacro && !isFront && settings.mode == .photo
    }

    // MARK: - Lấy nét & phơi sáng

    /// Bao nhiêu point vuốt dọc thì EV đổi 1 nấc.
    ///
    /// Trước đây đặt 33 để mặt trời bám đầu ngón tay 1:1 trên đường ray của
    /// `FocusIndicatorView`. Nhưng đường ray chỉ dài 132 point, nên vuốt hết
    /// ±2 EV chỉ tốn 132 point — nhích tay một chút là EV nhảy cả nấc, chỉnh
    /// không trúng. Camera gốc không buộc icon bám tay: icon đi trên đoạn ray
    /// ngắn, còn ngón tay phải đi quãng dài hơn nhiều.
    ///
    /// 90 point/nấc → hết dải ±2 EV tốn 360 point, cỡ nửa chiều cao preview.
    /// Muốn chậm hơn nữa thì tăng số này.
    static let evDragPointsPerStop: CGFloat = 90

    func focus(at devicePoint: CGPoint, uiPoint: CGPoint) {
        // `device` ở đây có thể là cái sắp bị `applyMode`/`flipCamera` tráo —
        // khoá cấu hình lên nó giữa chừng là chỉnh lấy nét cho ống đã rời đi.
        guard canPerform(.deviceTweak), let device else { return }
        focusPoint = uiPoint
        isLocked = false
        // Camera gốc trả EV về 0 mỗi lần chạm điểm mới — giữ lại mức cũ sẽ làm
        // icon mặt trời hiện ra đã lệch sẵn dù người dùng chưa vuốt gì.
        exposureBias = 0
        lastPushedBias = 0

        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            if device.isSubjectAreaChangeMonitoringEnabled == false {
                device.isSubjectAreaChangeMonitoringEnabled = true
            }
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = devicePoint
                device.focusMode = device.isFocusModeSupported(.autoFocus) ? .autoFocus : .continuousAutoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = device.isExposureModeSupported(.autoExpose) ? .autoExpose : .continuousAutoExposure
            }
            device.setExposureTargetBias(0, completionHandler: nil)
            device.unlockForConfiguration()
        }

        // Mỗi lần chạm trước đây sinh một Task hẹn 1,5 giây riêng, không ai
        // huỷ ai — chạm lần hai thì hẹn giờ của lần một vẫn chạy và xoá ô vàng
        // sớm. Nay chỉ giữ đúng một hẹn giờ.
        scheduleFocusHide()
    }

    /// Giữ ô vàng trên màn hình trong lúc người dùng còn đang vuốt chỉnh EV.
    func keepFocusAlive() {
        focusHideTask?.cancel()
    }

    func scheduleFocusHide(after seconds: Double = 3.5) {
        focusHideTask?.cancel()
        focusHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, !self.isLocked else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                self.focusPoint = nil
            }
        }
    }

    // MARK: Vuốt dọc cạnh ô vàng để chỉnh EV

    /// Mức EV lúc đặt ngón tay xuống; nil nghĩa là không có cử chỉ nào đang chạy.
    private var exposureDragStart: Float?

    func beginExposureDrag() {
        guard focusPoint != nil else { return }
        exposureDragStart = exposureBias
        keepFocusAlive()
    }

    /// `translationY` là độ dịch dọc của ngón tay tính từ lúc đặt xuống —
    /// âm là vuốt lên (sáng hơn).
    func updateExposureDrag(translationY: CGFloat) {
        guard let start = exposureDragStart else { return }
        let delta = Float(-translationY / Self.evDragPointsPerStop)
        // Làm tròn về nấc 0,05 EV: mắt không phân biệt nổi mà số lần đẩy
        // xuống sessionQueue giảm hẳn.
        let stepped = (round((start + delta) / 0.05) * 0.05)
        setExposureBias(stepped)
        keepFocusAlive()
    }

    func endExposureDrag() {
        guard exposureDragStart != nil else { return }
        exposureDragStart = nil
        // Đếm giờ ẩn ô vàng chỉ bắt đầu sau khi nhấc ngón tay ra.
        scheduleFocusHide()
    }


    /// Tự động trả về lấy nét liên tục và ẩn khung vàng khi lia máy sang cảnh mới
    func subjectAreaDidChange() {
        guard !isLocked else { return }
        // Đang vuốt chỉnh EV thì đừng giật ô vàng khỏi tay người dùng.
        guard exposureDragStart == nil else { return }
        guard focusPoint != nil || exposureBias != 0 else { return }

        focusHideTask?.cancel()
        lastPushedBias = 0
        withAnimation(.easeOut(duration: 0.25)) {
            focusPoint = nil
            exposureBias = 0
        }

        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            guard (try? device.lockForConfiguration()) != nil else { return }
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.setExposureTargetBias(0, completionHandler: nil)
            device.unlockForConfiguration()
        }
    }

    func lockFocusAndExposure(at devicePoint: CGPoint, uiPoint: CGPoint) {
        guard let device else { return }
        focusHideTask?.cancel()
        focusPoint = uiPoint
        isLocked = true

        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = devicePoint }
            if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = devicePoint }
            if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
            device.unlockForConfiguration()
        }
    }

    func unlock() {
        guard let device else { return }
        focusHideTask?.cancel()
        exposureDragStart = nil
        isLocked = false
        exposureBias = 0
        lastPushedBias = 0
        // Mờ dần như mọi đường ẩn ô vàng khác, thay vì biến mất đột ngột.
        withAnimation(.easeOut(duration: 0.25)) {
            focusPoint = nil
        }
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5) }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.setExposureTargetBias(0, completionHandler: nil)
            device.unlockForConfiguration()
        }
    }
 
    /// Giá trị EV gần nhất đã thực sự đẩy xuống thiết bị. Vuốt liên tục bắn ra
    /// hàng trăm sự kiện, phần lớn cùng một mức sau khi làm tròn — chặn ở đây
    /// để không dồn ứ sessionQueue.
    private var lastPushedBias: Float = 0

    func setExposureBias(_ value: Float) {
        guard canPerform(.deviceTweak), let device else { return }
        let target = min(max(value, -2.0), 2.0)
        guard target != lastPushedBias else { return }
        lastPushedBias = target
        exposureBias = target
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            let clamped = min(max(target, device.minExposureTargetBias), device.maxExposureTargetBias)
            device.setExposureTargetBias(clamped, completionHandler: nil)
            device.unlockForConfiguration()
        }
    }
 
    // MARK: - Đèn
 
    func cycleFlash() {
        settings.flashMode = switch settings.flashMode {
        case .auto: .on
        case .on: .off
        default: .auto
        }
        settings.save()
    }
 
    /// KHÔNG qua `canPerform`: `applyMode` và `flipCamera` gọi hàm này ngay
    /// giữa lúc cổng đang đóng (tắt đèn của camera sắp rời đi, bật lại đèn cho
    /// camera mới). Thêm cổng vào đây là hai đường đó tự chặn chính mình.
    func setTorch(_ on: Bool) {
        guard let device, device.hasTorch else { return }
        torchOn = on
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        }
    }
 
    // MARK: - Nút chụp điều phối
 
    func shutterTapped() {
        CaptureDiagnostics.shared.event("shutterTapped",
            "sessionBusy=\(sessionBusy) mode=\(settings.mode.rawValue) timer=\(settings.timerOption.rawValue)")
        // isRecording đã tự loại trừ sessionBusy (setMode, reconfigure và
        // flipCamera đều chặn khi đang quay, nên không đường nào mở được
        // transaction giữa lúc quay), vậy nhánh dừng quay không bị guard này
        // chặn oan.
        guard canPerform(.shutter) else { return }
        if settings.mode.isRecordingMode {
            if isRecording { stopRecording() } else { startRecording(quickTake: false) }
            return
        }
        if countdown > 0 { cancelCountdown(); return }
        if settings.timerOption == .off {
            capturePhoto()
        } else {
            runCountdown(from: settings.timerOption.rawValue)
        }
    }

    /// Giữ nút chụp ở chế độ Ảnh → QuickTake.
    /// Không dùng được khi Live Photo đang bật, vì movie output đã bị gỡ.
    func shutterHoldBegan() {
        guard canPerform(.quickTake), settings.mode == .photo, quickTakeAvailable,
              countdown == 0 else { return }
        startRecording(quickTake: true)
    }
 
    /// Thả tay sớm thì vẫn quay cho đủ thời lượng tối thiểu. Bản cũ dừng ngay,
    /// nên giữ nút 0,46 giây rồi thả là thư viện có một video 0,01 giây.
    func shutterHoldEnded() {
        guard isQuickTake, isRecording else { return }
        let elapsed = recordStartedAt.map { Date().timeIntervalSince($0) } ?? quickTakeMinimumDuration
        guard elapsed < quickTakeMinimumDuration else {
            stopRecording()
            return
        }
        let remaining = quickTakeMinimumDuration - elapsed
        quickTakeMinimumTask?.cancel()
        quickTakeMinimumTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard let self, !Task.isCancelled, self.isQuickTake, self.isRecording else { return }
            self.stopRecording()
        }
    }
 
    func burstBegan() {
        guard settings.mode == .photo, !isRecording, !isBursting else { return }
        isBursting = true
        burstCount = 0
        burstTask = Task {
            while !Task.isCancelled && isBursting {
                // Backpressure: bản cũ bắn đều 220ms bất kể output có tiêu hoá
                // kịp không, nên khi máy nóng hoặc đang lưu ProRAW thì
                // pendingCaptures phình dần và bộ nhớ đi theo.
                // Chỉ đếm khi `capturePhoto` THẬT SỰ nhận. Đếm vô điều kiện
                // thì lúc cổng chặn (đang tráo camera chẳng hạn) badge vẫn
                // nhảy số trong khi không có tấm nào được chụp.
                if capturesInFlight < 4, capturePhoto(isBurst: true) {
                    burstCount += 1
                }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }
 
    func burstEnded() {
        guard isBursting else { return }
        isBursting = false
        burstTask?.cancel()
        burstTask = nil
    }
 
    // MARK: - Hẹn giờ
 
    private func runCountdown(from seconds: Int) {
        countdown = seconds
        countdownTask = Task {
            while countdown > 0 {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                countdown -= 1
            }
            capturePhoto()
        }
    }
 
    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = 0
    }
 
    // MARK: - Ghi hình
 
    private func startRecording(quickTake: Bool) {
        guard !isRecording, !isProcessing else { return }
 
        if settings.mode == .timelapse {
            startTimeLapse()
            return
        }
 
        // Đọc cờ đã chốt từ applyMode thay vì hỏi thẳng session.outputs ở
        // main actor — mọi truy cập session.inputs/outputs nên nằm trên
        // sessionQueue, và applyMode đã gán movieOutputAttached đúng sau
        // commitConfiguration.
        guard movieOutputAttached else {
            errorMessage = "Chưa sẵn sàng quay. Tắt Live Photo rồi thử lại."
            return
        }

        // Không chặn ở đây thì clip quay ở tốc độ thường vẫn bị kéo giãn 8×
        // lúc xuất, ra một video giật chứ không phải quay chậm.
        guard settings.mode != .slomo || activeSlomoFps != nil else {
            errorMessage = "Camera này không hỗ trợ quay chậm (yêu cầu tối thiểu 120 fps)."
            return
        }
 
        // Ở chế độ quay, mic đã được gắn từ lúc vào chế độ. Chỉ QuickTake
        // (chế độ Ảnh) mới phải gắn tại chỗ.
        attachAudioIfNeeded()
        isQuickTake = quickTake
        isRecording = true
        recordDuration = 0
 
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec_\(UUID().uuidString).mov")
        let mirror = isFront
        let angle = captureRotationAngle
 
        sessionQueue.async {
            if let conn = self.movieOutput.connection(with: .video) {
                if conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }
                if conn.isVideoMirroringSupported {
                    conn.automaticallyAdjustsVideoMirroring = false
                    conn.isVideoMirrored = mirror
                }
                if conn.isVideoStabilizationSupported {
                    conn.preferredVideoStabilizationMode = .auto
                }
            }
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
 
        startRecordTimer()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
 
    /// Đồng hồ quay lấy hiệu thời gian thật. Bản cũ cộng dồn 0,1s mỗi tick,
    /// mà Timer không bao giờ đúng nhịp nên quay càng lâu càng lệch.
    private func startRecordTimer() {
        recordStartedAt = Date()
        recordTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let started = self.recordStartedAt else { return }
                self.recordDuration = Date().timeIntervalSince(started)
            }
        }
    }
 
    private func stopRecordTimer() {
        recordTimer?.invalidate()
        recordTimer = nil
        recordStartedAt = nil
    }
 
    func stopRecording() {
        guard isRecording else { return }
        quickTakeMinimumTask?.cancel()
        quickTakeMinimumTask = nil
 
        if settings.mode == .timelapse {
            stopTimeLapse()
            return
        }
 
        stopRecordTimer()
        sessionQueue.async { self.movieOutput.stopRecording() }
    }
 
    /// Tắt session sau khi file quay đã ghi xong (app vào nền giữa lúc quay).
    private func stopSessionIfPending() {
        guard stopSessionAfterRecording else { return }
        stopSessionAfterRecording = false
        detachAudio()
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }
 
    // MARK: - Tua nhanh (time-lapse)
 
    /// Chụp ảnh tĩnh theo chu kỳ rồi ghép thành video 30fps.
    /// Cách này tốn ít bộ nhớ hơn quay video dài rồi tua nhanh.
    private func startTimeLapse() {
        isRecording = true
        recordDuration = 0
        timeLapseFrames = 0
        timeLapseRecorder.reset()
 
        let interval = settings.timeLapseInterval.seconds
        timeLapseTask = Task {
            while !Task.isCancelled && isRecording {
                captureTimeLapseFrame()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
        startRecordTimer()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
 
    private func stopTimeLapse() {
        timeLapseTask?.cancel()
        timeLapseTask = nil
        stopRecordTimer()
        isRecording = false
        recordDuration = 0
 
        let frames = timeLapseFrames
        guard frames >= 2 else {
            timeLapseRecorder.reset()
            timeLapseFrames = 0
            statusMessage = "Quá ít khung hình, chưa tạo được video."
            stopSessionIfPending()
            return
        }
 
        isProcessing = true
        Task {
            do {
                let url = try await timeLapseRecorder.assemble()
                lastThumbnail = await UIImage.thumbnail(from: url)
                saveVideo(url)
                statusMessage = "Đã tạo video tua nhanh từ \(frames) khung hình."
            } catch {
                errorMessage = "Ghép video tua nhanh lỗi: \(error.localizedDescription)"
            }
            isProcessing = false
            timeLapseFrames = 0
            stopSessionIfPending()
        }
    }
 
    /// Khung hình tua nhanh cũng đi qua cùng đường an toàn với ảnh thường:
    /// dựng settings trên sessionQueue, ghi pending TRƯỚC khi bấm máy, và có
    /// watchdog dọn nếu khung không bao giờ về.
    private func captureTimeLapseFrame() {
        guard !isProcessing else { return }
        let angle = captureRotationAngle
        capturesInFlight += 1
 
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.session.isRunning else {
                Task { @MainActor in self.endCapture(id: nil) }
                return
            }
 
            let s = AVCapturePhotoSettings()
            s.flashMode = .off
            s.photoQualityPrioritization = .speed
            let id = s.uniqueID
 
            Task { @MainActor in
                self.pendingCaptures[id] = PendingCapture(kind: .timeLapseFrame)
                self.armWatchdog(id)
                self.sessionQueue.async {
                    if let conn = self.photoOutput.connection(with: .video),
                       conn.videoRotationAngle != angle,
                       conn.isVideoRotationAngleSupported(angle) {
                        conn.videoRotationAngle = angle
                    }
                    self.photoOutput.capturePhoto(with: s, delegate: self)
                }
            }
        }
    }
 
    func appendTimeLapseFrame(_ data: Data) {
        timeLapseRecorder.append(data)
        timeLapseFrames += 1
    }
 
    // MARK: - Lưu video
 
    func saveVideo(_ url: URL) {
        let location = currentLocation
        PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .video, fileURL: url, options: nil)
            req.location = location
        } completionHandler: { ok, err in
            try? FileManager.default.removeItem(at: url)
            let text = err?.localizedDescription ?? ""
            Task { @MainActor in
                if !ok { self.errorMessage = "Lưu video thất bại: \(text)" }
            }
        }
    }
 
    // MARK: - Thước thăng bằng

    /// |gz| bắt đầu làm mờ thước (~44° chúc) và tắt hẳn (~58° chúc).
    private static let pitchFadeStart = 0.70
    private static let pitchFadeEnd = 0.85
    /// Góc lệch để bắt/nhả trạng thái cân bằng (độ).
    private static let levelThresholdOn = 0.8
    private static let levelThresholdOff = 2.2

    private func startMotion() {
        guard motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let gx = motion.gravity.x
            let gy = motion.gravity.y
            let gz = motion.gravity.z

            // Máy càng chĩa lên trời hoặc xuống đất thì trọng lực càng dồn về
            // trục z, góc xoay trong mặt phẳng màn hình càng mất ý nghĩa. Mờ dần
            // trong dải 44°–58° chúc rồi tắt, thay vì biến mất đột ngột.
            let tilt = abs(gz)
            let fade = (Self.pitchFadeEnd - tilt) / (Self.pitchFadeEnd - Self.pitchFadeStart)
            self.levelPitchFade = min(max(fade, 0), 1)

            guard self.levelPitchFade > 0 else {
                self.isLevel = false
                return
            }

            // Tính góc xoay từ vector trọng lực (trên mặt phẳng màn hình)
            let angle = atan2(gx, -gy) * 180 / .pi
            // Tìm mốc thăng bằng gần nhất (0° dọc, ±90° ngang, 180° dọc ngược)
            var targetAngle = (angle / 90.0).rounded() * 90.0
            // rounded() sinh ra cả -180 và 180 cho cùng một chiều máy (dọc ngược).
            // Để nguyên thì rung tay qua biên ±180 sẽ đổi 180 <-> -180 và làm
            // thước quay trọn một vòng 360°. Chốt về một giá trị duy nhất; phần
            // bù ±360 bên dưới vẫn đưa delta về đúng dải.
            if targetAngle <= -180 { targetAngle = 180 }
            var delta = angle - targetAngle
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }

            self.rollAngle = delta
            self.orientationAngle = targetAngle

            // Hysteresis chống rung tay chập chờn khi ở sát ngưỡng cân bằng.
            // Ngưỡng nhả phải rộng hơn hẳn ngưỡng bắt: tay cầm máy dao động
            // cỡ ±1–2°, nếu nhả ở 1.2° thì thước vừa ẩn xong lại hiện lại liên
            // tục thay vì nằm im.
            if self.isLevel {
                self.isLevel = abs(delta) < Self.levelThresholdOff
            } else {
                self.isLevel = abs(delta) < Self.levelThresholdOn
            }
        }
    }
 
    private func stopMotion() { motionManager.stopDeviceMotionUpdates() }
}
 
// MARK: - Delegate ghi video
 
extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        let failure = error?.localizedDescription
        Task { @MainActor in
            self.isRecording = false
            let wasQuickTake = self.isQuickTake
            self.isQuickTake = false
            self.stopRecordTimer()
            self.recordDuration = 0
 
            // Ở chế độ quay, giữ mic lại cho lần quay sau — gắn/gỡ mỗi lần là
            // nguyên nhân làm đầu video khựng. QuickTake thì trả mic ngay.
            if wasQuickTake || !self.settings.mode.isRecordingMode {
                self.detachAudio()
            }
 
            if let failure {
                self.errorMessage = "Quay lỗi: \(failure)"
                try? FileManager.default.removeItem(at: outputFileURL)
                self.stopSessionIfPending()
                return
            }
 
            // Quay chậm: phải kéo giãn thời gian trước khi lưu, nếu không
            // video sẽ phát ở tốc độ thường.
            if self.settings.mode == .slomo {
                self.isProcessing = true
                // Lấy theo fps THẬT đang chạy, không theo mức người dùng
                // chọn: camera trước có thể đã bị hạ xuống 120fps.
                let fps = self.activeSlomoFps ?? self.settings.slomoRate.fps
                let factor = SlomoRate.slowdown(forCapturedFps: fps)
                Task {
                    do {
                        let slowed = try await MediaProcessing.slowDown(url: outputFileURL, factor: factor)
                        self.lastThumbnail = await UIImage.thumbnail(from: slowed)
                        self.saveVideo(slowed)
                    } catch {
                        self.errorMessage = "Xuất video chậm lỗi: \(error.localizedDescription)"
                    }
                    try? FileManager.default.removeItem(at: outputFileURL)
                    self.isProcessing = false
                    self.stopSessionIfPending()
                }
                return
            }
 
            // Thumbnail dựng bất đồng bộ: copyCGImage đồng bộ giải mã một
            // khung 4K ngay trên main thread, UI đứng hình một nhịp.
            let url = outputFileURL
            Task {
                self.lastThumbnail = await UIImage.thumbnail(from: url)
            }
            self.saveVideo(outputFileURL)
            self.stopSessionIfPending()
        }
    }
}
 
// MARK: - Delegate quét mã
 
extension CameraManager: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                                    didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        Task { @MainActor in
            guard self.settings.scanCodesOn, !self.isRecording else { return }
            // Bản cũ chỉ nhìn phần tử đầu: nếu nó không phải mã đọc được,
            // hoặc trong khung có nhiều mã, thì mã thật bị bỏ qua.
            guard let obj = metadataObjects
                .compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
                .first(where: { $0.stringValue?.isEmpty == false }),
                  let value = obj.stringValue else { return }
            if self.scannedCode?.value != value {
                self.scannedCode = ScannedCode(value: value, type: obj.type)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }
}
