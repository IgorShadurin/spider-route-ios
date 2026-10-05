import AVFoundation
import Photos
import XCTest
@testable import SpeedometerGPS

@MainActor
final class RemoteCameraPhotosTests: XCTestCase {
    private func storage() -> UserDefaults {
        let suite = "photos-tests-" + UUID().uuidString
        let result = UserDefaults(suiteName: suite)!
        addTeardownBlock { result.removePersistentDomain(forName: suite) }
        return result
    }
    private let clip = URL(fileURLWithPath: "/tmp/test-video.mov")
    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Photos export did not reach expected state")
    }
    func testDeniedAccessRetainsPendingWithoutWritingAndRetriesAfterSettingsChange() async {
        var auth = PHAuthorizationStatus.denied
        var writes = 0
        let exporter = RemoteCameraPhotos(defaults: storage(), authorization: { auth }, write: { _ in writes += 1; return true })
        exporter.enqueue(clip)
        XCTAssertEqual(exporter.state(for: clip), .denied)
        XCTAssertEqual(writes, 0)
        auth = .authorized
        exporter.sceneActive(true)
        await waitFor { exporter.state(for: self.clip) == .saved }
        XCTAssertEqual(writes, 1)
    }
    func testBackgroundCompletionIsDeferredAndPendingSurvivesRelaunch() async {
        let defaults = storage()
        var writes = 0
        let first = RemoteCameraPhotos(defaults: defaults, authorization: { .authorized }, write: { _ in writes += 1; return true })
        first.sceneActive(false)
        first.enqueue(clip)
        XCTAssertEqual(writes, 0)
        let relaunched = RemoteCameraPhotos(defaults: defaults, authorization: { .authorized }, write: { _ in writes += 1; return true })
        relaunched.sceneActive(true)
        await waitFor { relaunched.state(for: self.clip) == .saved }
        XCTAssertEqual(writes, 1)
    }
    func testFailedExportCanRetryAndSuccessfulReceiptPreventsDuplicatesAcrossLaunches() async {
        let defaults = storage()
        var writes = 0
        let exporter = RemoteCameraPhotos(defaults: defaults, authorization: { .authorized }, write: { _ in writes += 1; return writes > 1 })
        exporter.enqueue(clip)
        await waitFor { exporter.state(for: self.clip) == .failed }
        await exporter.saveManually(clip)
        await waitFor { exporter.state(for: self.clip) == .saved }
        exporter.enqueue(clip)
        await exporter.saveManually(clip)
        let relaunched = RemoteCameraPhotos(defaults: defaults, authorization: { .authorized }, write: { _ in writes += 1; return true })
        relaunched.enqueue(clip)
        XCTAssertEqual(relaunched.state(for: clip), .saved)
        XCTAssertEqual(writes, 2)
    }
    func testOldClipRequiresExplicitSaveAndPromptNeverComesFromCompletion() async {
        var requests = 0
        var auth = PHAuthorizationStatus.notDetermined
        let exporter = RemoteCameraPhotos(defaults: storage(), authorization: { auth }, request: {
            requests += 1; auth = .authorized; return auth
        }, write: { _ in true })
        XCTAssertEqual(exporter.state(for: clip), .local)
        exporter.enqueue(clip)
        XCTAssertEqual(requests, 0)
        await exporter.saveManually(clip)
        await waitFor { exporter.state(for: self.clip) == .saved }
        XCTAssertEqual(requests, 1)
    }
    func testInFlightExportCannotBeDuplicatedAndOnlyCompletionMeansSaved() async {
        var continuation: CheckedContinuation<Bool, Never>?
        var writes = 0
        let exporter = RemoteCameraPhotos(defaults: storage(), authorization: { .authorized }, write: { _ in
            writes += 1
            return await withCheckedContinuation { continuation = $0 }
        })
        exporter.enqueue(clip)
        await waitFor { continuation != nil }
        XCTAssertEqual(exporter.state(for: clip), .saving)
        exporter.enqueue(clip)
        await exporter.saveManually(clip)
        XCTAssertEqual(writes, 1)
        continuation?.resume(returning: true)
        await waitFor { exporter.state(for: self.clip) == .saved }
    }
    func testRepeatedCompletionManualSaveAndForegroundProduceOnePhotosAsset() async {
        let defaults = storage()
        var finish: CheckedContinuation<Bool, Never>?
        var writes = 0
        let exporter = RemoteCameraPhotos(defaults: defaults, authorization: { .authorized }, write: { _ in
            writes += 1
            return await withCheckedContinuation { finish = $0 }
        })
        exporter.enqueue(clip)
        await waitFor { finish != nil }
        for _ in 0..<3 {
            exporter.enqueue(clip)
            exporter.sceneActive(false)
            exporter.sceneActive(true)
            await exporter.saveManually(clip)
        }
        XCTAssertEqual(writes, 1)
        finish?.resume(returning: true)
        await waitFor { exporter.state(for: self.clip) == .saved }
        let relaunched = RemoteCameraPhotos(defaults: defaults, authorization: { .authorized }, write: { _ in
            writes += 1; return true
        })
        relaunched.enqueue(clip)
        await relaunched.saveManually(clip)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(defaults.stringArray(forKey: "remoteCamera.photos.saved"), [clip.lastPathComponent])
    }
    func testPhotoKitImportsPlayableMovieAndRetainsOriginal() async throws {
        guard PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized else {
            throw XCTSkip("Grant Photos add-only access to the simulator test host for the real PhotoKit integration check.")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("photos-integration-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 0, CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for frame in 0..<15 {
            await waitFor { input.isReadyForMoreMediaData }
            XCTAssertTrue(adapter.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        XCTAssertTrue(AVURLAsset(url: url).isPlayable)
        let success = await RemoteCameraPhotos.writeVideo(url)
        XCTAssertTrue(success)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(AVURLAsset(url: url).isPlayable)
    }
}
