//
//  MediaProcessing.swift
//  NoTeleCamera — Giai đoạn 3
//
//  Xử lý sau khi ghi: kéo giãn thời gian cho quay chậm, ghép khung hình
//  cho tua nhanh, và vài tiện ích ảnh.
//
 
import AVFoundation
import ImageIO
import UIKit
 
// MARK: - Lỗi
 
enum MediaError: LocalizedError {
    case noVideoTrack
    case exportFailed(String)
    case writerFailed(String)
    case noFrames
 
    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "File quay không có luồng hình."
        case .exportFailed(let m): "Xuất file lỗi: \(m)"
        case .writerFailed(let m): "Ghi file lỗi: \(m)"
        case .noFrames: "Không có khung hình nào."
        }
    }
}
 
// MARK: - Kéo giãn thời gian cho quay chậm
 
enum MediaProcessing {
 
    /// Video quay ở 240fps nếu phát nguyên trạng sẽ chạy tốc độ thường.
    /// Hàm này kéo giãn trục thời gian ra `factor` lần để thành quay chậm thật.
    /// Âm thanh bị bỏ — tiếng kéo chậm 8 lần chỉ còn là tiếng rền.
    static func slowDown(url: URL, factor: Double) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaError.noVideoTrack
        }
        let duration = try await asset.load(.duration)
        let transform = try await track.load(.preferredTransform)
 
        let composition = AVMutableComposition()
        guard let compTrack = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MediaError.noVideoTrack
        }
        let range = CMTimeRange(start: .zero, duration: duration)
        try compTrack.insertTimeRange(range, of: track, at: .zero)
        compTrack.preferredTransform = transform
 
        let scaled = CMTimeMultiplyByFloat64(duration, multiplier: factor)
        compTrack.scaleTimeRange(CMTimeRange(start: .zero, duration: duration), toDuration: scaled)
 
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("slomo_\(UUID().uuidString).mov")
 
        guard let export = AVAssetExportSession(asset: composition,
                                                presetName: AVAssetExportPresetHighestQuality) else {
            throw MediaError.exportFailed("không tạo được phiên xuất")
        }
        export.outputURL = outURL
        export.outputFileType = .mov
 
        await withCheckedContinuation { continuation in
            export.exportAsynchronously {
                continuation.resume()
            }
        }
 
        guard export.status == .completed else {
            throw MediaError.exportFailed(export.error?.localizedDescription ?? "không rõ")
        }
        return outURL
    }
 
    // MARK: - Cắt ảnh giữ nguyên metadata
 
    /// Cắt canh giữa về tỉ lệ rộng/cao cho trước, giữ nguyên định dạng gốc
    /// (HEIF vẫn là HEIF) và toàn bộ EXIF/TIFF/maker note.
    ///
    /// Ảnh gốc còn nằm ở hướng cảm biến, hướng hiển thị nằm trong tag
    /// orientation. Với orientation 5–8 (xoay 90°) thì tỉ lệ phải lật lại
    /// trước khi cắt, nếu không sẽ cắt nhầm chiều.
    static func cropPreservingMetadata(_ data: Data, toAspect ratio: CGFloat) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              var props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return nil }
 
        let orientation = (props[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let target = orientation >= 5 ? 1 / ratio : ratio
 
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        var newW = w, newH = h
        if w / h > target { newW = h * target } else { newH = w / target }
 
        let rect = CGRect(x: ((w - newW) / 2).rounded(.down),
                          y: ((h - newH) / 2).rounded(.down),
                          width: newW.rounded(.down),
                          height: newH.rounded(.down))
        guard let cropped = cg.cropping(to: rect) else { return nil }
 
        let type = CGImageSourceGetType(src) ?? ("public.jpeg" as CFString)
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type, 1, nil) else { return nil }
 
        // Kích thước trong metadata phải khớp ảnh mới, nếu không app Ảnh
        // đọc ra kích thước cũ.
        props[kCGImagePropertyPixelWidth] = cropped.width
        props[kCGImagePropertyPixelHeight] = cropped.height
        props[kCGImageDestinationLossyCompressionQuality] = 0.95
 
        CGImageDestinationAddImage(dest, cropped, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
 
    /// Thumbnail nhỏ dựng thẳng từ dữ liệu ảnh, không giải nén nguyên khung.
    static func thumbnail(from data: Data, maxPixel: CGFloat = 320) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cg)
    }
}
 
// MARK: - Bộ ghép tua nhanh
 
/// Nhận từng khung hình JPEG/HEIF rồi ghép thành video 30fps.
/// Ghi ra đĩa thay vì giữ trong RAM, nên quay dài bao lâu cũng được.
final class TimeLapseRecorder: @unchecked Sendable {
 
    private let queue = DispatchQueue(label: "timelapse.recorder")
    private var frameURLs: [URL] = []
    private let folder: URL
 
    /// Số khung hình mỗi giây của video kết quả.
    private let outputFPS: Int32 = 30
 
    init() {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("timelapse_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
 
    func reset() {
        queue.sync {
            for url in frameURLs { try? FileManager.default.removeItem(at: url) }
            frameURLs.removeAll()
        }
    }
 
    func append(_ data: Data) {
        queue.async {
            autoreleasepool {
                let url = self.folder.appendingPathComponent("f_\(self.frameURLs.count).jpg")
                // Nén lại về JPEG cho nhẹ, ảnh tua nhanh không cần chất lượng tối đa.
                if let img = UIImage(data: data), let jpeg = img.jpegData(compressionQuality: 0.8) {
                    try? jpeg.write(to: url)
                    self.frameURLs.append(url)
                }
            }
        }
    }
 
    func assemble() async throws -> URL {
        let urls: [URL] = queue.sync { frameURLs }
        guard let first = urls.first, let firstImage = UIImage(contentsOfFile: first.path) else {
            throw MediaError.noFrames
        }
 
        // Kích thước phải chẵn, nếu không encoder sẽ từ chối.
        let size = CGSize(width: (firstImage.size.width * firstImage.scale).rounded(.down).evenized,
                          height: (firstImage.size.height * firstImage.scale).rounded(.down).evenized)
 
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("timelapse_\(UUID().uuidString).mov")
 
        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ])
        input.expectsMediaDataInRealTime = false
 
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )
 
        guard writer.canAdd(input) else { throw MediaError.writerFailed("không thêm được input") }
        writer.add(input)
 
        // startWriting() hỏng thì requestMediaDataWhenReady không bao giờ chạy,
        // continuation bên dưới treo vĩnh viễn và app đứng ở màn "đang xuất".
        guard writer.startWriting() else {
            throw MediaError.writerFailed(writer.error?.localizedDescription ?? "không bắt đầu ghi được")
        }
        writer.startSession(atSourceTime: .zero)
 
        let fps = outputFPS
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let writeQueue = DispatchQueue(label: "timelapse.write")
            var index = 0
            var didResume = false   // writeQueue nối tiếp nên biến này an toàn
 
            input.requestMediaDataWhenReady(on: writeQueue) {
                while input.isReadyForMoreMediaData {
                    guard index < urls.count else {
                        input.markAsFinished()
                        writer.finishWriting {
                            guard !didResume else { return }
                            didResume = true
                            if writer.status == .completed {
                                cont.resume()
                            } else {
                                cont.resume(throwing: MediaError.writerFailed(
                                    writer.error?.localizedDescription ?? "không rõ"))
                            }
                        }
                        return
                    }
 
                    // Mỗi vòng dựng một UIImage cỡ đầy đủ và một CGContext.
                    // Không có autoreleasepool thì chúng dồn lại tới khi block
                    // thoát — quay tua nhanh vài nghìn khung là tràn RAM.
                    autoreleasepool {
                        let time = CMTime(value: CMTimeValue(index), timescale: fps)
                        if let image = UIImage(contentsOfFile: urls[index].path),
                           let buffer = image.pixelBuffer(size: size, pool: adaptor.pixelBufferPool) {
                            adaptor.append(buffer, withPresentationTime: time)
                        }
                        index += 1
                    }
                }
            }
        }
 
        reset()
        return outURL
    }
}
 
// MARK: - Tiện ích
 
private extension CGFloat {
    /// Làm tròn xuống số chẵn gần nhất.
    var evenized: CGFloat { self.truncatingRemainder(dividingBy: 2) == 0 ? self : self - 1 }
}
 
extension UIImage {
 
    /// Cắt ảnh về tỉ lệ rộng/cao cho trước, canh giữa.
    func cropped(toAspect ratio: CGFloat) -> UIImage? {
        guard let cg = cgImage else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        var newW = w, newH = h
        if w / h > ratio { newW = h * ratio } else { newH = w / ratio }
        let rect = CGRect(x: (w - newW) / 2, y: (h - newH) / 2, width: newW, height: newH)
        guard let out = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: out, scale: scale, orientation: imageOrientation)
    }
 
    /// Lấy khung hình đầu tiên của video làm thumbnail.
    ///
    /// Bản cũ dùng `copyCGImage` đồng bộ ngay trên main actor: giải mã một
    /// khung 4K chắn giao diện một nhịp sau mỗi lần quay xong. Bản này dùng
    /// API bất đồng bộ và giới hạn kích thước — ô thumbnail chỉ 52pt.
    static func thumbnail(from url: URL, maxPixel: CGFloat = 320) async -> UIImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        // Cho phép lệch nửa giây để không phải giải mã chính xác khung 0 —
        // thumbnail lấy khung nào ở đầu video cũng được.
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)
        guard let cg = try? await gen.image(at: .zero).image else { return nil }
        return UIImage(cgImage: cg)
    }
 
    /// Vẽ ảnh vào pixel buffer để đưa vào AVAssetWriter.
    func pixelBuffer(size: CGSize, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
 
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        } else {
            CVPixelBufferCreate(kCFAllocatorDefault,
                                Int(size.width), Int(size.height),
                                kCVPixelFormatType_32ARGB,
                                [kCVPixelBufferCGImageCompatibilityKey: true,
                                 kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
                                &buffer)
        }
        guard let buffer, let cg = cgImage else { return nil }
 
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
 
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }
 
        ctx.draw(cg, in: CGRect(origin: .zero, size: size))
        return buffer
    }
}
 