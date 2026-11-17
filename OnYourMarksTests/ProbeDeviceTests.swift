//
//  ProbeDeviceTests.swift
//  OnYourMarksTests
//

import AVFoundation
import CoreGraphics
import QuartzCore
import Testing
@testable import OnYourMarks

/// A measurement on the device, through the real camera, detector, audio
/// and engine. Opt-in: `TEST_RUNNER_RUN_CAMERA=1`, with camera access allowed.
///
/// Lay the phone flat on a table, camera up and nothing moving above it,
/// with no headphones or speaker connected: the gun plays on the built-in
/// speaker and the probe watches the whole picture. Whether the gun shaking
/// the phone shows as a step in the picture, and when against the modelled
/// heard time, is what this answers. Nothing is asserted about the offset.
@MainActor
@Suite(.serialized)
struct ProbeDeviceTests {
    private nonisolated static var cameraRequested: Bool {
        ProcessInfo.processInfo.environment["RUN_CAMERA"] == "1"
            && AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    @Test(.enabled(if: cameraRequested))
    func theGunShakingThePhoneMeasuredByAWholePictureProbe() async throws {
        let camera = CameraController()
        let detector = PoseMotionDetector(camera: camera)
        let player = AudioController(theme: .eng1)
        let engine = StarterEngine(player: player, movementDetector: detector)

        try #require(camera.configureIfNeeded())
        camera.start()
        try await Task.sleep(for: .seconds(2))

        var config = StartConfig.standard
        config.startType = .standing
        config.standingTimeToReady = 1
        config.standingTimeToStartMin = 2
        config.standingTimeToStartMax = 2
        config.recordsVideo = false
        config.probeRegions = [ProbeRegion(rect: ProbeRegion.wholePicture)]

        let began = CACurrentMediaTime()
        engine.start(config: config)

        while engine.isRunning, CACurrentMediaTime() - began < 20 {
            try await Task.sleep(for: .milliseconds(100))
        }

        let statistics = detector.detectionStatistics
        let precision = camera.lastPrecisionStatistics
        let route = player.currentOutput()
        camera.stop()
        await player.deactivateSession()

        let session = try #require(engine.lastSession)
        let gun = ReplayTimeline.gun(in: session)
        let steps = session.events.compactMap { event -> ProbeObservation? in
            if case .probeChanged(let observation) = event.kind { observation } else { nil }
        }

        func milliseconds(_ seconds: TimeInterval) -> String {
            (seconds * 1000).formatted(.number.precision(.fractionLength(1)))
        }

        let stepLines = steps.map { step in
            let offset = gun.map { step.change.duration(since: $0) }
            return """
              step \(offset.map { "\(milliseconds($0.earliest)) to \(milliseconds($0.latest)) ms after the gun" } ?? "without a gun"), \
            certain \(gun.map { milliseconds(step.certainAt.seconds - $0.best.seconds) } ?? "?") ms, \
            size \(step.size) against rest \(step.restLevel) ± \(step.restSpread), brightness \(step.brightnessChange), \
            dropped \(step.droppedFrames)
            """
        }

        Attachment.record(
            """
            outcome: \(String(describing: session.outcome))
            route: \(route?.name ?? "none"), built-in speaker: \(route?.isBuiltInSpeaker ?? false)
            gun heard: \(gun.map { "\($0.best.seconds) (± \(milliseconds(($0.latest.seconds - $0.earliest.seconds) / 2)) ms)" } ?? "none")
            frames sampled by the probe: \(statistics.sampledFrames)
            precision window: \(precision?.delivered ?? 0) frames at \(precision?.deliveredFrameRate ?? 0) fps, \
            dropped \(precision?.dropped ?? 0)
            steps: \(steps.count)
            \(stepLines.joined(separator: "\n"))
            nearest to the gun: \(engine.probeResults.map { "\(milliseconds($0.offset.earliest)) to \(milliseconds($0.offset.latest)) ms" })
            """,
            named: "Gun shake through a whole-picture probe"
        )

        #expect(session.outcome == .completed)
        #expect(statistics.sampledFrames > 0)
    }
}
