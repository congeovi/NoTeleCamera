//
//  CameraManager+Capture.swift
//  NoTeleCamera — Giai đoạn 3 (bản vá)
//
//  Đường chụp ảnh: HEIF, ProRAW, Live Photos, Chân dung (xoá phông từ depth),
//  burst, và khung hình cho tua nhanh.
//
//  Ba thay đổi lớn so với bản trước:
//   • AVCapturePhotoSettings được dựng NGAY trên sessionQueue, đọc cờ thật của
//     photoOutput tại đó. Bản cũ đọc cờ trên main actor rồi mới nhảy sang
//     sessionQueue, nên nếu applyMode kịp tắt Live Photo / depth ở giữa thì
//     AVFoundation ném exception (không phải trả lỗi) và app chết.
//   • pendingCaptures được ghi TRƯỚC khi gọi capturePhoto, cộng thêm watchdog
//     và hai delegate willBeginCaptureFor / didFinishCaptureFor, nên nút chụp
//     không còn kẹt vĩnh viễn khi một mảnh dữ liệu không bao giờ về.
//   • Dựng ảnh chân dung, cắt tỉ lệ và dựng thumbnail đều chạy ngoài main
//     actor — trước đây cả ba đều đứng chắn giao diện.
//
 
import AVFoundation
import CoreImage
import ImageIO
import Photos
import SwiftUI

/// Opt-in, bounded in-memory diagnostics. No disk I/O on the capture path.
/// All mutable state is protected by lock; callbacks may arrive on different queues.
final class CaptureDiagnostics: @unchecked Sendable {
    static let shared = CaptureDiagnostics()
    private let lock = NSLock()
    private var enabled = false
    private var lines: [String] = []
    private var dropped = 0

    var isEnabled: Bool { lock.withLock { enabled } }

    func setEnabled(_ value: Bool) {
        lock.withLock {
            if value && !enabled {
                lines = ["NoTeleCamera capture diagnostics v1",
                         "Started: \(ISO8601DateFormatter().string(from: Date()))",
                         "OS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
                         "App: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?") build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?")",
                         "Times: monotonic system uptime milliseconds; callback intervals are NOT EXIF exposure time.",
                         "No images/GPS recorded. New recording clears the previous in-memory log."]
                dropped = 0
            }
            enabled = value
        }
    }

    func event(_ name: String, id: Int64? = nil, at: TimeInterval? = nil,
               _ details: @autoclosure () -> String = "") {
        let time = at ?? ProcessInfo.processInfo.systemUptime
        guard isEnabled else { return }
        let line = String(format: "t_ms=%.3f", time * 1000)
            + " id=\(id.map { String($0) } ?? "-") \(name) \(details())"
        lock.withLock {
            guard enabled else { return }
            if lines.count >= 2000 {
                lines.removeFirst(200)
                dropped += 200
            }
            lines.append(line)
        }
    }

    /// Call from a background task after the test. Export includes only this process's log.
    func export() throws -> URL {
        let report = lock.withLock {
            "Dropped old lines: \(dropped)\n" + lines.joined(separator: "\n") + "\n"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CameraCaptureDiagnostics.txt")
        try report.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func deviceDetails(_ device: AVCaptureDevice?) -> String {
        guard let device else { return "device=missing" }
        return "device=\(device.deviceType.rawValue) position=\(device.position.rawValue) zoom=\(device.videoZoomFactor)"
            + " previewExposure_ms=\(CMTimeGetSeconds(device.exposureDuration) * 1000) previewISO=\(device.iso)"
            + " adjustingFocus=\(device.isAdjustingFocus) focusMode=\(device.focusMode.rawValue) lensPosition=\(device.lensPosition)"
            + " adjustingExposure=\(device.isAdjustingExposure) exposureMode=\(device.exposureMode.rawValue)"
    }
}
 
// MARK: - Gói kết quả của một lần chụp
 
/// Một lần bấm máy có thể sinh ra nhiều mảnh dữ liệu về ở các thời điểm khác
/// nhau (ảnh đã xử lý, file RAW, đoạn phim Live Photo). Struct này gom chúng
/// lại cho tới khi đủ rồi mới lưu một lần.
struct PendingCapture {
    enum Kind { case normal, portrait, timeLapseFrame }
 
    var kind: Kind = .normal
    var processedData: Data?
    var rawData: Data?
    var livePhotoURL: URL?
    var expectsRAW = false
    var expectsLivePhoto = false
    var depthData: AVDepthData?
 
    /// Đã nhận đủ mọi mảnh chưa.
    var isComplete: Bool {
        guard processedData != nil else { return false }
        if expectsRAW && rawData == nil { return false }
        if expectsLivePhoto && livePhotoURL == nil { return false }
        return true
    }
}
 
/// Hộp để mang những kiểu chưa được đánh dấu Sendable (AVDepthData) qua ranh
/// giới actor mà không phải tắt kiểm tra concurrency ở cả file.
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
 
extension CameraManager {
 
    // MARK: - Chụp
 
    /// - Returns: `false` khi cú bấm bị từ chối và KHÔNG có tấm ảnh nào được
    ///   đặt hàng. Chỗ gọi nào có sổ sách riêng (vòng lặp burst đếm số tấm)
    ///   phải đọc giá trị này, không thì nó đếm cả những cú bị chặn.
    @discardableResult
    func capturePhoto(isBurst: Bool = false) -> Bool {
        let requestedAt = ProcessInfo.processInfo.systemUptime
        guard isBurst || !isCapturing else {
            CaptureDiagnostics.shared.event("requestRejected", "reason=captureInFlight")
            return false
        }
        // Đang đổi mode/camera: session có thể đang thiếu video input hoặc
        // giữa lúc renegotiate format — không bấm máy vào lúc đó.
        guard canPerform(.shutter) else {
            CaptureDiagnostics.shared.event("requestRejected", "reason=sessionBusy")
            return false
        }

        // Chụp nhanh trạng thái trên main actor; mọi cờ của photoOutput sẽ
        // được đọc lại bên trong sessionQueue.
        let mode = settings.mode
        let wantRAW = settings.photoFormat == .proRAW && supportsProRAW && !isBurst && mode == .photo
        let wantLive = settings.livePhotoOn && supportsLivePhoto && !isBurst && mode == .photo
        let wantPortrait = mode == .portrait && supportsDepth
        let flash = settings.flashMode
        let mirror = isFront
        let angle = captureRotationAngle
        // Kẹp vào đúng khoảng thiết bị chấp nhận. Giá trị ngoài khoảng là
        // AVFoundation ném exception khi dựng bracket chứ không trả lỗi.
        let bias: Float = {
            guard let dev = device else { return 0 }
            return min(max(exposureBias, dev.minExposureTargetBias), dev.maxExposureTargetBias)
        }()

        capturesInFlight += 1
        isCapturing = true
        shutterFlashTrigger += 1

        sessionQueue.async { [weak self] in
            guard let self else { return }
            let sessionEnteredAt = ProcessInfo.processInfo.systemUptime
 
            // Bấm chụp lúc có cuộc gọi đến hoặc app khác đang chiếm camera:
            // bản cũ đặt isCapturing = true rồi không có callback nào về.
            guard self.session.isRunning else {
                CaptureDiagnostics.shared.event("requestRejected", "reason=sessionNotRunning")
                Task { @MainActor in
                    self.endCapture(id: nil)
                    self.statusMessage = "Camera chưa sẵn sàng, chưa chụp được."
                }
                return
            }
 
            // ── Từ đây trở xuống mọi cờ đều là trạng thái THẬT của output ──
 
            // ── Đường EV ──────────────────────────────────────────────────
            // setExposureTargetBias chỉ đổi phơi sáng CẢM BIẾN. Preview là
            // luồng cảm biến nên sáng lên ngay, nhưng ảnh tĩnh còn đi qua tầng
            // xử lý của ISP (zero shutter lag gộp khung + Smart HDR + gain map
            // HDR của HEIF); tầng đó tự tone-map lại về mức sáng "đúng" theo
            // phân tích cảnh và xoá gần hết phần bù trừ. Hạ
            // photoQualityPrioritization xuống .speed không đủ — vẫn cùng một
            // đường xử lý.
            //
            // AVCapturePhotoBracketSettings với đúng một nấc
            // AVCaptureAutoExposureBracketedStillImageSettings là API Apple
            // dành riêng cho "chụp một tấm ở EV ±X". Bracket không đi qua
            // fusion nên độ sáng ra đúng bằng cái đang thấy trên preview.
            //
            // Cái giá: bracket loại trừ Live Photo, depth (xoá phông chân
            // dung), flash và ProRAW. Đã chỉnh EV thì tấm đó mất cả bốn —
            // đây là đánh đổi có chủ đích, EV được ưu tiên trước.
            // maxBracketedCapturePhotoCount trả 0 khi cấu hình hiện tại không
            // bracket được (Live Photo hoặc depth đang bật ở output). Rơi về
            // đường cũ thì EV lại bị nuốt, nên phải nói ra chứ không im lặng.
            let useBracket = bias != 0 && self.photoOutput.maxBracketedCapturePhotoCount >= 1
            if bias != 0 && !useBracket {
                Task { @MainActor in
                    self.statusMessage = "Chế độ này chưa giữ được mức EV đã chỉnh."
                }
            }

            let rawFormat: OSType? = (wantRAW && !useBracket && self.photoOutput.isAppleProRAWEnabled)
                ? self.photoOutput.availableRawPhotoPixelFormatTypes.first(where: {
                    AVCapturePhotoOutput.isAppleProRAWPixelFormat($0)
                })
                : nil

            var photoSettings: AVCapturePhotoSettings
            if useBracket {
                let evStep = AVCaptureAutoExposureBracketedStillImageSettings
                    .autoExposureSettings(exposureTargetBias: bias)
                let processed: [String: Any] = self.photoOutput.availablePhotoCodecTypes.contains(.hevc)
                    ? [AVVideoCodecKey: AVVideoCodecType.hevc]
                    : [AVVideoCodecKey: AVVideoCodecType.jpeg]
                let bracket = AVCapturePhotoBracketSettings(
                    rawPixelFormatType: 0,
                    processedFormat: processed,
                    bracketedSettings: [evStep]
                )
                // Bracket chụp liên tiếp nên dễ rung hơn một khung đơn; bù lại
                // bằng ổn định thấu kính nếu máy có.
                bracket.isLensStabilizationEnabled =
                    self.photoOutput.isLensStabilizationDuringBracketedCaptureSupported
                photoSettings = bracket
            } else if let rawFormat {
                // ProRAW: file DNG kèm một bản HEIF/JPEG để xem nhanh.
                photoSettings = AVCapturePhotoSettings(
                    rawPixelFormatType: rawFormat,
                    processedFormat: [AVVideoCodecKey: AVVideoCodecType.hevc]
                )
            } else if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                photoSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                photoSettings = AVCapturePhotoSettings()
            }
 
            // Bracket không đi cùng đèn: đặt flashMode khác .off là exception.
            photoSettings.flashMode = (!useBracket && self.photoOutput.supportedFlashModes.contains(flash))
                ? flash : .off
            // Burst ưu tiên tốc độ; chụp đơn dùng .balanced — vẫn có Deep Fusion
            // và Smart HDR, nhưng KHÔNG mở cửa cho Night mode phơi sáng dài.
            // Với .quality máy gom khung trong cả giây sau khi bấm, hễ tay nhúc
            // nhích là ảnh nhoè; phải giữ yên ~2s mới ra ảnh nét.
            // Trần thật nằm ở photoOutput.maxPhotoQualityPrioritization (.balanced),
            // đặt cao hơn trần ở đây là AVFoundation ném exception.
            let ceiling = self.photoOutput.maxPhotoQualityPrioritization
            let wanted: AVCapturePhotoOutput.QualityPrioritization =
                (isBurst || useBracket) ? .speed : .balanced
            photoSettings.photoQualityPrioritization = wanted.rawValue <= ceiling.rawValue ? wanted : ceiling
            // Bracket không nhận mọi kích thước mà format công bố; để nguyên
            // mặc định của format thay vì ép lên trần (48MP) rồi ăn exception.
            if !useBracket {
                photoSettings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            }

            var live = false
            if wantLive && !useBracket && self.photoOutput.isLivePhotoCaptureEnabled {
                photoSettings.livePhotoMovieFileURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("live_\(UUID().uuidString).mov")
                live = true
            }
 
            var depthOn = false
            if wantPortrait && !useBracket && self.photoOutput.isDepthDataDeliveryEnabled {
                photoSettings.isDepthDataDeliveryEnabled = true
                // Giữ depth riêng để tự dựng xoá phông, không nhúng vào file.
                photoSettings.embedsDepthDataInPhoto = false
                depthOn = true
            }
 
            var pending = PendingCapture(kind: depthOn ? .portrait : .normal)
            pending.expectsRAW = (rawFormat != nil)
            pending.expectsLivePhoto = live
            let id = photoSettings.uniqueID
            let box = UncheckedBox(photoSettings)
            CaptureDiagnostics.shared.event("request", id: id, at: requestedAt,
                "mode=\(mode.rawValue) burst=\(isBurst) EV=\(bias) liveWanted=\(wantLive) rawWanted=\(wantRAW)")
            CaptureDiagnostics.shared.event("sessionQueueEntered", id: id, at: sessionEnteredAt)
            CaptureDiagnostics.shared.event("settingsReady", id: id,
                "bracket=\(useBracket) live=\(live) raw=\(rawFormat != nil) depth=\(depthOn) quality=\(photoSettings.photoQualityPrioritization.rawValue) flash=\(photoSettings.flashMode.rawValue) max=\(photoSettings.maxPhotoDimensions.width)x\(photoSettings.maxPhotoDimensions.height)")
 
            // Ghi pending TRƯỚC khi bấm máy. Nếu bấm trước rồi mới ghi thì
            // delegate có thể về sớm hơn và bị bỏ qua vì chưa thấy entry nào.
            Task { @MainActor in
                self.pendingCaptures[id] = pending
                self.armWatchdog(id)
                CaptureDiagnostics.shared.event("pendingRegistered", id: id)
 
                self.sessionQueue.async {
                    CaptureDiagnostics.shared.event("captureQueueEntered", id: id)
                    var connectionChanged = false
                    // Chỉ ghi khi giá trị THỰC SỰ khác. Ghi đè lại y nguyên giá
                    // trị cũ vẫn khiến AVFoundation cấu hình lại connection và
                    // xả vòng đệm zero-shutter-lag, làm mất đúng cái ta vừa bật.
                    if let conn = self.photoOutput.connection(with: .video) {
                        if conn.videoRotationAngle != angle,
                           conn.isVideoRotationAngleSupported(angle) {
                            conn.videoRotationAngle = angle
                            connectionChanged = true
                        }
                        if conn.isVideoMirroringSupported {
                            if conn.automaticallyAdjustsVideoMirroring {
                                conn.automaticallyAdjustsVideoMirroring = false
                                connectionChanged = true
                            }
                            if conn.isVideoMirrored != mirror {
                                conn.isVideoMirrored = mirror
                                connectionChanged = true
                            }
                        }
                    }
                    CaptureDiagnostics.shared.event("captureState", id: id,
                        "connectionChanged=\(connectionChanged) angle=\(angle) ZSL_supported=\(self.photoOutput.isZeroShutterLagSupported) ZSL_enabled=\(self.photoOutput.isZeroShutterLagEnabled) responsive=\(self.photoOutput.isResponsiveCaptureEnabled) fast=\(self.photoOutput.isFastCapturePrioritizationEnabled) readiness=\(self.photoOutput.captureReadiness.rawValue) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled) \(CaptureDiagnostics.deviceDetails(self.videoInput?.device))")
                    CaptureDiagnostics.shared.event("captureCall", id: id)
                    self.photoOutput.capturePhoto(with: box.value, delegate: self)
                }
            }
        }
        return true
    }
 
    // MARK: - Sổ sách một lần chụp
 
    /// Hẹn giờ cứu hộ. Live Photo có thể bị hệ thống huỷ vì máy nóng, thiếu
    /// bộ nhớ hoặc rung quá mạnh — khi đó callback phim không bao giờ về,
    /// `isComplete` mãi false, entry nằm lại và nút chụp chết cho tới khi
    /// khởi động lại app.
    func armWatchdog(_ id: Int64, seconds: Double = 8) {
        captureWatchdogs[id]?.cancel()
        captureWatchdogs[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, var pending = self.pendingCaptures[id] else { return }
            CaptureDiagnostics.shared.event("watchdog", id: id, "seconds=\(seconds)")
 
            // Thôi chờ những mảnh không về nữa, cứu lấy phần đã có.
            pending.expectsLivePhoto = false
            pending.expectsRAW = false
            self.pendingCaptures[id] = pending
 
            if pending.processedData != nil {
                self.finishIfComplete(id)
            } else {
                if let url = pending.livePhotoURL { try? FileManager.default.removeItem(at: url) }
                self.endCapture(id: id)
            }
        }
    }
 
    /// Đóng sổ đúng một lần cho mỗi lần gọi capturePhoto. `id` là nil khi lần
    /// chụp đó chưa kịp đăng ký pending.
    func endCapture(id: Int64?) {
        CaptureDiagnostics.shared.event("captureBookkeepingEnd", id: id)
        if let id {
            pendingCaptures.removeValue(forKey: id)
            captureWatchdogs.removeValue(forKey: id)?.cancel()
        }
        capturesInFlight = max(0, capturesInFlight - 1)
        if capturesInFlight == 0 { isCapturing = false }
    }
 
    /// Bỏ mọi lần chụp đang bay — dùng khi session gián đoạn, lỗi runtime,
    /// hoặc đổi camera.
    func abortAllCaptures() {
        for (_, task) in captureWatchdogs { task.cancel() }
        captureWatchdogs.removeAll()
        for (_, pending) in pendingCaptures {
            if let url = pending.livePhotoURL { try? FileManager.default.removeItem(at: url) }
        }
        CaptureDiagnostics.shared.event("abortAllCaptures", "count=\(pendingCaptures.count)")
        pendingCaptures.removeAll()
        capturesInFlight = 0
        isCapturing = false
    }
 
    // MARK: - Hoàn tất một lần chụp
 
    func finishIfComplete(_ id: Int64) {
        guard let pending = pendingCaptures[id], pending.isComplete else { return }
 
        // Khung hình tua nhanh: chỉ nạp vào bộ ghép, không lưu vào thư viện.
        if pending.kind == .timeLapseFrame {
            if let data = pending.processedData { appendTimeLapseFrame(data) }
            endCapture(id: id)
            return
        }
 
        guard let processed = pending.processedData else {
            endCapture(id: id)
            return
        }
 
        CaptureDiagnostics.shared.event("resourcesReady", id: id)
        savePhoto(id: id, processed: processed,
                  raw: pending.rawData,
                  liveMovie: pending.livePhotoURL,
                  depth: pending.kind == .portrait ? pending.depthData : nil)
 
        // Mở khoá nút chụp ngay khi đã bàn giao dữ liệu. Bản cũ đợi
        // PHPhotoLibrary ghi xong xuống đĩa mới mở, nên chụp liên tiếp bị khựng.
        endCapture(id: id)
    }
 
    // MARK: - Lưu ảnh
 
    /// Dựng chân dung, cắt tỉ lệ, dựng thumbnail và ghi thư viện — tất cả
    /// chạy ngoài main actor. Bản cũ render CIMaskedVariableBlur trên một ảnh
    /// 12MP ngay trên main thread, giao diện đứng cả giây sau mỗi lần chụp
    /// chân dung.
    private func savePhoto(id: Int64, processed: Data, raw: Data?, liveMovie: URL?, depth: AVDepthData?) {
        let location = currentLocation
        let targetAspect = settings.aspect
        let intensity = settings.portraitIntensity
        let depthBox = depth.map { UncheckedBox($0) }
        // Cắt tỉ lệ sẽ phá cặp Live Photo và không áp được cho RAW,
        // nên chỉ cắt khi chụp thường.
        let shouldCrop = targetAspect != .r4x3 && raw == nil && liveMovie == nil
 
        Task.detached(priority: .utility) {
            CaptureDiagnostics.shared.event("saveWorkerStart", id: id)
            var finalData = processed
 
            // Chân dung: dựng ảnh xoá phông từ depth map.
            if let depthBox,
               let blurred = PortraitRenderer.render(imageData: finalData,
                                                     depth: depthBox.value,
                                                     intensity: intensity) {
                finalData = blurred
            }
 
            if shouldCrop {
                // Cắt trên CGImageSource/CGImageDestination để giữ nguyên
                // định dạng gốc và toàn bộ EXIF. Đường qua UIImage cũ làm
                // rụng hết metadata kỹ thuật và ép ảnh HEIF xuống JPEG.
                if let kept = MediaProcessing.cropPreservingMetadata(finalData,
                                                                    toAspect: targetAspect.value) {
                    finalData = kept
                } else if let img = UIImage(data: finalData),
                          let cropped = img.cropped(toAspect: targetAspect.value),
                          let jpeg = cropped.jpegData(compressionQuality: 0.95) {
                    finalData = jpeg
                }
            }
 
            // Thumbnail dựng bằng CGImageSource thay vì UIImage(data:) — giải
            // nén nguyên ảnh 48MP chỉ để hiện ô 52pt là quá phí, và làm ngoài
            // main actor thì không chắn giao diện.
            let thumb = UncheckedBox(MediaProcessing.thumbnail(from: finalData))
            await MainActor.run { self.lastThumbnail = thumb.value }
            CaptureDiagnostics.shared.event("thumbnailPublished", id: id)
 
            let dataToSave = finalData
            CaptureDiagnostics.shared.event("photosSubmit", id: id, "bytes=\(dataToSave.count)")
            PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .photo, data: dataToSave, options: nil)
 
                // File DNG đi kèm ảnh đã xử lý, thành một asset ProRAW.
                if let raw {
                    let opts = PHAssetResourceCreationOptions()
                    opts.uniformTypeIdentifier = AVFileType.dng.rawValue
                    req.addResource(with: .alternatePhoto, data: raw, options: opts)
                }
 
                // Đoạn phim ngắn của Live Photo.
                if let liveMovie {
                    let opts = PHAssetResourceCreationOptions()
                    opts.shouldMoveFile = true
                    req.addResource(with: .pairedVideo, fileURL: liveMovie, options: opts)
                }
 
                req.location = location
            } completionHandler: { ok, err in
                CaptureDiagnostics.shared.event("photosComplete", id: id,
                    "ok=\(ok) errorCode=\((err as NSError?)?.code ?? 0)")
                let text = err?.localizedDescription ?? ""
                Task { @MainActor in
                    if !ok { self.errorMessage = "Lưu ảnh thất bại: \(text)" }
                }
            }
        }
    }
}
 
// MARK: - Delegate ảnh
 
extension CameraManager: AVCapturePhotoCaptureDelegate {

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        CaptureDiagnostics.shared.event("willCapture", id: resolvedSettings.uniqueID)
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        CaptureDiagnostics.shared.event("didCapture", id: resolvedSettings.uniqueID)
    }
 
    /// Gọi ngay khi hệ thống chốt xong cấu hình thật của lần chụp. Nếu
    /// Live Photo hoặc RAW bị từ chối ở đây thì hạ kỳ vọng xuống luôn, đừng
    /// ngồi đợi một callback không bao giờ tới.
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        let id = resolvedSettings.uniqueID
        CaptureDiagnostics.shared.event("willBegin", id: id,
            "resolved=\(resolvedSettings.photoDimensions.width)x\(resolvedSettings.photoDimensions.height) flash=\(resolvedSettings.isFlashEnabled)")
        let willHaveLive = resolvedSettings.livePhotoMovieDimensions.width > 0
        let willHaveRAW = resolvedSettings.rawPhotoDimensions.width > 0
 
        Task { @MainActor in
            guard var pending = self.pendingCaptures[id] else { return }
            if !willHaveLive { pending.expectsLivePhoto = false }
            if !willHaveRAW { pending.expectsRAW = false }
            self.pendingCaptures[id] = pending
            self.finishIfComplete(id)
        }
    }
 
    /// Ảnh đã xử lý và file RAW đều về qua hàm này, phân biệt bằng `photo.isRawPhoto`.
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        let id = photo.resolvedSettings.uniqueID
        let isRaw = photo.isRawPhoto
        CaptureDiagnostics.shared.event("processingCallback", id: id,
            "raw=\(isRaw) errorCode=\((error as NSError?)?.code ?? 0)")
        if CaptureDiagnostics.shared.isEnabled {
            let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
            // Whitelist only technical fields; never serialize the complete metadata/GPS.
            CaptureDiagnostics.shared.event("photoMetadata", id: id,
                "raw=\(isRaw) exposure_s=\(exif?[kCGImagePropertyExifExposureTime as String] ?? "missing") ISO=\(exif?[kCGImagePropertyExifISOSpeedRatings as String] ?? "missing") focalLength_mm=\(exif?[kCGImagePropertyExifFocalLength as String] ?? "missing") photoTimestamp_s=\(CMTimeGetSeconds(photo.timestamp))")
        }
        let dataStartedAt = ProcessInfo.processInfo.systemUptime
        let data = photo.fileDataRepresentation()
        CaptureDiagnostics.shared.event("fileDataReady", id: id,
            "raw=\(isRaw) bytes=\(data?.count ?? 0) encode_ms=\((ProcessInfo.processInfo.systemUptime - dataStartedAt) * 1000)")
        let failure = error?.localizedDescription
 
        // Depth map về theo hướng cảm biến, còn ảnh đã bị xoay bởi
        // videoRotationAngle. Không nắn lại thì mask xoá phông vừa lệch góc
        // vừa bị kéo méo theo hai trục khác nhau → vùng mờ rơi sai chỗ.
        var depth = photo.depthData
        if let raw = photo.metadata[kCGImagePropertyOrientation as String] as? UInt32,
           let orientation = CGImagePropertyOrientation(rawValue: raw) {
            depth = depth?.applyingExifOrientation(orientation)
        }
        let depthBox = depth.map { UncheckedBox($0) }
 
        Task { @MainActor in
            guard failure == nil, let data else {
                self.endCapture(id: id)
                if let failure { self.errorMessage = "Chụp lỗi: \(failure)" }
                return
            }
            guard var pending = self.pendingCaptures[id] else { return }
            if isRaw {
                pending.rawData = data
            } else {
                pending.processedData = data
                pending.depthData = depthBox?.value
            }
            self.pendingCaptures[id] = pending
            self.finishIfComplete(id)
        }
    }
 
    /// Đoạn phim của Live Photo về sau ảnh tĩnh vài trăm mili giây.
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
                                 duration: CMTime,
                                 photoDisplayTime: CMTime,
                                 resolvedSettings: AVCaptureResolvedPhotoSettings,
                                 error: Error?) {
        let id = resolvedSettings.uniqueID
        let failed = error != nil
        CaptureDiagnostics.shared.event("liveMovieReady", id: id, "failed=\(failed)")
        Task { @MainActor in
            guard var pending = self.pendingCaptures[id] else {
                try? FileManager.default.removeItem(at: outputFileURL)
                return
            }
            if !failed {
                pending.livePhotoURL = outputFileURL
            } else {
                // Mất phần phim thì vẫn lưu ảnh tĩnh.
                pending.expectsLivePhoto = false
                try? FileManager.default.removeItem(at: outputFileURL)
            }
            self.pendingCaptures[id] = pending
            self.finishIfComplete(id)
        }
    }
 
    /// Callback cuối cùng của một lần chụp. Còn sót pending ở đây nghĩa là có
    /// mảnh nào đó hỏng — rút ngắn watchdog xuống 2 giây thay vì để 8.
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                                 error: Error?) {
        let id = resolvedSettings.uniqueID
        CaptureDiagnostics.shared.event("didFinishCapture", id: id,
            "errorCode=\((error as NSError?)?.code ?? 0)")
        let failure = error?.localizedDescription

        Task { @MainActor in
            guard let pending = self.pendingCaptures[id] else { return }
            if let failure {
                if let url = pending.livePhotoURL { try? FileManager.default.removeItem(at: url) }
                self.endCapture(id: id)
                self.errorMessage = "Chụp lỗi: \(failure)"
            } else {
                self.armWatchdog(id, seconds: 2)
            }
        }
    }
}
 
// MARK: - Dựng ảnh chân dung
 
/// Xoá phông dựa trên depth map của cụm Dual Wide.
///
/// Lưu ý thật lòng: đây là bản tự dựng, không phải chế độ Chân dung của Apple.
/// Apple còn dùng phân đoạn người bằng mạng neural để bắt tóc và viền tay;
/// ở đây chỉ có depth map nên viền sẽ mềm hơn và đôi khi ăn lẹm.
/// Với ảnh chụp người ở khoảng cách vừa, kết quả vẫn dùng được.
enum PortraitRenderer {
 
    private static let context = CIContext(options: [.useSoftwareRenderer: false])
 
    static func render(imageData: Data, depth: AVDepthData, intensity: Float) -> Data? {
        guard let base = CIImage(data: imageData) else { return nil }
 
        // Đưa về disparity float để giá trị lớn = gần máy.
        var d = depth
        if d.depthDataType != kCVPixelFormatType_DisparityFloat32 {
            d = d.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
        }
        let disparity = CIImage(cvPixelBuffer: d.depthDataMap)
 
        // Depth map nhỏ hơn ảnh nhiều lần → phóng cho khớp.
        let sx = base.extent.width / disparity.extent.width
        let sy = base.extent.height / disparity.extent.height
        var mask = disparity.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
 
        // Lấy disparity tại tâm khung làm mặt phẳng nét.
        let focus = centerDisparity(d) ?? averageDisparity(mask) ?? 0.5
 
        // mask = |disparity - focus| → 0 ở mặt phẳng nét, tăng dần khi ra xa.
        // Dùng tổ hợp bậc nhất để tránh phải viết kernel riêng.
        guard let subtract = CIFilter(name: "CISubtractBlendMode") else { return nil }
        let focusPlane = CIImage(color: CIColor(red: CGFloat(focus),
                                                green: CGFloat(focus),
                                                blue: CGFloat(focus)))
            .cropped(to: mask.extent)
 
        subtract.setValue(mask, forKey: kCIInputImageKey)
        subtract.setValue(focusPlane, forKey: kCIInputBackgroundImageKey)
        let farSide = subtract.outputImage ?? mask
 
        subtract.setValue(focusPlane, forKey: kCIInputImageKey)
        subtract.setValue(mask, forKey: kCIInputBackgroundImageKey)
        let nearSide = subtract.outputImage ?? mask
 
        guard let maxFilter = CIFilter(name: "CIMaximumCompositing") else { return nil }
        maxFilter.setValue(farSide, forKey: kCIInputImageKey)
        maxFilter.setValue(nearSide, forKey: kCIInputBackgroundImageKey)
        mask = maxFilter.outputImage ?? mask
 
        // Khuếch đại theo cường độ người dùng chọn, rồi làm mượt biên.
        let gain = 2.0 + intensity * 8.0
        mask = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(gain), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: CGFloat(gain), y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: CGFloat(gain), y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
        mask = mask.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 8.0])
            .cropped(to: base.extent)
 
        // Làm mờ biến thiên theo mask.
        let radius = 6.0 + Double(intensity) * 22.0
        guard let blurred = CIFilter(name: "CIMaskedVariableBlur", parameters: [
            kCIInputImageKey: base.clampedToExtent(),
            kCIInputRadiusKey: radius,
            "inputMask": mask
        ])?.outputImage?.cropped(to: base.extent) else { return nil }
 
        guard let cg = context.createCGImage(blurred, from: blurred.extent) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.95)
    }
 
    /// Đọc giá trị disparity ngay tâm khung.
    private static func centerDisparity(_ depth: AVDepthData) -> Float? {
        let buffer = depth.depthDataMap
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
 
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let row = base.advanced(by: (h / 2) * stride)
        let value = row.assumingMemoryBound(to: Float32.self)[w / 2]
        return value.isFinite ? value : nil
    }
 
    private static func averageDisparity(_ image: CIImage) -> Float? {
        guard let avg = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: image.extent)
        ])?.outputImage else { return nil }
 
        var pixel = [Float32](repeating: 0, count: 4)
        context.render(avg,
                       toBitmap: &pixel,
                       rowBytes: 16,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf,
                       colorSpace: nil)
        return pixel[0].isFinite ? pixel[0] : nil
    }
}
