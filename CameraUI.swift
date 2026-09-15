//
//  CameraUI.swift
//  NoTeleCamera — Giai đoạn 3
//
//  Toàn bộ giao diện.
//
 
import AVFoundation
import MediaPlayer
import SwiftUI
 
// MARK: - Lớp preview
 
final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    /// Chụp lại khung hình đang hiển thị để làm ảnh đóng băng che nháy hình
    /// khi applyMode cấu hình lại session (đổi preset/format làm AVFoundation
    /// tự renegotiate, rớt mất một khung hình thật).
    func snapshotImage() -> UIImage? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        return renderer.image { ctx in
            previewLayer.render(in: ctx.cgContext)
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let onTap: (CGPoint, CGPoint) -> Void
    let onLongPress: (CGPoint, CGPoint) -> Void
    /// Vuốt dọc một ngón để chỉnh EV. Cử chỉ nằm ở đây chứ không phải trên lớp
    /// phủ SwiftUI: một view SwiftUI có .gesture sẽ nuốt cả chạm lẫn giữ lâu
    /// trong vùng của nó, làm không lấy nét lại hay khoá AE/AF được ngay cạnh
    /// ô vàng đang hiện.
    var onVerticalDrag: (UIGestureRecognizer.State, CGFloat) -> Void = { _, _ in }
    var onViewReady: (PreviewUIView) -> Void = { _ in }

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        let long = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLong(_:)))
        long.minimumPressDuration = 0.6
        // Một ngón thôi — hai ngón là cử chỉ zoom, để MagnifyGesture lo.
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(long)
        view.addGestureRecognizer(pan)
        context.coordinator.view = view
        onViewReady(view)
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        // Coordinator giữ bản sao struct từ lúc khởi tạo; các closure bên trong
        // bắt CameraManager (class) nên không cũ, nhưng vẫn refresh cho chắc.
        context.coordinator.parent = self
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: CameraPreview
        weak var view: PreviewUIView?
        init(_ parent: CameraPreview) { self.parent = parent }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let view else { return }
            let p = g.location(in: view)
            parent.onTap(view.previewLayer.captureDevicePointConverted(fromLayerPoint: p), p)
        }

        @objc func handleLong(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let view else { return }
            let p = g.location(in: view)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            parent.onLongPress(view.previewLayer.captureDevicePointConverted(fromLayerPoint: p), p)
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let view else { return }
            parent.onVerticalDrag(g.state, g.translation(in: view).y)
        }
    }
}
 
// MARK: - Lớp phủ

/// Ô vàng lấy nét kèm đường ray EV, kiểu Camera gốc. Thuần hiển thị — mọi cử
/// chỉ do CameraPreview bên dưới xử lý (xem `onVerticalDrag`).
struct FocusIndicatorView: View {
    let point: CGPoint
    let bias: Float
    /// Bề ngang của khung preview, để biết ô vàng có sát mép phải không.
    let containerWidth: CGFloat

    @State private var appearScale: CGFloat = 1.35

    private let boxSize: CGFloat = 70
    /// Nửa quãng đường của mặt trời = 2 nấc EV. 66 / 2 = 33 point mỗi nấc,
    /// khớp đúng `CameraManager.evDragPointsPerStop` nên icon bám tay 1:1.
    private let halfTrack: CGFloat = 66

    var body: some View {
        let sunSide: CGFloat = (point.x > containerWidth - 90) ? -1 : 1
        let clamped = min(max(bias, -2.0), 2.0)
        let sunY = -CGFloat(clamped / 2.0) * halfTrack

        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .stroke(.yellow, lineWidth: 1.2)
                .frame(width: boxSize, height: boxSize)
                .scaleEffect(appearScale)

            // Đường ray dẫn hướng + icon mặt trời chỉ mức EV hiện tại.
            ZStack {
                Rectangle()
                    .fill(.yellow.opacity(0.35))
                    .frame(width: 1.5, height: halfTrack * 2)

                Image(systemName: "sun.max.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.yellow)
                    .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
                    .overlay(alignment: sunSide > 0 ? .leading : .trailing) {
                        // Số EV chỉ hiện khi đã lệch khỏi 0, như Camera gốc.
                        if clamped != 0 {
                            Text(String(format: "%+.1f", clamped))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.yellow)
                                .shadow(color: .black.opacity(0.5), radius: 2)
                                .fixedSize()
                                .offset(x: sunSide > 0 ? 20 : -20)
                        }
                    }
                    .offset(y: sunY)
            }
            .offset(x: sunSide * (boxSize / 2 + 20))
        }
        .position(point)
        .onAppear { snapIn() }
        .onChange(of: point) { _, _ in snapIn() }
    }

    /// Nảy nhẹ rồi co về 1× — nhịp lò xo của Camera gốc.
    private func snapIn() {
        appearScale = 1.35
        withAnimation(.spring(response: 0.25, dampingFraction: 0.65)) {
            appearScale = 1.0
        }
    }
}

struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                for i in 1..<3 {
                    let x = geo.size.width * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: geo.size.height))
                    let y = geo.size.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
            }
            .stroke(.white.opacity(0.35), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}
 
struct LevelOverlay: View {
    let roll: Double
    let isLevel: Bool
 
    var body: some View {
        ZStack {
            Rectangle().fill(isLevel ? .yellow : .white.opacity(0.5))
                .frame(width: 64, height: 1)
            Rectangle().fill(.white.opacity(0.85))
                .frame(width: 110, height: 1)
                .rotationEffect(.degrees(-roll))
                .opacity(isLevel ? 0 : 1)
        }
        .animation(.easeOut(duration: 0.1), value: isLevel)
        .allowsHitTesting(false)
    }
}
 
// MARK: - Nút âm lượng làm shutter
 
/// Nghe thay đổi âm lượng hệ thống để dùng phím Vol làm nút chụp.
///
/// Hai điểm phải làm đúng, nếu không phím sẽ chết:
///  - Sau mỗi lần bấm phải kéo âm lượng về giữa dải. Nếu để nguyên, khi âm
///    lượng chạm 0 hoặc chạm max thì bấm tiếp không sinh thay đổi nào và
///    nút chụp im luôn.
///  - Dùng category `.ambient`, KHÔNG dùng `.playAndRecord`. playAndRecord
///    ngắt nhạc người dùng đang nghe và giữ mic suốt thời gian mở app, đúng
///    cái mà thiết kế "chỉ gắn mic lúc quay" muốn tránh.
final class VolumeShutter: ObservableObject {
    private var observer: NSKeyValueObservation?
    private var audioChangeToken: NSObjectProtocol?
 
    /// Hạn dùng của lần bỏ qua do CHÍNH MÌNH kéo slider. Bản cũ là một Bool
    /// không hạn: nếu KVO không phát (slider chưa sẵn sàng, giá trị đã bằng
    /// target) thì cờ nằm lại và nuốt đúng lần bấm phím thật kế tiếp.
    private var ignoreSelfChangeUntil: Date?
 
    /// Khoảng lặng quanh lúc app đổi AVAudioSession category. Chuyển sang
    /// playAndRecord làm outputVolume nhảy (ringer ↔ media), bản cũ hiểu đó là
    /// một lần bấm phím chụp nên vừa bấm quay là dừng ngay.
    private var ignoreSystemChangeUntil: Date?
 
    private let target: Float = 0.5
 
    /// MPVolumeView phải nằm trong cây view thật thì mới chỉnh được âm lượng,
    /// nên giữ đúng một instance rồi cho HiddenVolumeView gắn nó vào.
    let volumeView = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
 
    var onPress: (() -> Void)?
 
    private var slider: UISlider? {
        volumeView.subviews.compactMap { $0 as? UISlider }.first
    }
 
    func activate() {
        let audio = AVAudioSession.sharedInstance()
        // Không ép category ở đây nữa: khi đang ở chế độ quay, CameraManager
        // đã đặt playAndRecord và ghi đè lại bằng ambient sẽ cắt mất mic.
        if audio.category != .playAndRecord {
            try? audio.setCategory(.ambient, options: [.mixWithOthers])
        }
        try? audio.setActive(true)
 
        resetVolume()
 
        if audioChangeToken == nil {
            audioChangeToken = NotificationCenter.default.addObserver(
                forName: .cameraAudioSessionWillChange, object: nil, queue: .main
            ) { [weak self] _ in
                self?.ignoreSystemChangeUntil = Date().addingTimeInterval(0.8)
            }
        }
 
        observer = audio.observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                let now = Date()
 
                // Thay đổi do app đổi audio category gây ra.
                if let until = self.ignoreSystemChangeUntil, now < until { return }
 
                // Thay đổi do chính mình kéo slider về giữa dải. Cờ tiêu thụ
                // một lần và tự hết hạn, nên hỏng thì hỏng về phía "vẫn nhận
                // được phím" chứ không phải "phím chết".
                if let until = self.ignoreSelfChangeUntil {
                    self.ignoreSelfChangeUntil = nil
                    if now < until { return }
                }
 
                self.onPress?()
                self.resetVolume()
            }
        }
    }
 
    /// Kéo âm lượng về giữa dải để lần bấm sau luôn sinh được thay đổi.
    private func resetVolume() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, let slider = self.slider else { return }
            guard abs(slider.value - self.target) > 0.001 else { return }
            self.ignoreSelfChangeUntil = Date().addingTimeInterval(0.4)
            slider.value = self.target
        }
    }
 
    func deactivate() {
        observer?.invalidate()
        observer = nil
        ignoreSelfChangeUntil = nil
        ignoreSystemChangeUntil = nil
        if let audioChangeToken {
            NotificationCenter.default.removeObserver(audioChangeToken)
            self.audioChangeToken = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
 
    deinit {
        observer?.invalidate()
        if let audioChangeToken { NotificationCenter.default.removeObserver(audioChangeToken) }
    }
}
 
struct HiddenVolumeView: UIViewRepresentable {
    let shutter: VolumeShutter
 
    func makeUIView(context: Context) -> MPVolumeView {
        let v = shutter.volumeView
        v.alpha = 0.001
        v.showsRouteButton = false
        return v
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
 
// MARK: - Màn hình chính
 
struct ContentView: View {
    @StateObject private var cam = CameraManager()
    @StateObject private var volume = VolumeShutter()
    @State private var pinchStart: CGFloat = 1.0
    @State private var showSettings = false
    @State private var shutterDrag: CGFloat = 0
    @State private var isPinching = false
    @State private var shutterFlashOpacity: Double = 0
    @State private var previewUIView: PreviewUIView?
    @State private var modeFreezeFrame: UIImage?
    /// Bán kính mờ đang áp lên ảnh đóng băng khi chuyển chế độ: mờ dần vào
    /// ngay khi bấm mode, giữ đến khi camera sẵn sàng rồi tan về 0.
    @State private var switchBlur: CGFloat = 0
    /// Độ đục của ảnh đóng băng — rượt về 0 cùng lúc blur tan để chuyển mượt
    /// sang khung sống bên dưới.
    @State private var freezeOpacity: Double = 1
    /// Mốc thời gian bắt đầu chuyển, để giữ mờ tối thiểu một nhịp.
    @State private var modeSwitchStartedAt: Date?
    /// Số thứ tự của lần chuyển hiện tại — các hẹn giờ muộn của lần cũ phải
    /// đối chiếu số này trước khi đụng vào trạng thái của lần mới.
    @State private var modeSwitchGeneration = 0
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
 
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
 
            previewArea

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                if !cam.isRecording && !cam.isProcessing {
                    zoomSelector
                    if cam.settings.mode == .portrait { portraitSlider }
                    modeSelector
                }
                bottomBar
            }
 
            if let code = cam.scannedCode, !cam.isRecording { codeBanner(code) }
            if cam.countdown > 0 { countdownOverlay }
            if cam.isProcessing { processingOverlay }
            if let msg = cam.statusMessage { statusToast(msg) }
 
            HiddenVolumeView(shutter: volume).frame(width: 0, height: 0)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onAppear {
            volume.onPress = { cam.shutterTapped() }
            cam.start()
            volume.activate()
        }
        .onDisappear {
            cam.stop()
            volume.deactivate()
        }
        // onDisappear KHÔNG chạy khi app bị đẩy vào nền, nên nếu chỉ dựa vào nó
        // thì session vẫn chạy nền và file đang quay sẽ hỏng.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                cam.start()
                volume.activate()
            case .background:
                cam.stop()
                volume.deactivate()
            default:
                break
            }
        }
        .sheet(isPresented: $showSettings) { SettingsSheet(cam: cam, isPresented: $showSettings) }
        .alert("Lỗi", isPresented: Binding(
            get: { cam.errorMessage != nil },
            set: { if !$0 { cam.errorMessage = nil } }
        )) {
            Button("OK") { cam.errorMessage = nil }
        } message: {
            Text(cam.errorMessage ?? "")
        }
    }
 
    // MARK: Preview
 
    private var previewArea: some View {
        ZStack {
            CameraPreview(
                session: cam.session,
                onTap: { dp, up in cam.focus(at: dp, uiPoint: up) },
                onLongPress: { dp, up in cam.lockFocusAndExposure(at: dp, uiPoint: up) },
                onVerticalDrag: { state, translationY in
                    switch state {
                    case .began:   cam.beginExposureDrag()
                    case .changed: cam.updateExposureDrag(translationY: translationY)
                    default:       cam.endExposureDrag()
                    }
                },
                onViewReady: { previewUIView = $0 }
            )
            // Chốt mức zoom ngay khi cử chỉ bắt đầu. Bản cũ dùng .onTapGesture
            // để làm việc này, nhưng nó chồng lên UITapGestureRecognizer bên
            // trong CameraPreview nên chạm lấy nét bị chập chờn.
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        if !isPinching {
                            isPinching = true
                            pinchStart = cam.displayZoom
                        }
                        cam.pinchZoom(scale: value.magnification, from: pinchStart)
                    }
                    .onEnded { _ in
                        isPinching = false
                        pinchStart = cam.displayZoom
                    }
            )
            // Không chụp được snapshot (preview chưa có kích thước) thì làm
            // mờ thẳng khung sống — vẫn đúng ý "mờ đến khi camera sẵn sàng".
            .blur(radius: (modeFreezeFrame == nil && cam.isModeTransitioning) ? 16 : 0)
            .animation(.easeIn(duration: 0.15), value: cam.isModeTransitioning)
 

            // Ảnh đóng băng phủ lên trong lúc applyMode cấu hình lại session
            // (đổi mode ảnh/video/chân dung...). Che đúng lúc AVFoundation
            // renegotiate preset/format nên người dùng thấy chuyển mượt thay
            // vì thấy khung hình nháy/đen. Lớp blur nói cho mắt biết "đang
            // chuyển" và chỉ tan khi CameraManager báo đã sẵn sàng.
            if let modeFreezeFrame {
                Image(uiImage: modeFreezeFrame)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: switchBlur)
                    .opacity(freezeOpacity)
                    .allowsHitTesting(false)
                    .transition(.identity)
            }

            if cam.settings.gridOn { GridOverlay() }
            if cam.settings.levelOn { LevelOverlay(roll: cam.rollAngle, isLevel: cam.isLevel) }
            if let fp = cam.focusPoint {
                GeometryReader { geo in
                    FocusIndicatorView(point: fp,
                                       bias: cam.exposureBias,
                                       containerWidth: geo.size.width)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
            if cam.isBursting { centerBadge("\(cam.burstCount)") }
            if cam.isRecording && cam.settings.mode == .timelapse {
                centerBadge("\(cam.timeLapseFrames) khung")
            }

            // Nháy trắng ngay lúc bấm máy, giống Camera gốc — bằng chứng
            // trực quan rằng đã chụp, vì isCapturing đôi khi trả về quá
            // nhanh để mắt kịp thấy nút thu nhỏ lại.
            Color.white
                .opacity(shutterFlashOpacity)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .onChange(of: cam.shutterFlashTrigger) { _, _ in
            shutterFlashOpacity = 0.9
            withAnimation(.easeOut(duration: 0.25)) { shutterFlashOpacity = 0 }
        }
        // CameraManager báo đã cấu hình xong: giữ mờ thêm một nhịp tối thiểu
        // (tránh nhấp nháy khi sẵn sàng gần như tức thì) rồi cho hiệu ứng tan.
        .onChange(of: cam.isModeTransitioning) { _, transitioning in
            guard !transitioning, modeFreezeFrame != nil else { return }
            let gen = modeSwitchGeneration
            let elapsed = Date().timeIntervalSince(modeSwitchStartedAt ?? Date())
            let delay = max(0, 0.25 - elapsed)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard modeSwitchGeneration == gen, modeFreezeFrame != nil else { return }
                unwindModeFreeze()
            }
        }
    }
 
    /// Chụp khung hình cuối cùng trước khi đổi mode và giữ nó phủ lên preview.
    /// Bắt đầu hiệu ứng chuyển chế độ: chốt khung hình cuối làm nền và mờ dần
    /// vào ngay khi bấm mode. Ảnh đóng băng che đúng lúc AVFoundation
    /// renegotiate preset/format; lớp mờ chỉ tan khi CameraManager báo camera
    /// đã sẵn sàng (xem onChange của isModeTransitioning).
    private func freezePreviewForModeSwitch() {
        guard let image = previewUIView?.snapshotImage() else { return }
        modeSwitchGeneration += 1
        let gen = modeSwitchGeneration
        modeSwitchStartedAt = Date()
        freezeOpacity = 1
        switchBlur = 0
        modeFreezeFrame = image
        withAnimation(.easeIn(duration: 0.15)) { switchBlur = 16 }
        // Lưới an toàn thứ hai của UI: nếu cả tín hiệu sẵn sàng lẫn watchdog
        // của CameraManager đều mất, vẫn phải tan mờ.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard modeSwitchGeneration == gen, modeFreezeFrame != nil else { return }
            unwindModeFreeze()
        }
    }

    /// Tan mờ: blur về 0 đồng thời rượt độ đục về 0 (khung sống bên dưới đã
    /// sẵn sàng và đang hiển thị), xong mới gỡ ảnh đóng băng. Chỉ lần chuyển
    /// mới nhất mới được gỡ — lần cũ bấm muộn hơn thì bỏ qua.
    private func unwindModeFreeze() {
        guard modeFreezeFrame != nil else { return }
        let gen = modeSwitchGeneration
        withAnimation(.easeOut(duration: 0.25)) {
            switchBlur = 0
            freezeOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            guard modeSwitchGeneration == gen else { return }
            modeFreezeFrame = nil
            freezeOpacity = 1
            switchBlur = 0
        }
    }

    private func centerBadge(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(.bottom, 18)
        }
    }
 
    // MARK: Thanh trên
 
    private var topBar: some View {
        HStack(spacing: 0) {
            Button {
                usesTorch ? cam.setTorch(!cam.torchOn) : cam.cycleFlash()
            } label: {
                Image(systemName: usesTorch ? (cam.torchOn ? "bolt.fill" : "bolt.slash.fill") : flashIcon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(isLightActive ? .yellow : .white)
                    .frame(width: 42, height: 44)
            }
 
            if !cam.settings.mode.isRecordingMode && !cam.isRecording {
                timerButton
                if cam.supportsLivePhoto && cam.settings.mode == .photo { livePhotoButton }
                if cam.supportsMacro && !cam.isFront && cam.settings.mode == .photo { macroButton }
            }
 
            Spacer()
 
            if cam.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text(timeString(cam.recordDuration))
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.black.opacity(0.4), in: Capsule())
            } else if cam.isLocked {
                Button { cam.unlock() } label: {
                    Text("AE/AF LOCK")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.yellow, in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.black)
                }
            }
 
            Spacer()
 
            Button { showSettings = true } label: {
                Image(systemName: "chevron.down.circle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 44)
            }
            .opacity(cam.isRecording ? 0 : 1)
            .disabled(cam.isRecording)
        }
        .padding(.horizontal, 10)
        .frame(height: 50)
    }
 
    private var timerButton: some View {
        Button {
            let all = TimerOption.allCases
            let idx = all.firstIndex(of: cam.settings.timerOption) ?? 0
            cam.settings.timerOption = all[(idx + 1) % all.count]
            cam.settings.save()
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "timer").font(.system(size: 15, weight: .medium))
                if cam.settings.timerOption != .off {
                    Text("\(cam.settings.timerOption.rawValue)").font(.system(size: 11, weight: .bold))
                }
            }
            .foregroundStyle(cam.settings.timerOption == .off ? .white : .yellow)
            .frame(height: 44).padding(.horizontal, 5)
        }
    }
 
    private var livePhotoButton: some View {
        Button {
            // reconfigure() cũng renegotiate session (tráo Live Photo ↔ movie
            // output) như setMode, nên cần cùng cơ chế freeze+mờ — không thì
            // rơi vào nhánh fallback (mờ thẳng khung sống, không có mờ tối
            // thiểu) và có thể thấy chớp mờ nhanh thay vì mượt.
            if !cam.isRecording, !cam.isProcessing {
                freezePreviewForModeSwitch()
            }
            cam.settings.livePhotoOn.toggle()
            cam.settings.save()
            // Bật/tắt Live Photo phải tráo output (Live Photo và movie output
            // loại trừ nhau). setMode bị guard chặn vì chế độ không đổi.
            cam.reconfigure()
        } label: {
            Image(systemName: cam.settings.livePhotoOn ? "livephoto" : "livephoto.slash")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(cam.settings.livePhotoOn ? .yellow : .white)
                .frame(width: 40, height: 44)
        }
    }
 
    private var macroButton: some View {
        Button {
            cam.setMacro(!cam.settings.macroOn)
        } label: {
            Image(systemName: cam.settings.macroOn ? "camera.macro" : "camera.macro.slash")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(cam.settings.macroOn ? .yellow : .white)
                .frame(width: 40, height: 44)
        }
    }
 
    private var usesTorch: Bool { cam.settings.mode.isRecordingMode }
 
    private var isLightActive: Bool {
        usesTorch ? cam.torchOn : cam.settings.flashMode != .off
    }
 
    private var flashIcon: String {
        switch cam.settings.flashMode {
        case .on: "bolt.fill"
        case .off: "bolt.slash.fill"
        default: "bolt.badge.a.fill"
        }
    }
 
    // MARK: Zoom & thanh trượt
 
    private var zoomSelector: some View {
        HStack(spacing: 8) {
            ForEach(cam.zoomStops, id: \.self) { zoomButton($0) }
        }
        .padding(6)
        .background(.black.opacity(0.35), in: Capsule())
        .padding(.bottom, 10)
    }
 
    private func zoomButton(_ value: CGFloat) -> some View {
        let active = abs(cam.displayZoom - value) < 0.05
        let label = value == 0.5 ? "0,5" : String(format: "%g", value)
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { cam.setZoom(value) }
            pinchStart = value
        } label: {
            Text(active ? "\(label)×" : label)
                .font(.system(size: active ? 14 : 13, weight: .semibold))
                .foregroundStyle(active ? .yellow : .white)
                .frame(width: active ? 44 : 34, height: active ? 44 : 34)
                .background(.white.opacity(active ? 0.18 : 0.10), in: Circle())
        }
    }
 
    private var portraitSlider: some View {
        HStack(spacing: 10) {
            Image(systemName: "f.cursive").font(.system(size: 13)).foregroundStyle(.yellow)
            Slider(value: Binding(
                get: { Double(cam.settings.portraitIntensity) },
                set: { cam.settings.portraitIntensity = Float($0) }
            ), in: 0...1, onEditingChanged: { editing in
                // Bản cũ ghi cả 14 khoá UserDefaults mỗi tick kéo; chỉ cần
                // lưu một lần khi thả tay.
                if !editing { cam.settings.save() }
            })
            .tint(.yellow)
            Text("Xoá phông").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 26).padding(.bottom, 6)
    }
 
    // MARK: Chọn chế độ
 
    private var modeSelector: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    Color.clear.frame(width: 60)
                    ForEach(CaptureMode.ordered) { m in
                        Button {
                            if m != cam.settings.mode, !cam.isRecording, !cam.isProcessing {
                                freezePreviewForModeSwitch()
                            }
                            withAnimation(.easeOut(duration: 0.2)) {
                                cam.setMode(m)
                                proxy.scrollTo(m.id, anchor: .center)
                            }
                        } label: {
                            Text(m.label)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(cam.settings.mode == m ? .yellow : .white.opacity(0.6))
                        }
                        .id(m.id)
                    }
                    Color.clear.frame(width: 60)
                }
                .padding(.vertical, 8)
            }
            .onAppear { proxy.scrollTo(cam.settings.mode.id, anchor: .center) }
        }
        .frame(height: 34)
        .padding(.bottom, 6)
    }
 
    // MARK: Thanh dưới
 
    private var bottomBar: some View {
        HStack {
            Button {
                if let url = URL(string: "photos-redirect://") { openURL(url) }
            } label: {
                Group {
                    if let img = cam.lastThumbnail {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.12)
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .opacity(cam.isRecording ? 0 : 1)
            .disabled(cam.isRecording)
 
            Spacer()
            shutterButton
            Spacer()
 
            Button { cam.flipCamera() } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .opacity(cam.isRecording ? 0 : 1)
            .disabled(cam.isRecording || cam.isProcessing)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }
 
    private var shutterButton: some View {
        ZStack {
            Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
 
            if cam.isRecording {
                RoundedRectangle(cornerRadius: cam.isQuickTake ? 29 : 6)
                    .fill(.red)
                    .frame(width: cam.isQuickTake ? 58 : 30, height: cam.isQuickTake ? 58 : 30)
            } else {
                Circle()
                    .fill(cam.settings.mode.isRecordingMode ? .red : .white)
                    .frame(width: 61, height: 61)
                    .scaleEffect(cam.isCapturing || cam.isBursting ? 0.88 : 1.0)
            }
        }
        .animation(.easeOut(duration: 0.15), value: cam.isRecording)
        .animation(.easeOut(duration: 0.1), value: cam.isCapturing)
        .offset(x: shutterDrag)
        .opacity(cam.isProcessing ? 0.4 : 1)
        .contentShape(Circle())
        .gesture(
            // Chạm nhả nhanh → chụp / bật-tắt ghi.
            // Kéo sang trái → chụp liên tiếp.
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard !cam.isProcessing else { return }
                    if value.translation.width < -25 {
                        shutterDrag = max(value.translation.width, -70)
                        if !cam.isBursting && !cam.isRecording { cam.burstBegan() }
                    }
                }
                .onEnded { value in
                    withAnimation(.spring(duration: 0.25)) { shutterDrag = 0 }
                    guard !cam.isProcessing else { return }
                    if cam.isBursting {
                        cam.burstEnded()
                    } else if cam.isQuickTake && cam.isRecording {
                        cam.shutterHoldEnded()
                    } else if abs(value.translation.width) < 12 && abs(value.translation.height) < 12 {
                        cam.shutterTapped()
                    }
                }
        )
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45)
                .onEnded { _ in cam.shutterHoldBegan() }
        )
    }
 
    // MARK: Lớp phủ phụ
 
    private var countdownOverlay: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            Text("\(cam.countdown)")
                .font(.system(size: 110, weight: .thin, design: .rounded))
                .foregroundStyle(.white).shadow(radius: 8)
        }
        .onTapGesture { cam.cancelCountdown() }
        .transition(.opacity)
    }
 
    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().tint(.white).scaleEffect(1.3)
                Text("Đang xuất video…")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
    }
 
    private func statusToast(_ msg: String) -> some View {
        VStack {
            Spacer()
            Text(msg)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.black.opacity(0.7), in: Capsule())
                .padding(.bottom, 150)
        }
        .transition(.opacity)
        .task {
            try? await Task.sleep(for: .seconds(3))
            cam.statusMessage = nil
        }
    }
 
    private func codeBanner(_ code: ScannedCode) -> some View {
        VStack {
            HStack(spacing: 10) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 18))
                    .foregroundStyle(.yellow)
 
                VStack(alignment: .leading, spacing: 2) {
                    Text(code.typeLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    Text(code.value)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
 
                Spacer()
 
                if let url = code.url {
                    Button("Mở") { openURL(url) }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.yellow)
                } else {
                    Button {
                        UIPasteboard.general.string = code.value
                        cam.statusMessage = "Đã sao chép."
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 15))
                    }
                    .foregroundStyle(.yellow)
                }
 
                Button { cam.scannedCode = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 14)
            .padding(.top, 56)
 
            Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
 
    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
 
// MARK: - Bảng cài đặt
 
struct SettingsSheet: View {
    @ObservedObject var cam: CameraManager
    @Binding var isPresented: Bool
 
    var body: some View {
        NavigationStack {
            Form {
                Section("Ảnh") {
                    if cam.supportsProRAW {
                        Picker("Định dạng", selection: Binding(
                            get: { cam.settings.photoFormat },
                            set: { cam.settings.photoFormat = $0; cam.settings.save() }
                        )) {
                            ForEach(PhotoFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
 
                    Picker("Tỉ lệ", selection: Binding(
                        get: { cam.settings.aspect },
                        set: { cam.settings.aspect = $0; cam.settings.save() }
                    )) {
                        ForEach(AspectRatio.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
 
                    Toggle("Live Photo", isOn: Binding(
                        get: { cam.settings.livePhotoOn },
                        set: { cam.settings.livePhotoOn = $0; cam.settings.save(); cam.reconfigure() }
                    ))
                    .disabled(!cam.supportsLivePhoto)
                }
 
                Section {
                    EmptyView()
                } footer: {
                    Text("Live Photo và đường quay video của app hiện chưa dùng chung được, nên khi Live Photo bật thì QuickTake (giữ nút chụp để quay) tạm nghỉ; tắt Live Photo là QuickTake có lại.")
                }
 
                Section("Video") {
                    Picker("Chất lượng", selection: Binding(
                        get: { cam.settings.videoQuality },
                        set: { cam.settings.videoQuality = $0; cam.settings.save(); cam.reconfigure() }
                    )) {
                        ForEach(VideoQuality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
 
                    Picker("Quay chậm", selection: Binding(
                        get: { cam.settings.slomoRate },
                        set: { cam.settings.slomoRate = $0; cam.settings.save() }
                    )) {
                        ForEach(SlomoRate.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
 
                    Picker("Nhịp tua nhanh", selection: Binding(
                        get: { cam.settings.timeLapseInterval },
                        set: { cam.settings.timeLapseInterval = $0; cam.settings.save() }
                    )) {
                        ForEach(TimeLapseInterval.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
 
                Section("Hỗ trợ bố cục") {
                    Toggle("Lưới 3×3", isOn: Binding(
                        get: { cam.settings.gridOn },
                        set: { cam.settings.gridOn = $0; cam.settings.save() }
                    ))
                    Toggle("Thước thăng bằng", isOn: Binding(
                        get: { cam.settings.levelOn },
                        set: { cam.settings.levelOn = $0; cam.settings.save() }
                    ))
                    Toggle("Quét mã QR / mã vạch", isOn: Binding(
                        get: { cam.settings.scanCodesOn },
                        set: { cam.settings.scanCodesOn = $0; cam.settings.save() }
                    ))
                }
 
                Section {
                    Label("Ống tele 77mm đã bị vô hiệu hoá", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } footer: {
                    Text("App dùng cụm Dual Wide (siêu rộng + ống chính). Ống tele không bao giờ được cấp điện, nên OIS của nó không phát ra tiếng và không lọt vào tiếng video.")
                }
            }
            .navigationTitle("Cài đặt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") { isPresented = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}