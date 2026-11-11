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

    @Test(arguments: [60.0, 120.0, 240.0])
    func thePrecisionRateIsTheOneAskedFor(rate: Double) {
        #expect(CameraFrameRatePolicy.frameRate(for: .precision, pressure: .serious, precision: rate) == rate)
        #expect(CameraFrameRatePolicy.frameRate(for: .idle, pressure: .nominal, precision: rate) == CameraFrameRatePolicy.idle)
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

    /// How many frames per second pose detection and athlete tracking keep up with.
    @Test(.enabled(if: cameraRequested))
    func poseTrackingThroughputInPrecisionMode() async throws {
        let camera = CameraController()
        let tracker = PoseTracker()
        let athleteTracker = Mutex(AthleteTracker())
        let durations = Mutex<[TimeInterval]>([])
        let bodyCounts = Mutex<[Int]>([])

        camera.setFrameHandler { frame in
            let began = CACurrentMediaTime()
            let poses = tracker.poses(in: frame)
            let athletes = athleteTracker.withLock { $0.update(with: poses, at: frame.timestamp) }
            let took = CACurrentMediaTime() - began
            durations.withLock { $0.append(took) }
            bodyCounts.withLock { $0.append(athletes.count { $0.state == .tracked }) }
        }

        try #require(camera.configureIfNeeded())
        camera.start()
        try await Task.sleep(for: .seconds(2))

        camera.setMode(.precision)
        try await Task.sleep(for: .seconds(1))
        durations.withLock { $0.removeAll() }
        bodyCounts.withLock { $0.removeAll() }
        _ = camera.currentStatistics()
        camera.setMode(.idle)
        camera.setMode(.precision)
        try await Task.sleep(for: .seconds(3))

        let statistics = camera.currentStatistics()
        camera.stop()

        let sorted = durations.withLock { $0.sorted() }
        let median = try #require(sorted.isEmpty ? nil : sorted[sorted.count / 2])
        let bodies = bodyCounts.withLock { $0.sorted() }

        Attachment.record(
            """
            analysed: \(statistics.deliveredFrameRate ?? 0) fps (\(statistics.delivered) frames)
            dropped: \(statistics.dropped) (\(statistics.droppedLate) late), \
            longest gap \(statistics.longestGap * 1000) ms
            pose detection and tracking: median \(median * 1000) ms, max \((sorted.last ?? 0) * 1000) ms
            tracked athletes per frame: median \(bodies.isEmpty ? 0 : bodies[bodies.count / 2]), \
            max \(bodies.last ?? 0)
            pressure: \(camera.pressure)
            """,
            named: "Pose tracking throughput"
        )

        #expect(statistics.delivered > 0)
    }

    /// What the camera-motion compensation of the handheld mode costs on
    /// top of pose detection, and what it measures on a phone that is held.
    @Test(.enabled(if: cameraRequested))
    func cameraMotionCompensationThroughput() async throws {
        let camera = CameraController()
        let tracker = PoseTracker()
        let estimator = CameraMotionEstimator()
        let durations = Mutex<[TimeInterval]>([])
        let offsets = Mutex<[CGPoint]>([])

        camera.setFrameHandler { frame in
            _ = tracker.poses(in: frame)
            let began = CACurrentMediaTime()
            let offset = estimator.offset(in: frame)
            durations.withLock { $0.append(CACurrentMediaTime() - began) }
            offsets.withLock { $0.append(offset) }
        }

        try #require(camera.configureIfNeeded())
        camera.start()
        try await Task.sleep(for: .seconds(2))

        camera.setMode(.precision)
        try await Task.sleep(for: .seconds(1))
        durations.withLock { $0.removeAll() }
        offsets.withLock { $0.removeAll() }
        _ = camera.currentStatistics()
        camera.setMode(.idle)
        camera.setMode(.precision)
        try await Task.sleep(for: .seconds(3))

        let statistics = camera.currentStatistics()
        camera.stop()

        let sorted = durations.withLock { $0.sorted() }
        let median = try #require(sorted.isEmpty ? nil : sorted[sorted.count / 2])
        let largest = offsets.withLock { $0.map { hypot($0.x, $0.y) }.max() ?? 0 }

        Attachment.record(
            """
            analysed with compensation: \(statistics.deliveredFrameRate ?? 0) fps (\(statistics.delivered) frames)
            dropped: \(statistics.dropped) (\(statistics.droppedLate) late), \
            longest gap \(statistics.longestGap * 1000) ms
            image registration: median \(median * 1000) ms, max \((sorted.last ?? 0) * 1000) ms
            largest measured shift: \(largest * 100) % of the picture
            pressure: \(camera.pressure)
            """,
            named: "Camera motion compensation"
        )

        #expect(statistics.delivered > 0)
    }

    /// What each precision rate delivers when every frame is sampled for
    /// three athletes and pose detection runs beside it on its own queue,
    /// as in the detector.
    @Test(.enabled(if: cameraRequested))
    func samplingAndPoseRatesAtEachFrameRate() async throws {
        var report = ""

        for rate in CameraFrameRate.allCases {
            let camera = CameraController()
            camera.setPrecisionFrameRate(Double(rate.rawValue))

            let tracker = PoseTracker()
            let poseQueue = DispatchSerialQueue(label: "test.pose")
            let inbox = Mutex<(isBusy: Bool, waiting: CameraFrame?)>((false, nil))
            let poseCount = Mutex(0)
            let samplingDurations = Mutex<[TimeInterval]>([])

            // Three athletes side by side, each a fifth of the picture wide.
            let regions = [0.1, 0.4, 0.7].map { CGRect(x: $0, y: 0.2, width: 0.2, height: 0.5) }

            camera.setFrameHandler { frame in
                let began = CACurrentMediaTime()
                let width = CVPixelBufferGetWidth(frame.pixelBuffer)
                let height = CVPixelBufferGetHeight(frame.pixelBuffer)

                for region in regions {
                    _ = MotionSampler.cells(
                        of: frame.pixelBuffer,
                        in: MotionSampler.bufferRegion(for: region, bufferWidth: width, bufferHeight: height)
                    )
                }
                samplingDurations.withLock { $0.append(CACurrentMediaTime() - began) }

                // As in the detector: the newest frame waits for the pose queue.
                let isFree = inbox.withLock { inbox in
                    guard inbox.isBusy else {
                        inbox.isBusy = true
                        return true
                    }

                    inbox.waiting = frame
                    return false
                }
                guard isFree else { return }

                poseQueue.async {
                    var next: CameraFrame? = frame

                    while let current = next {
                        _ = tracker.poses(in: current)
                        poseCount.withLock { $0 += 1 }

                        next = inbox.withLock { inbox in
                            defer { inbox.waiting = nil }
                            inbox.isBusy = inbox.waiting != nil
                            return inbox.waiting
                        }
                    }
                }
            }

            try #require(camera.configureIfNeeded())
            let format = try #require(camera.format)
            camera.start()
            try await Task.sleep(for: .seconds(2))

            camera.setMode(.precision)
            try await Task.sleep(for: .seconds(1))
            samplingDurations.withLock { $0.removeAll() }
            poseCount.withLock { $0 = 0 }
            _ = camera.currentStatistics()
            camera.setMode(.idle)
            camera.setMode(.precision)
            try await Task.sleep(for: .seconds(3))

            let statistics = camera.currentStatistics()
            let poses = poseCount.withLock { $0 }
            camera.stop()

            let sorted = samplingDurations.withLock { $0.sorted() }
            let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]

            report += """
            asked for \(rate.rawValue) fps: format \(format.width)x\(format.height) up to \(format.maxFrameRate) fps
              sampled: \(statistics.deliveredFrameRate ?? 0) fps (\(statistics.delivered) frames), \
            dropped \(statistics.dropped) (\(statistics.droppedLate) late), longest gap \(statistics.longestGap * 1000) ms
              sampling three regions: median \(median * 1000) ms, max \((sorted.last ?? 0) * 1000) ms
              poses beside it: \(Double(poses) / 3) per second
              pressure: \(camera.pressure)

            """

            #expect(statistics.delivered > 0)
            // Lets the session let go of the camera before the next one takes it.
            try await Task.sleep(for: .seconds(2))
        }

        Attachment.record(report, named: "Sampling and pose rates")
    }

    /// Changing the precision rate in the settings picks another format
    /// while the camera runs; each rate has to arrive afterwards.
    @Test(.enabled(if: cameraRequested))
    func switchingThePrecisionRateWhileRunning() async throws {
        let camera = CameraController()
        let log = FrameLog()

        camera.setFrameHandler { frame in
            log.frames.withLock { $0.append((frame.timestamp.seconds, CACurrentMediaTime())) }
        }

        try #require(camera.configureIfNeeded())
        camera.start()
        try await Task.sleep(for: .seconds(2))

        var report = ""

        for rate in [240.0, 120, 60, 120] {
            camera.setPrecisionFrameRate(rate)
            try await Task.sleep(for: .seconds(1.5))
            let idle = log.rate(since: CACurrentMediaTime() - 0.8)

            camera.setMode(.precision)
            try await Task.sleep(for: .seconds(2))
            let precision = log.rate(since: CACurrentMediaTime() - 1)
            let statistics = camera.currentStatistics()
            camera.setMode(.idle)

            let format = try #require(camera.format)
            report += """
            \(rate) fps: format \(format.width)x\(format.height) up to \(format.maxFrameRate) fps, \
            idle \(idle) fps, precision \(precision) fps, dropped \(statistics.dropped)

            """

            #expect(abs(idle - CameraFrameRatePolicy.idle) < 2)
            #expect(precision > min(rate, format.maxFrameRate) * 0.9)
        }

        camera.stop()
        Attachment.record(report, named: "Switching the precision rate")

        // Lets the session let go of the camera before the next test takes it.
        try await Task.sleep(for: .seconds(2))
    }
}
