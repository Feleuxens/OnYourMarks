//
//  CameraTests.swift
//  OnYourMarksTests
//

import Testing
import AVFoundation
import QuartzCore
import Synchronization
@testable import OnYourMarks

struct CameraFormatSelectorTests {
    private func format(
        _ width: Int,
        _ height: Int,
        maxFrameRate: Double,
        pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    ) -> CameraFormatDescriptor {
        CameraFormatDescriptor(
            width: width,
            height: height,
            frameRateRanges: [1...maxFrameRate],
            pixelFormat: pixelFormat,
            supportsAutoFrameRate: false
        )
    }

    @Test
    func prefersFullHDThatReachesTheFrameRate() {
        let formats = [
            format(1920, 1080, maxFrameRate: 60),
            format(1280, 720, maxFrameRate: 240),
            format(1920, 1080, maxFrameRate: 120),
            format(3840, 2160, maxFrameRate: 120),
        ]

        #expect(CameraFormatSelector.bestIndex(among: formats, frameRate: 120) == 2)
    }

    @Test
    func prefersTheSlowestFormatThatIsFastEnough() {
        let formats = [
            format(1920, 1080, maxFrameRate: 240),
            format(1920, 1080, maxFrameRate: 120),
        ]

        #expect(CameraFormatSelector.bestIndex(among: formats, frameRate: 120) == 1)
    }

    @Test
    func prefersEightBitFullRangePixels() {
        let formats = [
            format(1920, 1080, maxFrameRate: 120, pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
            format(1920, 1080, maxFrameRate: 120, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            format(1920, 1080, maxFrameRate: 120),
        ]

        #expect(CameraFormatSelector.bestIndex(among: formats, frameRate: 120) == 2)
    }

    @Test
    func prefersSixteenByNineOverFourByThree() {
        let formats = [
            format(1440, 1080, maxFrameRate: 120),
            format(1280, 720, maxFrameRate: 120),
        ]

        #expect(CameraFormatSelector.bestIndex(among: formats, frameRate: 120) == 1)
    }

    @Test
    func fallsBackToTheFastestFormat() {
        let formats = [
            format(1920, 1080, maxFrameRate: 30),
            format(1280, 720, maxFrameRate: 60),
        ]

        #expect(CameraFormatSelector.bestIndex(among: formats, frameRate: 120) == 1)
    }

    @Test
    func noFormatsGiveNoChoice() {
        #expect(CameraFormatSelector.bestIndex(among: [], frameRate: 120) == nil)
    }
}

struct CameraFrameRatePolicyTests {
    @Test(arguments: [CameraPressureLevel.nominal, .fair, .serious, .critical, .shutdown])
    func precisionRateIsKeptUnderAnyPressure(pressure: CameraPressureLevel) {
        #expect(CameraFrameRatePolicy.frameRate(for: .precision, pressure: pressure) == CameraFrameRatePolicy.precision)
    }

    @Test
    func idleRateIsThrottledUnderSeriousPressure() {
        #expect(CameraFrameRatePolicy.frameRate(for: .idle, pressure: .nominal) == CameraFrameRatePolicy.idle)
        #expect(CameraFrameRatePolicy.frameRate(for: .idle, pressure: .fair) == CameraFrameRatePolicy.idle)
        #expect(CameraFrameRatePolicy.frameRate(for: .idle, pressure: .serious) == CameraFrameRatePolicy.throttledIdle)
        #expect(CameraFrameRatePolicy.frameRate(for: .idle, pressure: .critical) == CameraFrameRatePolicy.throttledIdle)
    }

    @Test
    func supportedRateIsKeptAndOthersMoveToTheNearestBound() {
        #expect(CameraFrameRatePolicy.supported(60, in: [1...120]) == 60)
        #expect(CameraFrameRatePolicy.supported(240, in: [1...120]) == 120)
        #expect(CameraFrameRatePolicy.supported(5, in: [15...30, 60...60]) == 15)
        #expect(CameraFrameRatePolicy.supported(50, in: [15...30, 60...60]) == 60)
        #expect(CameraFrameRatePolicy.supported(30, in: []) == nil)
    }
}

struct FrameStatisticsTests {
    @Test
    func measuresRateAndLongestGapFromTimestamps() throws {
        var statistics = FrameStatistics()

        // 120 fps with one frame missing.
        for index in [0, 1, 2, 4, 5] {
            statistics.recordDelivered(at: 100 + Double(index) / 120)
        }

        #expect(statistics.delivered == 5)
        #expect(abs(statistics.longestGap - 2.0 / 120) < 0.000_001)
        #expect(abs(try #require(statistics.deliveredFrameRate) - 4 / (5.0 / 120)) < 0.001)
    }

    @Test
    func countsDropsByReason() {
        var statistics = FrameStatistics()

        statistics.recordDropped(.late)
        statistics.recordDropped(.late)
        statistics.recordDropped(.outOfBuffers)
        statistics.recordDropped(.discontinuity)
        statistics.recordDropped(.unknown)

        #expect(statistics.droppedLate == 2)
        #expect(statistics.droppedOutOfBuffers == 1)
        #expect(statistics.droppedDiscontinuity == 1)
        #expect(statistics.dropped == 5)
    }

    @Test
    func singleFrameHasNoRate() {
        var statistics = FrameStatistics()
        statistics.recordDelivered(at: 1)

        #expect(statistics.deliveredFrameRate == nil)
        #expect(statistics.longestGap == 0)
    }
}

/// Runs the real camera, which only a device has. Opt-in: set
/// `TEST_RUNNER_RUN_CAMERA=1`, with camera access allowed for the app.
@MainActor
@Suite(.serialized)
struct CameraControllerTests {
    private nonisolated static var cameraRequested: Bool {
        ProcessInfo.processInfo.environment["RUN_CAMERA"] == "1"
            && AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    /// Capture time and arrival time of each delivered frame.
    private final class FrameLog: Sendable {
        let frames = Mutex<[(captured: TimeInterval, arrived: TimeInterval)]>([])

        func rate(since start: TimeInterval) -> Double {
            let times = frames.withLock { $0.map(\.captured).filter { $0 >= start } }
            guard let first = times.first, let last = times.last, last > first else { return 0 }
            return Double(times.count - 1) / (last - first)
        }
    }

    #if targetEnvironment(simulator)
    @Test
    func configurationFailsWithoutCamera() {
        let camera = CameraController()

        #expect(!camera.configureIfNeeded())
        #expect(camera.format == nil)
    }
    #endif

    @Test(.enabled(if: cameraRequested))
    func deliversTimestampedFramesAtBothRates() async throws {
        let camera = CameraController()
        let log = FrameLog()

        camera.setFrameHandler { frame in
            log.frames.withLock { $0.append((frame.timestamp.seconds, CACurrentMediaTime())) }
        }

        try #require(camera.configureIfNeeded())
        let format = try #require(camera.format)
        camera.start()

        try await Task.sleep(for: .seconds(2.5))
        let idleRate = log.rate(since: CACurrentMediaTime() - 1)

        camera.setMode(.precision)
        try await Task.sleep(for: .seconds(2))
        let precisionRate = log.rate(since: CACurrentMediaTime() - 1)
        let precision = camera.currentStatistics()

        camera.setMode(.idle)
        try await Task.sleep(for: .seconds(1.5))
        let idleAgainRate = log.rate(since: CACurrentMediaTime() - 0.8)
        camera.stop()

        let delays = log.frames.withLock { $0.map { $0.arrived - $0.captured } }.sorted()
        let medianDelay = try #require(delays.isEmpty ? nil : delays[delays.count / 2])

        Attachment.record(
            """
            format: \(format.width)x\(format.height), up to \(format.maxFrameRate) fps, \
            auto low-light frame rate supported: \(format.supportsAutoFrameRate)
            idle: \(idleRate) fps, precision: \(precisionRate) fps, idle again: \(idleAgainRate) fps
            precision window: \(precision.delivered) delivered, \(precision.dropped) dropped \
            (\(precision.droppedLate) late), longest gap \(precision.longestGap * 1000) ms
            capture to delivery: median \(medianDelay * 1000) ms, \
            min \((delays.first ?? 0) * 1000) ms, max \((delays.last ?? 0) * 1000) ms
            pressure: \(camera.pressure)
            """,
            named: "Camera frame delivery"
        )

        #expect(abs(idleRate - CameraFrameRatePolicy.idle) < 2)
        #expect(abs(idleAgainRate - CameraFrameRatePolicy.idle) < 2)

        let expectedPrecision = min(CameraFrameRatePolicy.precision, format.maxFrameRate)
        #expect(precisionRate > expectedPrecision * 0.9)

        // Timestamps on the host clock lie shortly before their arrival.
        #expect(try #require(delays.first) > 0)
        #expect(medianDelay < 0.25)
    }

    /// How many frames per second pose detection keeps up with.
    @Test(.enabled(if: cameraRequested))
    func poseTrackingThroughputInPrecisionMode() async throws {
        let camera = CameraController()
        let tracker = PoseTracker()
        let durations = Mutex<[TimeInterval]>([])

        camera.setFrameHandler { frame in
            let began = CACurrentMediaTime()
            _ = tracker.joints(in: frame)
            let took = CACurrentMediaTime() - began
            durations.withLock { $0.append(took) }
        }

        try #require(camera.configureIfNeeded())
        camera.start()
        try await Task.sleep(for: .seconds(2))

        camera.setMode(.precision)
        try await Task.sleep(for: .seconds(1))
        durations.withLock { $0.removeAll() }
        _ = camera.currentStatistics()
        camera.setMode(.idle)
        camera.setMode(.precision)
        try await Task.sleep(for: .seconds(3))

        let statistics = camera.currentStatistics()
        camera.stop()

        let sorted = durations.withLock { $0.sorted() }
        let median = try #require(sorted.isEmpty ? nil : sorted[sorted.count / 2])

        Attachment.record(
            """
            analysed: \(statistics.deliveredFrameRate ?? 0) fps (\(statistics.delivered) frames)
            dropped: \(statistics.dropped) (\(statistics.droppedLate) late), \
            longest gap \(statistics.longestGap * 1000) ms
            pose detection: median \(median * 1000) ms, max \((sorted.last ?? 0) * 1000) ms
            pressure: \(camera.pressure)
            """,
            named: "Pose tracking throughput"
        )

        #expect(statistics.delivered > 0)
    }
}
