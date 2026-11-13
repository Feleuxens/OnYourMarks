//
//  AudioControllerTests.swift
//  OnYourMarksTests
//

import Testing
import AVFoundation
import QuartzCore
@testable import OnYourMarks

/// Runs against the real audio session, which the simulator supports.
/// Serialized because every controller shares the one system session.
@MainActor
@Suite(.serialized)
struct AudioControllerTests {
    @Test(arguments: SoundTheme.allCases)
    func loadsEverySignalOfTheTheme(theme: SoundTheme) {
        let controller = AudioController(theme: theme)
        
        for signal in Signal.allCases {
            #expect(controller.duration(of: signal) > 0.1, "\(signal) not loaded")
            #expect(controller.onsetOffsets[signal] != nil, "\(signal) has no onset")
        }
    }
    
    @Test
    func playFailsWithoutActiveSession() {
        let controller = AudioController(theme: .eng1)
        
        #expect(!controller.isSessionActive)
        #expect(!controller.play(.go))
    }
    
    @Test
    func deactivatingInactiveSessionIsSafe() async {
        let controller = AudioController(theme: .eng1)
        
        await controller.deactivateSession()
        
        #expect(!controller.isSessionActive)
    }
    
    @Test(arguments: SoundTheme.allCases)
    func reloadingThemeKeepsSignalsLoaded(theme: SoundTheme) {
        let controller = AudioController(theme: .eng1)
        
        controller.loadSounds(theme)
        
        for signal in Signal.allCases {
            #expect(controller.duration(of: signal) > 0.1, "\(signal) lost after reload")
        }
    }
    
    // MARK: - With an active session
    
    /// An active controller that records each unexpected stop it reports.
    private func activeController() async throws -> (AudioController, StopRecorder) {
        let controller = AudioController(theme: .eng1)
        let recorder = StopRecorder()
        controller.onUnexpectedStop = { recorder.reasons.append($0) }
        
        try await controller.activateSession()
        return (controller, recorder)
    }
    
    /// Lets the async notification handlers hop to the main actor and run.
    private func settle() async {
        for _ in 0..<50 {
            await Task.yield()
        }
    }
    
    @Test
    func activationEnablesPlaybackAndDeactivationStopsIt() async throws {
        let (controller, recorder) = try await activeController()
        
        #expect(controller.isSessionActive)
        #expect(controller.play(.go))
        
        await controller.deactivateSession()
        
        #expect(!controller.isSessionActive)
        #expect(!controller.play(.go))
        // Our own deactivation is not mistaken for the system taking audio away.
        await settle()
        #expect(recorder.reasons.isEmpty)
    }
    
    @Test
    func repeatedTransitionsStaySerialized() async throws {
        let controller = AudioController(theme: .eng1)
        
        // Requested back to back without waiting, as quick taps would.
        // Main-actor tasks start in the order they're created.
        let first = Task { try await controller.activateSession() }
        let second = Task { await controller.deactivateSession() }
        let third = Task { try await controller.activateSession() }
        
        try await first.value
        await second.value
        try await third.value
        
        #expect(controller.isSessionActive)
        #expect(controller.play(.go))
        
        await controller.deactivateSession()
    }
    
    @Test
    func changingThemeWhileActiveKeepsEngineRunning() async throws {
        let (controller, recorder) = try await activeController()
        
        controller.loadSounds(.eng1)
        
        for signal in Signal.allCases {
            #expect(controller.play(signal), "\(signal) not playable after reload")
        }
        #expect(recorder.reasons.isEmpty)
        
        await controller.deactivateSession()
    }
    
    @Test
    func sessionBecomingInactiveStopsPlaybackAndReports() async throws {
        let (controller, recorder) = try await activeController()
        
        controller.handleSessionBecameInactive()
        // A second report of the same loss (e.g. route change right after) stays silent.
        controller.handleSessionBecameInactive()
        
        #expect(recorder.reasons.count == 1)
        #expect(!controller.isSessionActive)
        #expect(!controller.play(.go))
        
        await controller.deactivateSession()
    }
    
    @Test
    func mediaServicesResetRebuildsAndReports() async throws {
        let (controller, recorder) = try await activeController()
        
        NotificationCenter.default.post(
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance()
        )
        // Delivery to the main actor takes longer on a device than a few yields.
        await waitUntil { recorder.reasons.count == 1 }
        
        #expect(recorder.reasons.count == 1)
        #expect(!controller.isSessionActive)
        for signal in Signal.allCases {
            #expect(controller.duration(of: signal) > 0.1, "\(signal) lost after reset")
        }
        
        // The rebuilt engine can be used for the next start.
        try await controller.activateSession()
        #expect(controller.play(.go))
        await controller.deactivateSession()
    }
    
    @Test
    func routeNotificationWithoutOutputChangeIsIgnored() async throws {
        let (controller, recorder) = try await activeController()
        
        // Also posted for category changes; only a different set of outputs counts.
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
        await settle()
        
        #expect(recorder.reasons.isEmpty)
        #expect(controller.isSessionActive)
        
        await controller.deactivateSession()
    }
    
    @Test
    func configurationChangeOfAnotherEngineIsIgnored() async throws {
        let (controller, recorder) = try await activeController()
        let otherEngine = AVAudioEngine()
        
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: otherEngine)
        await settle()
        
        #expect(recorder.reasons.isEmpty)
        #expect(controller.isSessionActive)
        
        await controller.deactivateSession()
    }
    
    @Test
    func notificationsWhileInactiveAreIgnored() async {
        let controller = AudioController(theme: .eng1)
        let recorder = StopRecorder()
        controller.onUnexpectedStop = { recorder.reasons.append($0) }
        
        let session = AVAudioSession.sharedInstance()
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: session)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nil)
        controller.handleSessionBecameInactive()
        await settle()
        
        #expect(recorder.reasons.isEmpty)
    }

    // MARK: - Scheduling
    
    private func now() -> MonotonicTimestamp {
        MonotonicTimestamp(seconds: CACurrentMediaTime())
    }
    
    /// The simulator's virtual audio device runs about 0.1 % off the host
    /// clock, so its sample-to-host conversions drift by ~1 ms per second.
    /// Real hardware keeps both clocks within parts per million.
    private var schedulingTolerance: TimeInterval {
        #if targetEnvironment(simulator)
        0.002
        #else
        OutputTiming.maximumScheduleDeviation
        #endif
    }
    
    @Test
    func scheduledSignalStartsWhereScheduled() async throws {
        let (controller, _) = try await activeController()
        let target = MonotonicTimestamp(seconds: now().seconds + 0.3)
        
        let scheduled = try #require(controller.schedule(.go, at: target))
        #expect(scheduled.renderStart == target)
        #expect(controller.measuredPlayback(of: .go) == nil, "measured before it started")
        
        // Measured shortly after the start, as the engine does.
        try await Task.sleep(for: .seconds(0.35))
        
        let measured = try #require(controller.measuredPlayback(of: .go))
        let deviation = measured.renderStart.seconds - target.seconds
        Attachment.record("\(deviation * 1_000_000) µs", named: "Gun deviation from schedule")
        
        #expect(
            abs(deviation) < schedulingTolerance,
            "gun started \(deviation * 1_000_000) µs from its schedule"
        )
        
        await controller.deactivateSession()
    }
    
    @Test
    func schedulingTooSoonIsPushedBack() async throws {
        let (controller, _) = try await activeController()
        let before = now()
        
        let scheduled = try #require(controller.schedule(.go, at: MonotonicTimestamp(seconds: before.seconds - 1)))
        
        let lead = OutputTiming.minimumLead(ioBufferDuration: AVAudioSession.sharedInstance().ioBufferDuration)
        #expect(scheduled.renderStart.seconds >= before.seconds + lead)
        
        try await Task.sleep(for: .seconds(lead + 0.05))
        let measured = try #require(controller.measuredPlayback(of: .go))
        #expect(abs(measured.renderStart.seconds - scheduled.renderStart.seconds) < schedulingTolerance)
        
        await controller.deactivateSession()
    }
    
    @Test
    func stopCancelsScheduledSignal() async throws {
        let (controller, _) = try await activeController()
        
        _ = try #require(controller.schedule(.go, at: MonotonicTimestamp(seconds: now().seconds + 0.2)))
        controller.stop()
        
        try await Task.sleep(for: .seconds(0.4))
        
        #expect(controller.measuredPlayback(of: .go) == nil)
        
        await controller.deactivateSession()
    }
    
    @Test
    func audibleOnsetIncludesOnsetOffsetAndLatency() async throws {
        let (controller, _) = try await activeController()
        
        let scheduled = try #require(controller.schedule(.go, at: MonotonicTimestamp(seconds: now().seconds + 0.2)))
        let onset = try #require(controller.onsetOffsets[.go])
        
        let delay = scheduled.audibleOnset.best.seconds - scheduled.renderStart.seconds
        let session = AVAudioSession.sharedInstance()
        Attachment.record(
            """
            render to audible onset: \(delay * 1000) ms
            onset in file: \(onset * 1000) ms
            uncertainty: ±\((scheduled.audibleOnset.latest.seconds - scheduled.audibleOnset.best.seconds) * 1000) ms
            session outputLatency: \(session.outputLatency * 1000) ms, ioBuffer: \(session.ioBufferDuration * 1000) ms
            route: \(session.currentRoute.outputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", "))
            """,
            named: "Output timing"
        )
        
        #expect(delay >= onset, "render to audible onset \(delay * 1000) ms, onset \(onset * 1000) ms")
        #expect(scheduled.audibleOnset.earliest <= scheduled.audibleOnset.best)
        
        controller.stop()
        await controller.deactivateSession()
    }
    
    @Test
    func scheduleFailsWithoutActiveSession() {
        let controller = AudioController(theme: .eng1)
        
        #expect(controller.schedule(.go, at: now()) == nil)
    }

    // MARK: - Microphone (needs access: simctl privacy grant, or allow once on a device)
    
    private nonisolated static var microphoneGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }
    
    /// Opt-in: plays the gun six times at full session volume.
    private nonisolated static var calibrationRequested: Bool {
        ProcessInfo.processInfo.environment["RUN_CALIBRATION"] == "1"
    }
    
    @Test(.enabled(if: microphoneGranted))
    func recorderDeliversTimestampedSamples() async throws {
        // The speaker setup records, so it activates with microphone input.
        let controller = AudioController(theme: .eng1)
        controller.output = .iPhoneSpeaker
        try await controller.activateSession()
        
        let recorder = MicrophoneRecorder()
        try recorder.start()
        try await Task.sleep(for: .seconds(0.5))
        let chunks = recorder.stop()
        
        let samples = chunks.reduce(0) { $0 + $1.samples.count }
        #expect(samples > 0)
        
        // Consecutive chunks follow each other on the host clock.
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            let expected = previous.hostSeconds + Double(previous.samples.count) / previous.sampleRate
            #expect(abs(next.hostSeconds - expected) < 0.005)
        }
        
        await controller.deactivateSession()
    }
    
    @Test(.enabled(if: microphoneGranted && calibrationRequested), arguments: AudioOutput.allCases)
    func calibrationMeasuresCurrentOutput(output: AudioOutput) async throws {
        let controller = AudioController(theme: .eng1)
        controller.output = output
        
        do {
            let calibration = try await controller.calibrateCurrentOutput()
            Attachment.record(
                """
                \(calibration.routeName): \(calibration.correction * 1000) ms ± \(calibration.uncertainty * 1000) ms \
                from \(calibration.clickCount) clicks
                """,
                named: "Calibration \(output)"
            )
            
            // What a start on this output makes of it: the latency reported
            // in the start's session category against the calibration's.
            controller.calibrations = [calibration.routeID: calibration]
            let preflight = try await controller.prepareForStart()
            Attachment.record(
                """
                \(preflight.gunTiming.route?.name ?? "none"): latency at the calibration                 \((calibration.reportedLatency ?? -1) * 1000) ms, at a start \(preflight.gunTiming.outputLatency * 1000) ms,                 calibration applied: \(preflight.gunTiming.calibration != nil),                 uncertainty \(preflight.gunTiming.uncertainty * 1000) ms
                """,
                named: "Calibration at a start \(output)"
            )
            await controller.deactivateSession()
        } catch CalibrationError.inconsistentClicks(let offsets) {
            let listed = offsets.map { String(format: "%.1f", $0 * 1000) }.joined(separator: ", ")
            Issue.record("Calibration on \(output) inconsistent, offsets: \(listed) ms")
        } catch {
            Issue.record("Calibration on \(output) failed: \(error.localizedDescription)")
        }
        
        #expect(!controller.isSessionActive)
    }

    // MARK: - Applying calibrations
    
    @Test
    func scheduledSignalIncludesCalibrationOfCurrentRoute() async throws {
        let (controller, _) = try await activeController()
        let route = try #require(controller.currentOutput())
        let at = MonotonicTimestamp(seconds: now().seconds + 0.3)
        
        let uncalibrated = try #require(controller.schedule(.go, at: at))
        
        controller.calibrations = [route.id: .fake(routeID: route.id, correction: 0.107, uncertainty: 0.004)]
        let calibrated = try #require(controller.schedule(.go, at: at))
        
        let shift = calibrated.audibleOnset.best.seconds - uncalibrated.audibleOnset.best.seconds
        #expect(abs(shift - 0.107) < 0.000_001)
        #expect(abs(calibrated.audibleOnset.latest.seconds - calibrated.audibleOnset.best.seconds - 0.004) < 0.000_001)
        
        controller.stop()
        await controller.deactivateSession()
    }
    
    // MARK: - Preflight
    
    @Test
    func preflightActivatesAndReportsOutputTiming() async throws {
        let controller = AudioController(theme: .eng1)
        
        let preflight = try await controller.prepareForStart()
        let route = try #require(controller.currentOutput())
        
        #expect(controller.isSessionActive)
        #expect(controller.engine.isRunning)
        #expect(preflight.sampleRate > 0)
        #expect(preflight.ioBufferDuration > 0)
        #expect(preflight.gunTiming.route == route)
        #expect(preflight.gunTiming.onsetOffset == controller.onsetOffsets[.go])
        #expect(preflight.gunTiming.calibration == nil)
        #expect(preflight.gunTiming.uncertainty > 0)
        
        await controller.deactivateSession()
    }
    
    @Test
    func preflightAndScheduledGunShareTheCalibration() async throws {
        let controller = AudioController(theme: .eng1)
        let route = try #require(controller.currentOutput())
        let calibration = OutputCalibration.fake(routeID: route.id, correction: 0.107, uncertainty: 0.004)
        controller.calibrations = [route.id: calibration]
        
        let preflight = try await controller.prepareForStart()
        let gun = try #require(controller.schedule(.go, at: MonotonicTimestamp(seconds: now().seconds + 0.3)))
        
        #expect(preflight.gunTiming.calibration == calibration)
        #expect(preflight.gunTiming.uncertainty == 0.004)
        #expect(!preflight.isCalibrationMissing)
        #expect(gun.basis.calibration == calibration)
        #expect(gun.basis.route == preflight.gunTiming.route)
        #expect(gun.audibleOnset == gun.basis.audibleOnset(renderStart: gun.renderStart))
        
        controller.stop()
        await controller.deactivateSession()
    }
    
    @Test
    func calibrationOfAnotherRouteIsIgnored() async throws {
        let (controller, _) = try await activeController()
        let at = MonotonicTimestamp(seconds: now().seconds + 0.3)
        
        let uncalibrated = try #require(controller.schedule(.go, at: at))
        controller.calibrations = ["some-other-device": .fake(routeID: "some-other-device", correction: 0.2)]
        let scheduled = try #require(controller.schedule(.go, at: at))
        
        #expect(scheduled.audibleOnset == uncalibrated.audibleOnset)
        
        controller.stop()
        await controller.deactivateSession()
    }
    
    /// Device check: a calibration is stored under the route ID seen while
    /// recording, but looked up while starts play in `.playback`.
    @Test(.enabled(if: microphoneGranted && calibrationRequested))
    func routeIDAndLatencyMatchAcrossCategories() async throws {
        let session = AVAudioSession.sharedInstance()
        
        func snapshot(_ label: String) -> (id: String?, line: String) {
            let port = session.currentRoute.outputs.first
            return (
                port?.uid,
                "\(label): \(port?.portName ?? "none") [\(port?.portType.rawValue ?? "-")] uid \(port?.uid ?? "-"), " +
                "outputLatency \(session.outputLatency * 1000) ms, ioBuffer \(session.ioBufferDuration * 1000) ms, rate \(session.sampleRate)"
            )
        }
        
        let starts = AudioController(theme: .eng1)
        try await starts.activateSession()
        let playback = snapshot("playback (starts)")
        await starts.deactivateSession()
        
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP, .defaultToSpeaker])
        try session.setActive(true)
        let recording = snapshot("playAndRecord (calibration)")
        try session.setActive(false)
        
        Attachment.record("\(playback.line)\n\(recording.line)", named: "Route across categories")
        #expect(playback.id == recording.id, "the calibration would be stored under a different route ID")
    }

    // MARK: - Hardware reconfiguration
    
    @Test
    func schedulingRestartsEngineStoppedByReconfiguration() async throws {
        let (controller, recorder) = try await activeController()
        controller.engine.stop()
        
        let scheduled = controller.schedule(.go, at: MonotonicTimestamp(seconds: now().seconds + 0.2))
        
        #expect(scheduled != nil)
        #expect(controller.engine.isRunning)
        #expect(recorder.reasons.isEmpty)
        
        controller.stop()
        await controller.deactivateSession()
    }
    
    @Test
    func reconfigurationWithNothingPlayingRestartsQuietly() async throws {
        let (controller, recorder) = try await activeController()
        controller.engine.stop()
        
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: controller.engine)
        await waitUntil { controller.engine.isRunning }
        await settle()
        
        #expect(recorder.reasons.isEmpty)
        #expect(controller.isSessionActive)
        
        await controller.deactivateSession()
    }
    
    @Test
    func reconfigurationCuttingOffScheduledGunReports() async throws {
        let (controller, recorder) = try await activeController()
        _ = try #require(controller.schedule(.go, at: MonotonicTimestamp(seconds: now().seconds + 1)))
        controller.engine.stop()
        
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: controller.engine)
        await waitUntil { recorder.reasons.count == 1 }
        
        await controller.deactivateSession()
    }
}

@MainActor
private final class StopRecorder {
    var reasons: [String] = []
}

