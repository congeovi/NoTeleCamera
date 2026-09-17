//
//  CaptureTypes.swift
//  NoTeleCamera — Giai đoạn 3
//
//  Các kiểu dữ liệu dùng chung và phần ghi nhớ cài đặt.
//
 
import AVFoundation
import SwiftUI
 
// MARK: - Chế độ chụp
 
enum CaptureMode: String, CaseIterable, Identifiable {
    case timelapse, slomo, video, photo, portrait
 
    var id: String { rawValue }
 
    var label: String {
        switch self {
        case .timelapse: "TUA NHANH"
        case .slomo: "QUAY CHẬM"
        case .video: "VIDEO"
        case .photo: "ẢNH"
        case .portrait: "CHÂN DUNG"
        }
    }
 
    /// Các chế độ ghi hình liên tục (nút chụp là nút bật/tắt).
    var isRecordingMode: Bool {
        self == .video || self == .slomo || self == .timelapse
    }
 
    /// Thứ tự hiển thị trên thanh chọn chế độ.
    static var ordered: [CaptureMode] { [.timelapse, .slomo, .video, .photo, .portrait] }
}
 
// MARK: - Tỉ lệ khung hình
 
enum AspectRatio: String, CaseIterable {
    case r4x3 = "4:3", r16x9 = "16:9", r1x1 = "1:1"
 
    /// Tỉ lệ rộng/cao khi cầm máy dọc.
    var value: CGFloat {
        switch self {
        case .r4x3: 3.0 / 4.0
        case .r16x9: 9.0 / 16.0
        case .r1x1: 1.0
        }
    }
}
 
// MARK: - Hẹn giờ
 
enum TimerOption: Int, CaseIterable {
    case off = 0, three = 3, ten = 10

    var label: String {
        switch self {
        case .off: "Tắt"
        case .three: "3 giây"
        case .ten: "10 giây"
        }
    }
}
 
// MARK: - Chất lượng video
 
enum VideoQuality: String, CaseIterable {
    case hd1080_30 = "1080p30"
    case hd1080_60 = "1080p60"
    case uhd4k_30  = "4K30"
 
    var preset: AVCaptureSession.Preset {
        self == .uhd4k_30 ? .hd4K3840x2160 : .hd1920x1080
    }
    var fps: Double { self == .hd1080_60 ? 60 : 30 }
}
 
// MARK: - Quay chậm
 
enum SlomoRate: String, CaseIterable {
    case x120 = "120 fps", x240 = "240 fps"
 
    var fps: Double { self == .x120 ? 120 : 240 }
    /// Hệ số làm chậm khi xuất ra (phát ở 30fps).
    ///
    /// Nhận fps THẬT đã quay được chứ không đọc `fps` của mức đã chọn: camera
    /// trước chỉ đạt 120fps nên mức chọn và mức chạy có thể lệch nhau, lấy
    /// nhầm là video ra sai tốc độ gấp đôi.
    static func slowdown(forCapturedFps fps: Double) -> Double { fps / 30.0 }
}
 
// MARK: - Tua nhanh
 
enum TimeLapseInterval: String, CaseIterable {
    case fast = "0,5s", medium = "1s", slow = "3s"
 
    var seconds: TimeInterval {
        switch self {
        case .fast: 0.5
        case .medium: 1.0
        case .slow: 3.0
        }
    }
}
 
// MARK: - Định dạng ảnh
 
enum PhotoFormat: String, CaseIterable {
    case heif = "HEIF"
    case proRAW = "ProRAW"
}
 
// MARK: - Mã đã quét
 
struct ScannedCode: Equatable, Identifiable {
    let id = UUID()
    let value: String
    let type: AVMetadataObject.ObjectType
 
    /// Mã có mở được bằng Safari / app khác không.
    var url: URL? {
        guard value.lowercased().hasPrefix("http") || value.lowercased().hasPrefix("mailto:")
                || value.lowercased().hasPrefix("tel:") else { return nil }
        return URL(string: value)
    }
 
    var typeLabel: String {
        type == .qr ? "Mã QR" : "Mã vạch"
    }
}
 
// MARK: - Ghi nhớ cài đặt
 
/// Gói toàn bộ tuỳ chọn người dùng vào một chỗ để đọc/ghi UserDefaults.
struct CameraSettings {
    var mode: CaptureMode = .photo
    var flashMode: AVCaptureDevice.FlashMode = .auto
    var aspect: AspectRatio = .r4x3
    var gridOn = false
    var levelOn = false
    var timerOption: TimerOption = .off
    var videoQuality: VideoQuality = .hd1080_30
    var slomoRate: SlomoRate = .x240
    var timeLapseInterval: TimeLapseInterval = .medium
    var photoFormat: PhotoFormat = .heif
    var livePhotoOn = true
    var macroOn = false
    var scanCodesOn = true
    var portraitIntensity: Float = 0.6
 
    private enum Key {
        static let mode = "mode", flash = "flash", aspect = "aspect"
        static let grid = "grid", level = "level", timer = "timer"
        static let videoQuality = "videoQuality", slomo = "slomo"
        static let timelapse = "timelapse", photoFormat = "photoFormat"
        static let livePhoto = "livePhoto", macro = "macro"
        static let scanCodes = "scanCodes", portraitIntensity = "portraitIntensity"
    }
 
    static func load() -> CameraSettings {
        let d = UserDefaults.standard
        var s = CameraSettings()
        if let v = d.string(forKey: Key.mode), let m = CaptureMode(rawValue: v) { s.mode = m }
        if d.object(forKey: Key.flash) != nil,
           let f = AVCaptureDevice.FlashMode(rawValue: d.integer(forKey: Key.flash)) { s.flashMode = f }
        if let v = d.string(forKey: Key.aspect), let a = AspectRatio(rawValue: v) { s.aspect = a }
        s.gridOn = d.bool(forKey: Key.grid)
        s.levelOn = d.bool(forKey: Key.level)
        if let t = TimerOption(rawValue: d.integer(forKey: Key.timer)) { s.timerOption = t }
        if let v = d.string(forKey: Key.videoQuality), let q = VideoQuality(rawValue: v) { s.videoQuality = q }
        if let v = d.string(forKey: Key.slomo), let r = SlomoRate(rawValue: v) { s.slomoRate = r }
        if let v = d.string(forKey: Key.timelapse), let i = TimeLapseInterval(rawValue: v) { s.timeLapseInterval = i }
        if let v = d.string(forKey: Key.photoFormat), let p = PhotoFormat(rawValue: v) { s.photoFormat = p }
        if d.object(forKey: Key.livePhoto) != nil { s.livePhotoOn = d.bool(forKey: Key.livePhoto) }
        if d.object(forKey: Key.scanCodes) != nil { s.scanCodesOn = d.bool(forKey: Key.scanCodes) }
        s.macroOn = d.bool(forKey: Key.macro)
        if d.object(forKey: Key.portraitIntensity) != nil {
            s.portraitIntensity = d.float(forKey: Key.portraitIntensity)
        }
        return s
    }
 
    func save() {
        let d = UserDefaults.standard
        d.set(mode.rawValue, forKey: Key.mode)
        d.set(flashMode.rawValue, forKey: Key.flash)
        d.set(aspect.rawValue, forKey: Key.aspect)
        d.set(gridOn, forKey: Key.grid)
        d.set(levelOn, forKey: Key.level)
        d.set(timerOption.rawValue, forKey: Key.timer)
        d.set(videoQuality.rawValue, forKey: Key.videoQuality)
        d.set(slomoRate.rawValue, forKey: Key.slomo)
        d.set(timeLapseInterval.rawValue, forKey: Key.timelapse)
        d.set(photoFormat.rawValue, forKey: Key.photoFormat)
        d.set(livePhotoOn, forKey: Key.livePhoto)
        d.set(macroOn, forKey: Key.macro)
        d.set(scanCodesOn, forKey: Key.scanCodes)
        d.set(portraitIntensity, forKey: Key.portraitIntensity)
    }
}
 