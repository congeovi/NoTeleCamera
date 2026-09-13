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
    @Published var isFront = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?
 
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
 
            sessionQueue.async { [weak self] in
                self?.configureSession()
                self?.session.startRunning()
            }
            startMotion()
        }
    }
 
    func stop() {
        stopMotion()
        cancelCountdown()
        burstEnded()
 
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
                    let reason = raw.flatMap { AVCaptureSession.InterruptionReason(rawValue: $0) }
                    self.statusMessage = switch reason {
                    case .videoDeviceInUseByAnotherClient: "Camera đang được app khác dùng."
                    case .audioDeviceInUseByAnotherClient: "Mic đang được app khác dùng."
                    case .videoDeviceNotAvailableWithMultipleForegroundApps: "Camera tạm dừng khi chia đôi màn hình."
                    default: "Camera tạm bị gián đoạn."
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
    }
 
    deinit {
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
        rotationObservation?.invalidate()
    }
 
    // MARK: - Dựng session
 
    private nonisolated func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo
 
        // ★★★ ĐIỂM MẤU CHỐT ★★★
        // builtInDualWideCamera = [ống siêu rộng 0.5x + ống chính 1x].
        // Thiết bị ảo này KHÔNG chứa ống tele, nên OIS tele không bao giờ
        // được cấp điện — đây là lý do tồn tại của cả app.
        let cam = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
 
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
        photoOutput.maxPhotoQualityPrioritization = .quality
        if let maxDim = cam.activeFormat.supportedMaxPhotoDimensions.last {
            photoOutput.maxPhotoDimensions = maxDim
        }
 
        // ProRAW — chỉ có trên máy Pro. Phải bật ở output trước khi dùng.
        let proRAW = photoOutput.isAppleProRAWSupported
        if proRAW { photoOutput.isAppleProRAWEnabled = true }
 
        // Đọc khả năng Live Photo và depth TRƯỚC khi thêm movie output, vì
        // movie output sẽ che mất chúng. Việc bật/tắt để applyMode lo.
        let livePhoto = photoOutput.isLivePhotoCaptureSupported
        let depth = photoOutput.isDepthDataDeliverySupported
 
        // Movie output thêm sẵn để QuickTake không phải dựng lại session.
        // applyMode sẽ gỡ ra nếu chế độ Ảnh cần Live Photo.
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
 
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
    private func attachAudioIfNeeded() {
        guard !audioAttached else { return }
        audioAttached = true
        sessionQueue.async { [weak self] in
            guard let self else { return }
            Self.setAudioSession(recording: true)
            guard let mic = AVCaptureDevice.default(for: .audio),
                  let input = try? AVCaptureDeviceInput(device: mic) else { return }
            self.session.beginConfiguration()
            if self.session.canAddInput(input) {
                self.session.addInput(input)
                // AVFoundation mặc định thu mono; phải xin stereo rõ ràng.
                if input.isMultichannelAudioModeSupported(.stereo) {
                    input.multichannelAudioMode = .stereo
                }
            }
            self.session.commitConfiguration()
        }
    }
 
    /// Gỡ mọi input âm thanh đang có trong session. Lấy session làm nguồn sự
    /// thật thay vì giữ tham chiếu riêng, và vì hai hàm này cùng chạy trên
    /// sessionQueue nối tiếp nên thứ tự gắn-rồi-gỡ luôn đúng.
    func detachAudio() {
        guard audioAttached else { return }
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
        }
    }
 
    // MARK: - Đổi chế độ
 
    func setMode(_ new: CaptureMode) {
        guard new != settings.mode, !isRecording, !isProcessing else { return }
        settings.mode = new
        settings.save()
        if new != .video && new != .slomo { setTorch(false) }
        applyMode(new)
    }
 
    /// Dựng lại session cho những thay đổi KHÔNG kèm đổi chế độ — bật/tắt Live
    /// Photo, đổi chất lượng video. Trước đây các chỗ này gọi setMode với chính
    /// chế độ hiện tại nên bị guard chặn và không có tác dụng gì.
    func reconfigure() {
        guard !isRecording, !isProcessing else { return }
        applyMode(settings.mode)
    }
 
    private func applyMode(_ mode: CaptureMode) {
        // Lấy device trên main actor TRƯỚC khi nhảy sang sessionQueue.
        // Bản cũ dùng MainActor.assumeIsolated bên trong sessionQueue, mà
        // assumeIsolated trap khi không thực sự ở main actor → crash.
        guard let dev = device else { return }
 
        let quality = settings.videoQuality
        let slomo = settings.slomoRate
        let wantsDepth = (mode == .portrait) && supportsDepth
        let wantsLive = (mode == .photo) && settings.livePhotoOn && supportsLivePhoto
        let defFormat = defaultFormat
        // Mic chuẩn bị sẵn cho hai chế độ quay có tiếng.
        let wantsMic = (mode == .video || mode == .slomo)
 
        quickTakeAvailable = !wantsLive
 
        sessionQueue.async { [weak self] in
            guard let self else { return }
 
            self.session.beginConfiguration()
 
            switch mode {
            case .slomo:
                // Quay chậm cần chọn activeFormat riêng → preset phải là inputPriority.
                if let fmt = Self.highFrameRateFormat(for: dev, fps: slomo.fps) {
                    self.session.sessionPreset = .inputPriority
                    try? dev.lockForConfiguration()
                    dev.activeFormat = fmt
                    let d = CMTime(value: 1, timescale: CMTimeScale(slomo.fps))
                    dev.activeVideoMinFrameDuration = d
                    dev.activeVideoMaxFrameDuration = d
                    dev.unlockForConfiguration()
                } else {
                    Task { @MainActor in self.errorMessage = "Máy không hỗ trợ mức quay chậm này." }
                }
 
            case .video, .timelapse:
                // Khôi phục format gốc nếu vừa thoát quay chậm.
                if let defFormat, dev.activeFormat != defFormat {
                    try? dev.lockForConfiguration()
                    dev.activeFormat = defFormat
                    dev.unlockForConfiguration()
                }
                let preset = (mode == .video) ? quality.preset : AVCaptureSession.Preset.hd1920x1080
                if self.session.canSetSessionPreset(preset) { self.session.sessionPreset = preset }
                if mode == .video { Self.applyFrameRate(quality.fps, to: dev) }
 
            case .photo, .portrait:
                if let defFormat, dev.activeFormat != defFormat {
                    try? dev.lockForConfiguration()
                    dev.activeFormat = defFormat
                    dev.unlockForConfiguration()
                }
                if self.session.canSetSessionPreset(.photo) { self.session.sessionPreset = .photo }
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
 
            if self.photoOutput.isLivePhotoCaptureSupported {
                self.photoOutput.isLivePhotoCaptureEnabled = wantsLive
            }
 
            // Depth chỉ bật ở chế độ Chân dung — bật thừa sẽ giới hạn format.
            if self.photoOutput.isDepthDataDeliverySupported {
                self.photoOutput.isDepthDataDeliveryEnabled = wantsDepth
            }
 
            // activeFormat có thể vừa đổi (quay chậm ↔ thường) nên kích thước
            // ảnh tối đa phải đọc lại, nếu không chụp ở format mới sẽ lỗi.
            if let maxDim = dev.activeFormat.supportedMaxPhotoDimensions.last {
                self.photoOutput.maxPhotoDimensions = maxDim
            }
 
            self.session.commitConfiguration()
 
            Task { @MainActor in
                self.applyMacroIfNeeded()
                self.displayZoom = self.currentDisplayZoom()
                if wantsMic {
                    self.attachAudioIfNeeded()
                } else if !self.isRecording {
                    self.detachAudio()
                }
            }
        }
    }
 
    /// Tìm format hỗ trợ tốc độ cao, ưu tiên độ phân giải lớn nhất ở mức fps đó.
    private static func highFrameRateFormat(for dev: AVCaptureDevice, fps: Double) -> AVCaptureDevice.Format? {
        dev.formats
            .filter { fmt in
                fmt.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= fps }
            }
            .max { a, b in
                let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                return Int(da.width) * Int(da.height) < Int(db.width) * Int(db.height)
            }
    }
 
    private static func applyFrameRate(_ fps: Double, to dev: AVCaptureDevice) {
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
 
    private func currentDisplayZoom() -> CGFloat {
        guard let device else { return 1.0 }
        return device.videoZoomFactor / baseFactor
    }
 
    // MARK: - Macro
 
    /// 13 Pro chụp macro bằng ống siêu rộng lấy nét gần.
    /// Bật macro = ép về 0,5× và giới hạn dải lấy nét về phía gần.
    func setMacro(_ on: Bool) {
        settings.macroOn = on
        settings.save()
        if on { setZoom(0.5) }
        applyMacroIfNeeded()
    }
 
    private func applyMacroIfNeeded() {
        guard let device, supportsMacro else { return }
        let on = settings.macroOn && !isFront
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
        guard !isRecording, !isProcessing, let current = videoInput else { return }
        let goingFront = !isFront
        isFront = goingFront
        setTorch(false)
        // Ảnh đang bay thuộc về camera cũ — bỏ hết, đừng để kẹt nút chụp.
        abortAllCaptures()
 
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let newCam: AVCaptureDevice? = goingFront
                ? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                : (AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
                   ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back))
 
            guard let newCam, let newInput = try? AVCaptureDeviceInput(device: newCam) else { return }
 
            self.session.beginConfiguration()
            self.session.removeInput(current)
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
            } else {
                self.session.addInput(current)
                self.session.commitConfiguration()
                return
            }
 
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
            newCam.unlockForConfiguration()
 
            let newFormat = newCam.activeFormat
 
            Task { @MainActor in
                self.videoInput = newInput
                self.baseFactor = switchOver
                self.displayZoom = 1.0
                self.exposureBias = 0
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
                // mới — bản cũ giữ nguyên cấu hình của camera cũ.
                self.applyMode(self.settings.mode)
            }
        }
    }
 
    // MARK: - Zoom
 
    func setZoom(_ target: CGFloat) {
        guard let device else { return }
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
        if settings.mode == .portrait { return [1.0, 2.0] }
        return [0.5, 1.0, 2.0]
    }
 
    // MARK: - Lấy nét & phơi sáng
 
    func focus(at devicePoint: CGPoint, uiPoint: CGPoint) {
        guard let device else { return }
        focusPoint = uiPoint
        isLocked = false
 
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = devicePoint
                device.focusMode = device.isFocusModeSupported(.autoFocus) ? .autoFocus : .continuousAutoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = device.isExposureModeSupported(.autoExpose) ? .autoExpose : .continuousAutoExposure
            }
            device.unlockForConfiguration()
        }
 
        // Mỗi lần chạm trước đây sinh một Task hẹn 1,5 giây riêng, không ai
        // huỷ ai — chạm lần hai thì hẹn giờ của lần một vẫn chạy và xoá ô vàng
        // sớm. Nay chỉ giữ đúng một hẹn giờ.
        focusHideTask?.cancel()
        focusHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled, !self.isLocked else { return }
            self.focusPoint = nil
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
        isLocked = false
        focusPoint = nil
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.unlockForConfiguration()
        }
    }
 
    func setExposureBias(_ value: Float) {
        guard let device else { return }
        exposureBias = value
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            let clamped = min(max(value, device.minExposureTargetBias), device.maxExposureTargetBias)
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
        guard settings.mode == .photo, quickTakeAvailable,
              !isRecording, !isBursting, countdown == 0 else { return }
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
                if capturesInFlight < 4 {
                    capturePhoto(isBurst: true)
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
 
        guard session.outputs.contains(movieOutput) else {
            errorMessage = "Chưa sẵn sàng quay. Tắt Live Photo rồi thử lại."
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
 
    private func startMotion() {
        guard motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let roll = motion.attitude.roll * 180 / .pi
            self.rollAngle = roll
            self.isLevel = abs(roll) < 1.0 || abs(abs(roll) - 180) < 1.0
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
                let factor = self.settings.slomoRate.slowdown
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