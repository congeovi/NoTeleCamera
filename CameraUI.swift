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
    /// Vuốt ngang một ngón để đổi chế độ. Dùng CHUNG một
    /// UIPanGestureRecognizer với vuốt dọc chỉnh EV — hướng chốt một lần khi
    /// ngón tay đi đủ xa (xem `Coordinator.Axis`), nên hai việc không giành
    /// nhau. Cử chỉ phải nằm ở đây chứ không phải `.gesture` của SwiftUI, cùng
    /// lý do đã ghi ở trên.
    var onHorizontalDrag: (UIGestureRecognizer.State, CGFloat) -> Void = { _, _ in }
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
        /// Hướng đã chốt của cử chỉ đang chạy. nil = ngón tay chưa đi đủ xa
        /// để biết là vuốt ngang (đổi chế độ) hay vuốt dọc (chỉnh EV).
        enum Axis { case horizontal, vertical }

        /// Ngón tay phải đi đủ quãng này mới chốt được hướng — dưới mức đó
        /// một cú chạm hơi lệch tay chưa bị hiểu thành vuốt.
        static let axisLockDistance: CGFloat = 12

        var parent: CameraPreview
        weak var view: PreviewUIView?
        private var axis: Axis?
        /// Nhánh nào đã thực sự nhận `.began` thì mới được nhận `.ended` —
        /// nhánh chưa từng bắt đầu mà nhận kết thúc thì bên kia làm việc thừa
        /// (hẹn giờ ẩn ô vàng, nhả cờ một-bước của vuốt chế độ).
        private var verticalBegun = false
        private var horizontalBegun = false
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
            var t = g.translation(in: view)

            switch g.state {
            case .began:
                // Chưa biết người dùng định vuốt ngang hay dọc — đo đã.
                axis = nil
                verticalBegun = false
                horizontalBegun = false

            case .changed:
                if axis == nil {
                    // Ưu tiên dọc 1,5×: chỉnh EV chỉ có đúng cử chỉ này, còn
                    // vuốt ngang là việc mới nên nhường.
                    guard max(abs(t.x), abs(t.y)) >= Self.axisLockDistance else { return }
                    axis = abs(t.x) > abs(t.y) * 1.5 ? .horizontal : .vertical
                    // Dời mốc về đúng điểm chốt hướng, nên mọi giá trị gửi đi
                    // sau đây đều tính từ đó. Không dời thì quãng đã tiêu để
                    // chốt hướng (cộng cả slop sẵn có của UIPanGestureRecognizer)
                    // bị tính luôn vào giá trị đầu tiên — EV nhảy sẵn một nấc
                    // ngay khi vừa bắt đầu vuốt, trong khi nó phải bám 1:1
                    // theo ngón tay.
                    g.setTranslation(.zero, in: view)
                    t = .zero
                }
                if axis == .vertical {
                    if !verticalBegun {
                        verticalBegun = true
                        parent.onVerticalDrag(.began, t.y)
                    }
                    parent.onVerticalDrag(.changed, t.y)
                } else {
                    if !horizontalBegun {
                        horizontalBegun = true
                        parent.onHorizontalDrag(.began, t.x)
                    }
                    parent.onHorizontalDrag(.changed, t.x)
                }

            default:
                // `.ended` / `.cancelled` / `.failed` — chỉ báo cho nhánh đã
                // thực sự bắt đầu, và chốt lại hướng cho cử chỉ kế tiếp.
                if verticalBegun {
                    verticalBegun = false
                    parent.onVerticalDrag(g.state, t.y)
                }
                if horizontalBegun {
                    horizontalBegun = false
                    parent.onHorizontalDrag(g.state, t.x)
                }
                axis = nil
            }
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
    /// Nửa quãng đường của mặt trời trên ray = mức EV tối đa (±2).
    ///
    /// Không còn khớp với `CameraManager.evDragPointsPerStop` — cố ý: icon
    /// đi trên đoạn ray ngắn này, còn ngón tay phải vuốt quãng dài hơn nhiều
    /// thì EV mới chỉnh được mịn, giống Camera gốc.
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
    var orientationAngle: Double = 0
    /// Độ mờ theo độ chúc của máy, do CameraManager tính.
    var pitchFade: Double = 1

    @State private var isHiddenAfterLevel = false
    @State private var hideTask: Task<Void, Never>? = nil
    @State private var hasTriggeredHaptic = false
    /// Giữ lại một generator đã hâm nóng để cú rung khớp đúng lúc thước đổi
    /// vàng. Tạo trong onAppear chứ không đặt giá trị mặc định cho @State: struct
    /// này bị dựng lại 30 lần/giây theo nhịp CoreMotion, mà biểu thức mặc định
    /// của @State thì chạy theo mỗi lần dựng dù chỉ dùng lần đầu.
    @State private var haptic: UIImpactFeedbackGenerator?

    // Kích thước thanh cân bằng chuẩn iOS Camera (tổng dài 180pt)
    private let sideWidth: CGFloat = 36
    private let centerWidth: CGFloat = 84
    private let gap: CGFloat = 12
    private let barHeight: CGFloat = 1.5

    // Mờ dần theo góc lệch thay vì cắt cứng ở một ngưỡng: rõ hoàn toàn tới 12°,
    // nhạt dần tới hết ở 38°. Không đặt mốc tắt sát 45° vì đúng ở 45° thì mốc
    // thăng bằng gần nhất đổi sang trục khác, thước sẽ nhảy 90° — để nó tắt
    // xong trước khi tới đó.
    private let fadeStartAngle: Double = 12
    private let fadeEndAngle: Double = 38

    private var totalWidth: CGFloat {
        (sideWidth * 2) + (gap * 2) + centerWidth
    }

    /// Mờ dần theo góc lệch. Giá trị này đổi liên tục theo từng khung CoreMotion
    /// nên tự mượt, không cần (và không được) gắn animation vào.
    private var angleFade: Double {
        let deviation = abs(roll)
        if deviation <= fadeStartAngle { return 1 }
        if deviation >= fadeEndAngle { return 0 }
        return 1 - (deviation - fadeStartAngle) / (fadeEndAngle - fadeStartAngle)
    }

    /// Sắp cân bằng — dùng để hâm nóng haptic trước khi thật sự cần rung.
    private var isNearLevel: Bool {
        abs(roll) < 5
    }

    var body: some View {
        ZStack {
            // Khi chưa cân bằng: 1 thanh gồm 3 đoạn màu trắng
            // (2 vạch mốc cố định 2 bên + 1 đoạn giữa xoay theo góc chân trời)
            HStack(spacing: gap) {
                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: sideWidth, height: barHeight)

                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: centerWidth, height: barHeight)
                    .rotationEffect(.degrees(-roll))

                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: sideWidth, height: barHeight)
            }
            .opacity(isLevel ? 0 : 1)

            // Khi đã cân bằng: Nối liền thành 1 vạch vàng duy nhất dài 180pt
            Capsule()
                .fill(Color.yellow)
                .frame(width: totalWidth, height: barHeight)
                .opacity(isLevel ? 1 : 0)
        }
        .shadow(color: .black.opacity(0.4), radius: 1, x: 0, y: 0.5)
        .rotationEffect(.degrees(-orientationAngle))
        // Mờ dần theo góc: liên tục, cố tình không animate.
        .opacity(angleFade * min(max(pitchFade, 0), 1))
        // Tự ẩn sau khi cân bằng: animate bằng withAnimation trong
        // handleLevelChange để hai chiều có thời lượng khác nhau (ẩn chậm,
        // hiện lại tức thì).
        .opacity(isHiddenAfterLevel ? 0 : 1)
        .animation(.easeInOut(duration: 0.3), value: orientationAngle)
        .animation(.easeOut(duration: 0.15), value: isLevel)
        .allowsHitTesting(false)
        .onChange(of: isLevel) { _, newValue in
            handleLevelChange(newValue, allowHaptic: true)
        }
        .onChange(of: isNearLevel) { _, near in
            if near { haptic?.prepare() }
        }
        .onAppear {
            if haptic == nil { haptic = UIImpactFeedbackGenerator(style: .light) }
            haptic?.prepare()
            // Lần đầu hiện chỉ dựng đúng trạng thái, không rung: người dùng vừa
            // bật setting chứ không vừa căn được máy.
            if isLevel { handleLevelChange(true, allowHaptic: false) }
        }
        .onDisappear {
            hideTask?.cancel()
            hideTask = nil
        }
    }

    private func handleLevelChange(_ leveled: Bool, allowHaptic: Bool) {
        if leveled {
            if !hasTriggeredHaptic {
                if allowHaptic {
                    haptic?.impactOccurred()
                    haptic?.prepare()
                }
                hasTriggeredHaptic = true
            }
            hideTask?.cancel()
            hideTask = Task {
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.35)) {
                        isHiddenAfterLevel = true
                    }
                }
            }
        } else {
            hideTask?.cancel()
            hideTask = nil
            hasTriggeredHaptic = false
            withAnimation(.easeIn(duration: 0.15)) {
                isHiddenAfterLevel = false
            }
        }
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
    /// Không gian tên cho hiệu ứng morph của Liquid Glass: mốc chế độ đang chọn
    /// trượt từ ô này sang ô kia thay vì tắt phụt rồi bật lại, như Camera gốc.
    @Namespace private var glassNamespace
    @State private var shutterDrag: CGFloat = 0
    /// Cú vuốt ngang trên khung ngắm chỉ được đổi ĐÚNG MỘT chế độ: cờ này chốt
    /// lại ngay sau bước đầu tiên và chỉ mở khi nhấc tay.
    @State private var modeSwipeConsumed = false
    @State private var isPinching = false
    @State private var shutterFlashOpacity: Double = 0
    @State private var previewUIView: PreviewUIView?
    @State private var modeFreezeFrame: UIImage?
    /// Bán kính mờ đang áp lên ảnh đóng băng khi chuyển chế độ: mờ dần vào
    /// ngay khi bấm mode, giữ đến khi camera sẵn sàng rồi tan về 0.
    @State private var switchBlur: CGFloat = 0
    /// Bán kính mờ tối đa khi chuyển chế độ. 64pt cùng opaque: true che hẳn
    /// chi tiết khung cảnh bên dưới, cho ra khối bokeh mịn.
    ///
    /// Một lượt blur duy nhất, đừng chồng thêm: hai blur Gauss nối tiếp cộng
    /// theo bình phương (`sqrt(r1² + r2²)`) chứ không cộng thẳng, nên lượt thứ
    /// hai tốn nguyên một vòng render mà gần như không làm mờ thêm. Tệ hơn,
    /// lượt non-opaque chạy trước sẽ hút pixel trong suốt ngoài biên làm mép
    /// màn hình nhạt dần — đúng thứ opaque: true sinh ra để chặn, và lượt sau
    /// không cứu lại được.
    private static let modeSwitchBlurRadius: CGFloat = 64
    /// Bao nhiêu point vuốt ngang thì đổi một chế độ, tính TỪ LÚC CHỐT HƯỚNG
    /// (`CameraPreview.Coordinator` đã dời mốc về đó). 48 point ở đây cộng 12
    /// point chốt hướng là đúng 60 point ngón tay thật sự phải đi — quãng của
    /// một cú vuốt dứt khoát, mà cú chạm lấy nét hơi lệch tay thì không tới.
    private static let modeSwipeThreshold: CGFloat = 48
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
                }
                bottomCluster
            }
 
            if let code = cam.scannedCode, !cam.isRecording { codeBanner(code) }
            if cam.countdown > 0 { countdownOverlay }
            if cam.isProcessing { processingOverlay }
            if let msg = cam.statusMessage { statusToast(msg) }
 
            // Nháy trắng ngay lúc bấm máy, giống Camera gốc — bằng chứng trực
            // quan rằng đã chụp, vì isCapturing đôi khi trả về quá nhanh để mắt
            // kịp thấy nút thu nhỏ lại. Ở lớp ngoài cùng chứ không nằm trong
            // previewArea: khung preview đã bị khoá theo tỉ lệ file nên nháy
            // phải phủ cả màn hình như Camera gốc, không chỉ phủ khung ảnh.
            Color.white
                .opacity(shutterFlashOpacity)
                .allowsHitTesting(false)
                .ignoresSafeArea()

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
                // Vuốt ngang để đổi chế độ. Cử chỉ dùng chung một
                // UIPanGestureRecognizer với vuốt dọc chỉnh EV — Coordinator đã
                // chốt hướng nên ở đây chỉ còn một việc.
                onHorizontalDrag: { state, translationX in
                    switch state {
                    case .changed: handleModeSwipe(translationX)
                    // Nhấc tay / bị huỷ → mở khoá cho cú vuốt kế tiếp. Đây là
                    // chỗ DUY NHẤT nhả cờ, và thế là đủ: cờ chỉ chốt được khi
                    // nhánh ngang đã bắt đầu, mà nhánh đã bắt đầu thì chắc chắn
                    // nhận được kết thúc của chính cử chỉ đó.
                    case .ended, .cancelled, .failed: modeSwipeConsumed = false
                    default: break
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
            .blur(radius: (modeFreezeFrame == nil && cam.isModeTransitioning) ? Self.modeSwitchBlurRadius : 0,
                  opaque: true)
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
                    .blur(radius: switchBlur, opaque: true)
                    .opacity(freezeOpacity)
                    .allowsHitTesting(false)
                    .transition(.identity)
            }

            if cam.settings.gridOn { GridOverlay() }
            if cam.settings.levelOn {
                LevelOverlay(roll: cam.rollAngle,
                             isLevel: cam.isLevel,
                             orientationAngle: cam.orientationAngle,
                             pitchFade: cam.levelPitchFade)
            }
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

        }
        // Khung preview khoá đúng tỉ lệ file sẽ ghi ra (xem
        // `CameraManager.outputAspectRatio`): 1:1 → khung vuông, 16:9 và mọi
        // chế độ quay → khung 9:16, 4:3 → khung 3:4. aspectRatio(.fit) canh
        // giữa khung trong màn hình nên hở ra hai dải đen trên/dưới; khung nào
        // dài thì tràn xuống dưới cụm nút, nút vẫn nằm trên như cũ.
        //
        // videoGravity = .resizeAspectFill được giữ nguyên: nó đúng bằng phép
        // "cắt canh giữa" mà savePhoto dùng, nên khung vuông / 16:9 nhìn thấy
        // đúng vùng mà file sẽ chứa. Riêng 4:3 thì luồng preview vốn đã 4:3
        // (preset .photo) nên fill = fit, thấy trọn khung.
        .aspectRatio(cam.outputAspectRatio, contentMode: .fit)
        // Ảnh đóng băng chụp lúc đổi chế độ mang tỉ lệ của khung cũ; để .fill
        // trong khung mới thì nó tràn ra ngoài nếu không chặn.
        .clipShape(Rectangle())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        // "Đổi tỉ lệ có hiệu ứng": khung co giãn theo lúc đổi tỉ lệ hoặc đổi
        // chế độ, không nhảy một cái. Chỉ chạy khi chính tỉ lệ đổi nên lớp mờ
        // chuyển chế độ (animation riêng, gắn sát CameraPreview) vẫn giữ nhịp.
        .animation(.easeInOut(duration: 0.25), value: cam.outputAspectRatio)
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
 
    // MARK: Đổi chế độ

    /// Đổi chế độ kèm hiệu ứng chuyển — dùng chung cho cả nút bấm trên thanh
    /// chế độ lẫn cú vuốt ngang trên khung ngắm, nên hai đường không thể lệch
    /// hành vi nhau. Đây cũng là NƠI DUY NHẤT giữ điều kiện được phép đổi, các
    /// chỗ gọi chỉ đọc kết quả trả về chứ đừng kiểm lại.
    ///
    /// Điều kiện được phép đổi nằm ở `CameraManager.canPerform(.changeMode)`,
    /// không chép lại ở đây: chép là có hai bản luật, và bản ở UI sẽ trôi khỏi
    /// bản ở manager ngay lần sửa cổng tiếp theo.
    ///
    /// - Returns: `true` nếu yêu cầu đổi chế độ được nhận. Đang có một lần
    ///   chuyển chạy dở thì manager giữ nó lại làm `pendingMode` và áp ngay khi
    ///   xong — vẫn tính là nhận.
    @discardableResult
    private func applyModeSelection(_ m: CaptureMode) -> Bool {
        guard m != cam.settings.mode, cam.canPerform(.changeMode) else { return false }
        freezePreviewForModeSwitch()
        withAnimation(.easeOut(duration: 0.2)) { cam.setMode(m) }
        return true
    }

    /// Vuốt sang trái → chế độ kế tiếp, sang phải → chế độ trước. Một bước cho
    /// mỗi cử chỉ như Camera gốc; kẹp ở hai đầu, không xoay vòng.
    private func handleModeSwipe(_ translationX: CGFloat) {
        guard !modeSwipeConsumed else { return }
        guard abs(translationX) >= Self.modeSwipeThreshold else { return }
        let list = CaptureMode.ordered
        guard let i = list.firstIndex(of: cam.settings.mode) else { return }
        let next = translationX < 0 ? i + 1 : i - 1
        guard list.indices.contains(next) else { return }
        // Chỉ chốt cờ và rung khi chế độ ĐÃ đổi thật — đang quay / đang xuất
        // file / đang chụp liên tiếp thì không rung suông. Chốt sau vẫn kịp:
        // applyModeSelection chạy đồng bộ trên main actor, .changed kế tiếp của
        // cử chỉ phải đợi vòng run loop sau nên không thể chen vào giữa.
        guard applyModeSelection(list[next]) else { return }
        modeSwipeConsumed = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Chụp khung hình cuối cùng trước khi đổi mode và giữ nó phủ lên preview.
    /// Bắt đầu hiệu ứng chuyển chế độ: chốt khung hình cuối làm nền và mờ dần
    /// vào ngay khi bấm mode. Ảnh đóng băng che đúng lúc AVFoundation
    /// renegotiate preset/format; lớp mờ chỉ tan khi CameraManager báo camera
    /// đã sẵn sàng (xem onChange của isModeTransitioning).
    private func freezePreviewForModeSwitch() {
        // Lần chuyển trước còn đang phủ ảnh đóng băng thì GIỮ NGUYÊN ảnh đó.
        // snapshotImage() chỉ chụp previewLayer chứ không chụp lớp phủ, mà lúc
        // này layer đang là khung AVFoundation renegotiate dở — chụp đè là thay
        // ảnh đẹp bằng khung đen. Vuốt liên tiếp (ẢNH → VIDEO là hai bước) làm
        // tình huống này thành thường gặp chứ không còn hiếm như hồi chỉ có nút.
        if modeFreezeFrame == nil {
            guard let image = previewUIView?.snapshotImage() else { return }
            modeFreezeFrame = image
            switchBlur = 0
        }
        modeSwitchGeneration += 1
        let gen = modeSwitchGeneration
        modeSwitchStartedAt = Date()
        // Kể cả khi giữ ảnh cũ: lần tan mờ trước có thể đang chạy dở (độ đục
        // đang rượt về 0), lần chuyển mới phải kéo nó đục trở lại.
        freezeOpacity = 1
        withAnimation(.easeIn(duration: 0.15)) { switchBlur = Self.modeSwitchBlurRadius }
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
 
    /// Cụm nút giữa thanh trên: đèn · Live Photo · tỉ lệ khung. Đủ 3 nút ở chế
    /// độ Ảnh trên máy có Live Photo; Chân dung và Video chỉ còn nút đèn, Quay
    /// chậm là đèn + mốc fps. Nút hẹn giờ và lối vào Cài đặt đã dời xuống
    /// `menuButton` ở hàng nút chụp, nên thanh trên chỉ còn việc của camera.
    private var topBar: some View {
        VStack(spacing: 10) {
            // Container riêng cho cụm nút trên: các mảng kính cạnh nhau được
            // gộp thành một lượt render. spacing 12 < khoảng cách thật 26 nên
            // ba nút vẫn là ba viên tách bạch, không dính thành một khối.
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 26) {
                    lightButton

                    if !cam.isRecording {
                        if cam.settings.mode == .slomo {
                            slomoRateButton
                        } else if cam.settings.mode == .photo {
                            if cam.supportsLivePhoto { livePhotoButton }
                            aspectButton
                        }
                    }
                }
            }
            .frame(height: 46)
 
            // Đồng hồ quay và huy hiệu AE/AF LOCK nằm dưới cụm nút chứ không chen
            // vào giữa: cụm nút giờ đã canh giữa màn hình, nhét thêm là lệch.
            if cam.isRecording {
                recordBadge
            } else if cam.isLocked {
                lockBadge
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
    }
 
    /// Nút đèn: xoay vòng mức flash ở chế độ ảnh, bật/tắt đèn pin ở chế độ quay.
    private var lightButton: some View {
        Button {
            usesTorch ? cam.setTorch(!cam.torchOn) : cam.cycleFlash()
        } label: {
            Image(systemName: usesTorch ? (cam.torchOn ? "bolt.fill" : "bolt.slash.fill") : flashIcon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isLightActive ? .yellow : .white)
                .frame(width: 48, height: 46)
                .contentShape(Circle())
        }
        .glassEffect(isLightActive ? Glass.regular.tint(.yellow.opacity(0.55)).interactive(true)
                                   : Glass.regular.interactive(true),
                     in: Circle())
    }
 
    private var recordBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(.red).frame(width: 8, height: 8)
            Text(timeString(cam.recordDuration))
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule())
    }
 
    /// Bấm vào là mở khoá AE/AF, như nút cũ ở mép phải thanh trên.
    private var lockBadge: some View {
        Button { cam.unlock() } label: {
            Text("AE/AF LOCK")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .contentShape(Capsule())
        }
        .glassEffect(.regular.tint(.yellow).interactive(true), in: Capsule())
    }
 
    /// Hẹn giờ chỉ có tác dụng ở hai chế độ ảnh: `CameraManager.shutterTapped()`
    /// bắt đầu/dừng ghi ngay và không ngó tới `timerOption` ở ba chế độ quay.
    /// Nên ở chế độ quay thì không hiện mục chọn, và cũng không sáng chấm vàng
    /// — bản trước bày ra cả hai, hứa một cái đếm ngược không bao giờ chạy.
    private var timerApplies: Bool { !cam.settings.mode.isRecordingMode }

    /// Menu ba chấm ở hàng nút chụp: chứa hẹn giờ và lối vào Cài đặt. Thanh trên
    /// chỉ còn cụm nút camera nên hai thứ đó phải ở đây, đúng như ảnh mẫu.
    private var menuButton: some View {
        let timerOn = timerApplies && cam.settings.timerOption != .off
        return Menu {
            if timerApplies {
                Picker("Hẹn giờ", selection: Binding(
                    get: { cam.settings.timerOption },
                    set: { cam.settings.timerOption = $0; cam.settings.save() }
                )) {
                    ForEach(TimerOption.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }

            Button { showSettings = true } label: {
                Label("Cài đặt", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(timerOn ? .yellow : .white)
                .frame(width: 46, height: 46)
                .overlay(alignment: .topTrailing) {
                    // Hẹn giờ giờ nằm trong menu nên phải có chấm vàng báo hiệu,
                    // không thì bấm máy xong mới giật mình thấy đếm ngược.
                    if timerOn {
                        Circle().fill(.yellow)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(.black.opacity(0.45), lineWidth: 1))
                    }
                }
                .contentShape(Circle())
        }
        .glassEffect(.regular.interactive(true), in: Circle())
    }

    /// Khung THẬT SỰ sẽ ghi ra file. Live Photo và ProRAW không cắt được nên
    /// ảnh vẫn ra 4:3 dù người dùng chọn khung khác — quy tắc nằm một chỗ ở
    /// `CameraManager.aspectCropSkipped`, đây chỉ đọc lại.
    private var effectiveAspect: AspectRatio {
        cam.aspectCropSkipped ? .r4x3 : cam.settings.aspect
    }

    /// Nút tỉ lệ khung: xoay vòng 4:3 → 16:9 → 1:1. Nhãn hiện khung đang áp dụng
    /// thật, nên khi Live Photo hoặc ProRAW đang giữ ảnh ở 4:3 thì nút mờ đi và
    /// bấm vào chỉ báo lý do — không hứa hão một khung mà file sẽ không có.
    ///
    /// Vàng = đang lệch khỏi mặc định, đúng quy ước của nút đèn và nút Live
    /// Photo bên cạnh. 4:3 là mặc định nên để trắng.
    private var aspectButton: some View {
        let locked = cam.aspectCropSkipped
        let isDefault = effectiveAspect == .r4x3
        return Button {
            let all = AspectRatio.allCases
            let idx = all.firstIndex(of: cam.settings.aspect) ?? 0
            cam.settings.aspect = all[(idx + 1) % all.count]
            cam.settings.save()
            // Lựa chọn vẫn được lưu như trước; chỉ nói thêm vì sao chưa thấy
            // khung đổi — trước đây phải mở Cài đặt mới đọc được dòng nhắc này.
            if let reason = cam.aspectCropSkippedReason { cam.statusMessage = reason }
        } label: {
            Text(effectiveAspect.rawValue)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(isDefault ? .white : .yellow)
                .frame(width: 48, height: 46)
                .contentShape(Circle())
        }
        .opacity(locked ? 0.5 : 1)
        .glassEffect(isDefault ? Glass.regular.interactive(true)
                               : Glass.regular.tint(.yellow.opacity(0.55)).interactive(true),
                     in: Circle())
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
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(cam.settings.livePhotoOn ? .yellow : .white)
                .frame(width: 48, height: 46)
                .contentShape(Circle())
        }
        .glassEffect(cam.settings.livePhotoOn ? Glass.regular.tint(.yellow.opacity(0.55)).interactive(true)
                                             : Glass.regular.interactive(true),
                     in: Circle())
    }
 
    private var slomoRateButton: some View {
        Button {
            let next: SlomoRate = cam.settings.slomoRate == .x240 ? .x120 : .x240
            cam.settings.slomoRate = next
            cam.settings.save()
            cam.reconfigure()
        } label: {
            // Hiện mức ĐANG chạy, không phải mức đã chọn: camera trước chỉ
            // đạt 120fps nên hai giá trị có thể lệch nhau, và người dùng cần
            // thấy đúng thứ máy sắp quay.
            Text(cam.activeSlomoFps.map { "\(Int($0.rounded())) fps" } ?? cam.settings.slomoRate.rawValue)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.yellow)
                .padding(.horizontal, 10)
                .frame(height: 46)
                .contentShape(Capsule())
        }
        .glassEffect(.regular.tint(.yellow.opacity(0.4)).interactive(true), in: Capsule())
    }

    // MARK: Hàng nút chụp & hàng chế độ

    /// Hàng dưới cùng của màn hình: thumbnail · pill chế độ · nút đổi camera.
    /// Hai nút hai bên cùng bề rộng nên pill luôn nằm chính giữa.
    private var modeRow: some View {
        HStack(spacing: 12) {
            thumbnailButton

            modeSelector

            flipButton
        }
        .padding(.horizontal, Self.bottomRowInset)
    }

    /// Lề ngang dùng chung cho hàng nút chụp và hàng chế độ, để nút ba chấm nằm
    /// thẳng cột với nút đổi camera ngay dưới nó.
    private static let bottomRowInset: CGFloat = 20
 
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
 
    // MARK: Hàng nút chụp & zoom
 
    /// Hàng nút chụp: nút chụp ở giữa, menu ba chấm bên phải. Bên trái để trống
    /// — chỗ đó Camera gốc dành cho nút macro, còn app này đã bỏ macro nhanh
    /// khỏi màn hình chính (macro chỉ còn công tắc trong Cài đặt).
    ///
    /// Dùng ZStack chứ không phải HStack + Spacer: nút chụp phải nằm đúng tâm
    /// màn hình dù nút bên phải to nhỏ thế nào.
    private var shutterRow: some View {
        ZStack {
            shutterButton

            HStack {
                Spacer()
                menuButton
                    .opacity(cam.isRecording ? 0 : 1)
                    .disabled(cam.isRecording || cam.isProcessing)
            }
        }
        .padding(.horizontal, Self.bottomRowInset)
    }

    /// Bọc hàng nút chụp và hàng chế độ trong một khung kính chung để iOS gộp
    /// một lượt render.
    ///
    /// `spacing` phải NHỎ hơn khoảng hở thật giữa nút ba chấm và nút đổi camera
    /// ngay dưới nó, nếu không hai viên kính hoà thành một cục dọc. Khoảng hở
    /// đó = (74 − 46)/2 + `VStack.spacing` = 14 + 12 = 26pt, nên 10 là an toàn.
    ///
    /// `modeRow` được GIỮ CHỖ chứ không gỡ khỏi cây khi đang quay: gỡ hẳn thì
    /// nút chụp tụt xuống sát mép safe area rồi nhảy ngược lên lúc quay xong.
    private var bottomCluster: some View {
        let hideModeRow = cam.isRecording || cam.isProcessing
        return GlassEffectContainer(spacing: 10) {
            VStack(spacing: 12) {
                shutterRow

                modeRow
                    .opacity(hideModeRow ? 0 : 1)
                    .disabled(hideModeRow)
                    .animation(.easeOut(duration: 0.2), value: hideModeRow)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    /// Chỉ mốc đang chọn có mảng kính thật, nhưng vẫn bọc container: mốc sáng
    /// mang một mã hiệu cố định nên nó TRƯỢT sang mốc mới khi đổi zoom, giống
    /// khối sáng của pill chế độ.
    private var zoomSelector: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(cam.zoomStops, id: \.self) { zoomButton($0) }
            }
        }
        .padding(.bottom, 12)
    }

    /// Mốc đang chọn mới có nền kính tối + chữ vàng như ảnh mẫu; các mốc còn lại
    /// chỉ là chữ trơn kèm bóng đổ nhẹ cho đọc được trên nền sáng.
    private func zoomButton(_ value: CGFloat) -> some View {
        let active = abs(cam.displayZoom - value) < 0.05
        let label = value == 0.5 ? "0,5" : String(format: "%g", value)
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { cam.setZoom(value) }
            pinchStart = value
        } label: {
            Text(active ? "\(label)×" : label)
                .font(.system(size: active ? 15 : 13, weight: active ? .bold : .semibold))
                .foregroundStyle(active ? .yellow : .white)
                .shadow(color: .black.opacity(active ? 0 : 0.45), radius: 3)
                .frame(width: active ? 56 : 42, height: 34)
                .contentShape(Capsule())
        }
        .glassEffect(active ? Glass.regular.tint(.black.opacity(0.5)).interactive(true)
                            : Glass.identity,
                     in: Capsule())
        .glassEffectID(active ? Self.zoomHighlightID : "zoom-\(value)", in: glassNamespace)
        .disabled(!cam.canPerform(.zoom))
    }

    /// Mã hiệu cố định của mảng kính "mốc zoom đang chọn" (xem `zoomButton`).
    private static let zoomHighlightID = "zoom-highlight"
 
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
 
    /// Pill chế độ: 5 mốc cuộn ngang trong một viên kính, mốc đang chọn có nền
    /// kính sáng hơn + chữ vàng. Giữ nguyên hành vi cũ: tự canh giữa mốc đang
    /// chọn dù đổi bằng nút hay bằng cú vuốt ngang trên khung ngắm.
    private var modeSelector: some View {
        // Bề rộng pill phải đo được thì mới tính nổi khoảng đệm hai đầu: hằng số
        // cũ (56pt) nhỏ hơn mức cần (~77pt ở iPhone 13 Pro) nên `scrollTo` bị
        // kẹp ở biên nội dung và hai mốc TUA NHANH / CHÂN DUNG không bao giờ
        // canh được vào giữa.
        GeometryReader { geo in
            modePill(width: geo.size.width)
        }
        .frame(height: 40)
        .frame(maxWidth: .infinity)
    }

    private func modePill(width: CGFloat) -> some View {
        // Nửa bề rộng pill luôn ĐỦ để canh giữa mốc đầu và mốc cuối, dù nhãn dài
        // ngắn thế nào: mốc rộng tối đa bằng pill, nên cần nhiều nhất là
        // (pill − mốc)/2 ≤ pill/2. Dư ra chỉ là khoảng trống cuộn được, vô hại.
        let inset = max(width / 2, 0)

        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // Container CHỈ bọc các mốc. Kính nền của pill nằm ngoài, nếu
                // để chung thì hai mảng chồng nhau bị hoà làm một cục kính dày
                // thay vì "khối sáng trượt trên đường ray".
                GlassEffectContainer(spacing: 0) {
                    HStack(spacing: 4) {
                        // Hai khoảng đệm trong suốt để mốc đầu và mốc cuối vẫn canh
                        // được vào giữa pill — cuộn không bị kẹp ở hai đầu.
                        Color.clear.frame(width: inset)

                        ForEach(CaptureMode.ordered) { m in
                            Button {
                                if m == cam.settings.mode {
                                    // Bấm lại chế độ đang chọn không đổi gì, nhưng
                                    // vẫn canh giữa lại thanh — như bản cũ làm.
                                    withAnimation(.easeOut(duration: 0.25)) {
                                        proxy.scrollTo(m.id, anchor: .center)
                                    }
                                } else {
                                    applyModeSelection(m)
                                }
                            } label: {
                                Text(m.label)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(cam.settings.mode == m ? .yellow : .white.opacity(0.75))
                                    .padding(.horizontal, 10)
                                    .frame(height: 32)
                                    .contentShape(Capsule())
                            }
                            .id(m.id)
                            // Khối kính của mốc đang chọn mang ĐÚNG một mã hiệu cố
                            // định, nên khi đổi chế độ nó "trượt" sang ô mới thay vì
                            // tắt phụt rồi bật lại — GlassEffectContainer lo phần
                            // morph. Mốc không chọn dùng Glass.identity nên không
                            // sinh thêm mảng kính nào.
                            .glassEffect(cam.settings.mode == m
                                         ? Glass.regular.tint(.white.opacity(0.22)).interactive(true)
                                         : Glass.identity,
                                         in: Capsule())
                            .glassEffectID(cam.settings.mode == m ? Self.modeHighlightID : m.id,
                                           in: glassNamespace)
                        }

                        Color.clear.frame(width: inset)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }
            .frame(height: 40)
            // ScrollView clip theo hình chữ nhật, không theo capsule của kính —
            // thiếu dòng này thì chữ của mốc đầu/cuối tràn ra ngoài hai đầu bo.
            .clipShape(Capsule())
            .glassEffect(.regular, in: Capsule())
            .onAppear { proxy.scrollTo(cam.settings.mode.id, anchor: .center) }
            // Chế độ có thể đổi từ nút bấm hoặc từ cú vuốt ngang trên khung
            // ngắm — bám theo `settings.mode` để thanh luôn canh giữa đúng chế
            // độ, không phụ thuộc nguồn đổi.
            .onChange(of: cam.settings.mode) { _, m in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(m.id, anchor: .center) }
            }
        }
    }

    /// Mã hiệu cố định của mảng kính "mốc chế độ đang chọn" (xem `modeSelector`).
    private static let modeHighlightID = "mode-highlight"
 
    // MARK: Thanh dưới
 
    /// Thumbnail tròn ở góc trái hàng dưới: bấm để mở app Ảnh.
    private var thumbnailButton: some View {
        Button {
            if let url = URL(string: "photos-redirect://") { openURL(url) }
        } label: {
            Group {
                if let img = cam.lastThumbnail {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.15)
                        .overlay(
                            Image(systemName: "photo")
                                .font(.system(size: 16))
                                .foregroundStyle(.white.opacity(0.75))
                        )
                }
            }
            .frame(width: 46, height: 46)
            .clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
            .contentShape(Circle())
        }
    }

    // Cả hai nút không cần tự ẩn / tự khoá khi đang quay hoặc đang xuất file:
    // `bottomCluster` đã làm việc đó cho cả `modeRow`.
    private var flipButton: some View {
        Button {
            cam.flipCamera()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .contentShape(Circle())
        }
        .glassEffect(.regular.interactive(true), in: Circle())
        // CameraManager.flipCamera() tự gác cổng này rồi, nhưng disable ở đây
        // để không có khoảng bấm-mà-không-thấy-gì-xảy-ra. Hỏi thẳng cùng một
        // cổng thay vì đọc `isModeTransitioning`: cổng còn chặn cả lúc đang
        // chụp liên tiếp, mà lớp mờ thì không.
        .disabled(!cam.canPerform(.flip))
        .opacity(cam.canPerform(.flip) ? 1 : 0.4)
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
                    guard !cam.isProcessing, cam.canPerform(.shutter) else { return }
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
                        // cam.shutterTapped() tự gác cổng canPerform(.shutter);
                        // vẫn gọi thẳng ở đây, không thêm điều kiện — dừng quay
                        // (isRecording) phải luôn bấm được kể cả khi một cờ
                        // khác đang dở dang.
                        cam.shutterTapped()
                    }
                }
        )
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45)
                .onEnded { _ in
                    guard cam.canPerform(.quickTake) else { return }
                    cam.shutterHoldBegan()
                }
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
                .padding(.bottom, 190)
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
            .padding(.top, 64)
 
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

                    // Macro giờ chỉ còn ở đây: màn hình chính đã bỏ nút bông hoa
                    // để hàng nút chụp gọn như ảnh mẫu, nên công tắc này là lối
                    // duy nhất để bật/tắt macro. Điều kiện bật vẫn y như nút cũ
                    // (§9) — `macroAvailable` giữ cả ba vế, không chỉ mỗi cờ
                    // năng lực.
                    Toggle("Macro", isOn: Binding(
                        get: { cam.settings.macroOn },
                        set: { cam.setMacro($0) }
                    ))
                    .disabled(!cam.macroAvailable)
                }

                Section {
                    EmptyView()
                } footer: {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Live Photo và đường quay video của app hiện chưa dùng chung được, nên khi Live Photo bật thì QuickTake (giữ nút chụp để quay) tạm nghỉ; tắt Live Photo là QuickTake có lại.")
                        // Khung preview đứng ở 4:3 đúng như file sẽ lưu, nói ra để
                        // không tưởng chức năng đổi tỉ lệ hỏng.
                        if let notice = cam.aspectCropSkippedReason { Text(notice) }
                        // Công tắc macro mờ đi khá dễ gặp (đang quay, đang dùng
                        // camera trước), nói lý do ngay cạnh nó.
                        if cam.supportsMacro && !cam.macroAvailable {
                            Text("Macro chỉ bật được ở chế độ Ảnh với camera sau.")
                        }
                    }
                }
 
                Section("Video") {
                    Picker("Chất lượng", selection: Binding(
                        get: { cam.settings.videoQuality },
                        // Chất lượng chỉ tác động tới preset của chế độ Video;
                        // ở chế độ khác dựng lại session chỉ tổ nháy preview.
                        set: {
                            cam.settings.videoQuality = $0
                            cam.settings.save()
                            if cam.settings.mode == .video { cam.reconfigure() }
                        }
                    )) {
                        ForEach(VideoQuality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
 
                    Picker("Quay chậm", selection: Binding(
                        get: { cam.settings.slomoRate },
                        set: {
                            cam.settings.slomoRate = $0
                            cam.settings.save()
                            if cam.settings.mode == .slomo { cam.reconfigure() }
                        }
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