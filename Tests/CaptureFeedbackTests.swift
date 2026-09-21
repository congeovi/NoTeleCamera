import XCTest
import UIKit
@testable import NoTeleCamera

@MainActor
final class CaptureFeedbackTests: XCTestCase {
    private func manager(live: Bool = false, burst: Bool = false) -> CameraManager {
        let camera = CameraManager()
        camera.latestPhotoSequence = 1
        camera.acquiringPhotoTokens = [1]
        camera.isAcquiringPhoto = true
        camera.captureFeedback[10] = CaptureFeedback(sequence: 1, isBurst: burst, expectsLive: live)
        return camera
    }

    func testStillFeedbackIsOnceAndIndependentOfSaving() {
        let camera = manager()
        camera.photoSaveState = .processing
        camera.updateAcquisitionFeedback(10, still: true)
        camera.updateAcquisitionFeedback(10, still: true)
        XCTAssertEqual(camera.shutterFlashTrigger, 1)
        XCTAssertFalse(camera.isAcquiringPhoto)
        XCTAssertTrue(camera.captureFeedback.isEmpty)
        XCTAssertEqual(camera.photoSaveState, .processing)
        camera.publishPhotoState(.failed, sequence: 1)
        XCTAssertEqual(camera.photoSaveState, .failed)
        XCTAssertEqual(camera.shutterFlashTrigger, 1)
    }

    func testLiveRequiresBothCallbacksInEitherOrder() {
        for movieFirst in [false, true] {
            let camera = manager(live: true)
            camera.updateAcquisitionFeedback(10, still: !movieFirst, liveFinished: movieFirst)
            XCTAssertEqual(camera.shutterFlashTrigger, 0)
            XCTAssertTrue(camera.isAcquiringPhoto)
            camera.updateAcquisitionFeedback(10, still: movieFirst, liveFinished: !movieFirst)
            XCTAssertEqual(camera.shutterFlashTrigger, 1)
            XCTAssertFalse(camera.isAcquiringPhoto)
        }
    }

    func testResolvedLiveDisabledStopsWaitingForMovie() {
        let camera = manager(live: true)
        camera.updateAcquisitionFeedback(10, still: true)
        camera.updateAcquisitionFeedback(10, resolvedLive: false)
        XCTAssertEqual(camera.shutterFlashTrigger, 1)
    }

    func testAbortSuppressesLateCallbacks() {
        let camera = manager(live: true)
        camera.abortAllCaptures()
        camera.updateAcquisitionFeedback(10, still: true, liveFinished: true)
        XCTAssertEqual(camera.shutterFlashTrigger, 0)
        XCTAssertFalse(camera.isAcquiringPhoto)
        XCTAssertEqual(camera.photoSaveState, .failed)
    }

    func testOldSaveCannotOverwriteLatestStatus() {
        let camera = manager()
        camera.latestPhotoSequence = 2
        camera.photoSaveState = .saving
        camera.publishPhotoState(.saved, sequence: 1)
        XCTAssertEqual(camera.photoSaveState, .saving)
        camera.publishPhotoState(.saved, sequence: 2)
        XCTAssertEqual(camera.photoSaveState, .saved)
    }

    func testOldThumbnailCannotReplaceNewPhoto() {
        let camera = manager()
        camera.latestPhotoSequence = 2
        let newest = UIImage()
        camera.publishPhotoThumbnail(newest, sequence: 2)
        camera.publishPhotoThumbnail(UIImage(), sequence: 1)
        XCTAssertTrue(camera.lastThumbnail === newest)
    }

    func testHandOffKeepsAcquisitionRecordAndDuplicateEndDoesNotDecrement() {
        let camera = manager(live: true)
        camera.pendingCaptures[10] = PendingCapture(sequence: 1)
        camera.capturesInFlight = 2
        camera.endCapture(id: 10, handedOff: true)
        camera.endCapture(id: 10)
        XCTAssertEqual(camera.capturesInFlight, 1)
        XCTAssertNotNil(camera.captureFeedback[10])
        camera.updateAcquisitionFeedback(10, still: true, liveFinished: true)
        XCTAssertEqual(camera.shutterFlashTrigger, 1)
    }

    // MARK: Bỏ chờ Live Photo

    /// Phim hỏng hoặc watchdog hết giờ: ảnh tĩnh vẫn được lưu nên màn trập
    /// vẫn phải nổ. Nuốt phản hồi ở đây là ảnh vào thư viện mà không có tín
    /// hiệu nào cho người dùng.
    func testAbandonLiveWaitStillFiresShutterWhenStillAlreadyArrived() {
        let camera = manager(live: true)
        camera.updateAcquisitionFeedback(10, still: true)
        XCTAssertEqual(camera.shutterFlashTrigger, 0)
        camera.abandonLiveWait(10)
        XCTAssertEqual(camera.shutterFlashTrigger, 1)
        XCTAssertFalse(camera.isAcquiringPhoto)
        XCTAssertTrue(camera.captureFeedback.isEmpty)
    }

    /// Không mảnh nào về thì không nổ màn trập, nhưng token phải được dọn —
    /// bỏ sót là `isAcquiringPhoto` treo true và nút chụp co mãi.
    func testAbandonLiveWaitClearsTokenWhenNothingArrived() {
        let camera = manager(live: true)
        camera.abandonLiveWait(10)
        XCTAssertEqual(camera.shutterFlashTrigger, 0)
        XCTAssertFalse(camera.isAcquiringPhoto)
        XCTAssertTrue(camera.captureFeedback.isEmpty)
        XCTAssertTrue(camera.acquiringPhotoTokens.isEmpty)
    }

    // MARK: Đóng sổ khi hỏng

    func testFailedEndCapturePublishesFailureAndClearsFeedback() {
        let camera = manager(live: true)
        camera.pendingCaptures[10] = PendingCapture(sequence: 1)
        camera.capturesInFlight = 1
        camera.isCapturing = true
        camera.endCapture(id: 10)
        XCTAssertEqual(camera.photoSaveState, .failed)
        XCTAssertEqual(camera.shutterFlashTrigger, 0)
        XCTAssertFalse(camera.isAcquiringPhoto)
        XCTAssertTrue(camera.captureFeedback.isEmpty)
        XCTAssertEqual(camera.capturesInFlight, 0)
        XCTAssertFalse(camera.isCapturing)
    }

    /// Hai tấm bay cùng lúc: chỉ tấm cuối cùng thu nhận xong mới hạ cờ.
    func testConcurrentTokensKeepAcquiringUntilAllResolve() {
        let camera = manager(burst: true)
        camera.acquiringPhotoTokens.insert(2)
        camera.captureFeedback[11] = CaptureFeedback(sequence: 2, isBurst: true, expectsLive: false)
        camera.updateAcquisitionFeedback(10, still: true)
        XCTAssertTrue(camera.isAcquiringPhoto)
        XCTAssertEqual(camera.burstCount, 1)
        camera.updateAcquisitionFeedback(11, still: true)
        XCTAssertFalse(camera.isAcquiringPhoto)
        XCTAssertEqual(camera.burstCount, 2)
    }

    // MARK: Huy hiệu trạng thái lưu tự tắt

    func testOnlyTerminalStatesAutoDismiss() {
        XCTAssertNil(PhotoSaveState.processing.autoDismissAfter)
        XCTAssertNil(PhotoSaveState.saving.autoDismissAfter)
        XCTAssertNotNil(PhotoSaveState.saved.autoDismissAfter)
        XCTAssertNotNil(PhotoSaveState.failed.autoDismissAfter)
    }

    func testTerminalStateSchedulesAutoDismissAndNextStateCancelsIt() {
        let camera = manager()
        camera.setPhotoSaveState(.processing)
        XCTAssertNil(camera.photoSaveStateResetTask)
        camera.setPhotoSaveState(.saved)
        let scheduled = camera.photoSaveStateResetTask
        XCTAssertNotNil(scheduled)
        camera.setPhotoSaveState(.processing)
        XCTAssertNil(camera.photoSaveStateResetTask)
        XCTAssertEqual(scheduled?.isCancelled, true)
    }

    /// Kết quả của ảnh cũ không được hiện huy hiệu, cũng không được hẹn giờ
    /// tắt — cái hẹn đó sẽ xoá mất huy hiệu của ảnh mới.
    func testStaleSaveNeitherShowsBadgeNorSchedulesDismiss() {
        let camera = manager()
        camera.latestPhotoSequence = 2
        camera.publishPhotoState(.saved, sequence: 1)
        XCTAssertNil(camera.photoSaveState)
        XCTAssertNil(camera.photoSaveStateResetTask)
    }

    func testBurstCountsAcquiredImagesWithoutFlash() {
        let camera = manager(burst: true)
        camera.updateAcquisitionFeedback(10, still: true)
        camera.updateAcquisitionFeedback(10, still: true)
        XCTAssertEqual(camera.burstCount, 1)
        XCTAssertEqual(camera.shutterFlashTrigger, 0)
    }

    func testOldBurstDoesNotIncrementNewBurstCount() {
        let camera = manager(burst: true)
        camera.burstGeneration = 1
        camera.updateAcquisitionFeedback(10, still: true)
        XCTAssertEqual(camera.burstCount, 0)
    }

    func testInternalFrameHasNoPhotoFeedbackOrSaveStatus() {
        let camera = CameraManager()
        camera.updateAcquisitionFeedback(10, still: true)
        camera.publishPhotoState(.failed, sequence: 0)
        XCTAssertEqual(camera.shutterFlashTrigger, 0)
        XCTAssertNil(camera.photoSaveState)
    }
}
