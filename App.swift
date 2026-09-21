//
//  NoTeleCameraApp.swift
//  NoTeleCamera — Giai đoạn 3
//
//  App chụp ảnh & quay video cho iPhone 13 Pro, khoá cứng ở cụm Dual Wide
//  (ống siêu rộng 0,5× + ống chính 1×). Ống tele 77mm không bao giờ được
//  cấp điện, nên OIS hỏng của nó không kêu và không lọt vào tiếng video.
//
//  YÊU CẦU: iOS 26+, Xcode 26+ — giao diện dùng Liquid Glass thật (API iOS 26),
//  chạy trên máy thật.
//
//  ⚠️ BẮT BUỘC thêm vào Info.plist:
//    NSCameraUsageDescription            — "Dùng camera để chụp ảnh và quay video"
//    NSMicrophoneUsageDescription        — "Thu âm khi quay video"
//    NSPhotoLibraryAddUsageDescription   — "Lưu ảnh và video vào thư viện"
//    NSLocationWhenInUseUsageDescription — "Gắn vị trí vào ảnh"
//
//  CÁC FILE:
//    CaptureTypes.swift            — enum, tuỳ chọn, ghi nhớ cài đặt
//    CameraManager.swift           — session, ống kính, zoom, lấy nét, ghi hình
//    CameraManager_Capture.swift   — chụp ảnh, ProRAW, Live Photos, chân dung
//    MediaProcessing.swift         — xuất quay chậm, ghép tua nhanh
//    CameraUI.swift                — toàn bộ giao diện
//    NoTeleCameraApp.swift         — file này
//
//  ⚠️ NoTeleCamera_Phase1.swift PHẢI được gỡ khỏi target (bỏ tick Target
//     Membership) hoặc xoá hẳn. Nó khai báo lại CameraManager, ContentView,
//     PreviewUIView, CameraPreview, VolumeShutter, HiddenVolumeView và một
//     @main thứ hai — để trong target là build fail hàng loạt.
//
 
import SwiftUI
 
@main
struct NoTeleCameraApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}