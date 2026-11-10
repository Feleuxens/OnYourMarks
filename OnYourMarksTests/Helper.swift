//
//  Helper.swift
//  OnYourMarks
//
//  Created by Felix on 23.08.26.
//
import Foundation
import QuartzCore
import Testing
@testable import OnYourMarks

@MainActor
class FakeSignalPlayer: SignalPlayer {
    var played: [Signal] = []
    /// Label of each diagnostics call, with how many signals had played by then.
    var diagnostics: [(label: String, playedCount: Int)] = []
    var stopCount = 0
    var recallCount = 0
    
    var failingSignal: Signal?
    
    /// Length of the gun; zero lets sequences run instantly.
    var gunDuration: TimeInterval = 0
    /// Added between render start and the audible onset.
    var outputLatency: TimeInterval = 0
    
    /// Returned by the preflight, which fails with `preflightError` if set.
    var preflight = AudioPreflight.fake()
    var preflightError: Error?
    /// How long the preflight takes.
    var preflightDuration: Duration = .zero
    private(set) var preflightCount = 0
    
    /// The scheduled signal that stop() has not cancelled yet.
    private(set) var pendingSchedule: ScheduledSignal?
    private(set) var scheduleRequests: [MonotonicTimestamp] = []
    
    func play(_ signal: Signal) -> Bool {
        if signal == failingSignal {
            return false
        }
        
        played.append(signal)
        return true
    }
    
    func schedule(_ signal: Signal, at time: MonotonicTimestamp) -> ScheduledSignal? {
        scheduleRequests.append(time)
        
        guard signal != failingSignal else { return nil }
        
        played.append(signal)
        
        let scheduled = ScheduledSignal(
            signal: signal,
            renderStart: time,
            audibleOnset: .exact(MonotonicTimestamp(seconds: time.seconds + outputLatency)),
            basis: preflight.gunTiming
        )
        pendingSchedule = scheduled
        return scheduled
    }
    
    func measuredPlayback(of signal: Signal) -> ScheduledSignal? {
        pendingSchedule?.signal == signal ? pendingSchedule : nil
    }
    
    func stop() {
        stopCount += 1
        pendingSchedule = nil
    }
    
    func playRecall(times: Int, gap: TimeInterval) async {
        for _ in 0..<times {
            guard !Task.isCancelled else { return }
            
            recallCount += 1
            _ = play(.go)
        }
    }
    
    /// Length of the spoken commands.
    var commandDuration: TimeInterval = 0
    
    func duration(of signal: Signal) -> TimeInterval {
        signal == .go ? gunDuration : commandDuration
    }
    
    func logTimingDiagnostics(label: String) {
        diagnostics.append((label, played.count))
    }
    
    func prepareForStart() async throws -> AudioPreflight {
        preflightCount += 1
        
        if preflightDuration > .zero {
            try await Task.sleep(for: preflightDuration)
        }
        
        if let preflightError {
            throw preflightError
        }
        return preflight
    }
}

struct FakeActivationError: LocalizedError {
    var errorDescription: String? { "Activation refused" }
}

/// Session player whose activation can be held open to test the "activating" window.
@MainActor
final class FakeSessionPlayer: FakeSignalPlayer, AudioSessionPlayer {
    var theme: SoundTheme = .eng1
    var output: AudioOutput = .automatic
    var calibrations: [String: OutputCalibration] = [:]
    var onUnexpectedStop: ((String) -> Void)?
    var onRouteChange: (() -> Void)?
    
    var route: OutputRoute? = OutputRoute(id: "headphones", name: "Headphones", isWireless: true, isBuiltInSpeaker: false)
    
    /// Returned by the next calibration; nil makes it throw `calibrationError`.
    var calibrationResult: OutputCalibration?
    var calibrationError: Error = FakeActivationError()
    private(set) var calibrationCount = 0
    
    private(set) var activateCount = 0
    private(set) var deactivateCount = 0
    private(set) var isSessionActive = false
    
    /// While true, activateSession() waits until releaseActivation() is called.
    var holdsActivation = false
    var activationError: Error?
    
    private var pendingActivations: [CheckedContinuation<Void, Never>] = []
    
    /// Like the real controller, transitions run one after the other and
    /// to the end, also when the caller is cancelled.
    private var transition: Task<Void, Never>?
    
    var isActivationPending: Bool {
        !pendingActivations.isEmpty
    }
    
    func activateSession() async throws {
        activateCount += 1
        
        let previous = transition
        let activation = Task {
            await previous?.value
            
            if holdsActivation {
                await withCheckedContinuation { pendingActivations.append($0) }
            }
            
            if let activationError {
                throw activationError
            }
            
            isSessionActive = true
        }
        
        transition = Task { _ = try? await activation.value }
        try await activation.value
    }
    
    func deactivateSession() async {
        let previous = transition
        let deactivation = Task {
            await previous?.value
            
            guard isSessionActive else { return }
            
            deactivateCount += 1
            isSessionActive = false
        }
        
        transition = deactivation
        await deactivation.value
    }
    
    override func prepareForStart() async throws -> AudioPreflight {
        try await activateSession()
        try Task.checkCancellation()
        return try await super.prepareForStart()
    }
    
    func releaseActivation() {
        let pending = pendingActivations
        pendingActivations.removeAll()
        
        for continuation in pending {
            continuation.resume()
        }
    }
    
    /// Simulates the system taking audio away (route change, call, reset).
    func failUnexpectedly(_ reason: String) {
        onUnexpectedStop?(reason)
    }
    
    func currentOutput() -> OutputRoute? {
        route
    }
    
    func calibrateCurrentOutput() async throws -> OutputCalibration {
        calibrationCount += 1
        await Task.yield()
        
        guard let calibrationResult else { throw calibrationError }
        return calibrationResult
    }
    
    /// Simulates the system switching outputs.
    func changeRoute(to route: OutputRoute?) {
        self.route = route
        onRouteChange?()
    }
}

final class FakeMovementDetector: MovementDetector {
    var onMovement: ((MovementObservation) -> Void)?
    var onTrackingChange: ((AthleteTrackingChange) -> Void)?
    
    /// Returned as the roster of each monitoring.
    var roster = AthleteRoster.empty
    
    private(set) var startCount = 0
    private(set) var stopCount = 0
    
    @discardableResult
    func startMonitoring() -> AthleteRoster {
        startCount += 1
        return roster
    }
    
    func stopMonitoring() {
        stopCount += 1
    }
    
    /// When each precision window began, on the host clock.
    private(set) var precisionBegins: [TimeInterval] = []
    private(set) var precisionEndCount = 0
    
    var isInPrecisionWindow: Bool {
        precisionBegins.count > precisionEndCount
    }
    
    func beginPrecisionWindow() {
        precisionBegins.append(CACurrentMediaTime())
    }
    
    func endPrecisionWindow() {
        precisionEndCount += 1
    }
    
    func emitMovement(
        at time: TimeInterval,
        athlete: AthleteID? = nil,
        quality: TrackingQuality? = nil
    ) {
        onMovement?(
            MovementObservation(time: MonotonicTimestamp(seconds: time), athleteID: athlete, quality: quality)
        )
    }
    
    func emitTrackingChange(_ state: AthleteTrackState, athlete: AthleteID, at time: TimeInterval) {
        onTrackingChange?(
            AthleteTrackingChange(athleteID: athlete, state: state, time: MonotonicTimestamp(seconds: time))
        )
    }
}

/// Yields until the condition holds, failing the test after the timeout.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: () -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    
    while ContinuousClock.now < deadline {
        if condition() {
            return
        }

        await Task.yield()
    }

    #expect(condition())
}

extension AudioPreflight {
    static func fake(
        route: OutputRoute? = OutputRoute(id: "speaker", name: "Speaker", isWireless: false, isBuiltInSpeaker: true),
        calibration: OutputCalibration? = nil
    ) -> AudioPreflight {
        AudioPreflight(
            sampleRate: 48_000,
            ioBufferDuration: 0.005,
            gunTiming: SignalTimingBasis(
                route: route,
                outputLatency: 0.012,
                onsetOffset: 0.024,
                calibration: calibration,
                uncertainty: OutputTiming.wiredUncertainty
            )
        )
    }
}

extension StartEventKind {
    var isGunScheduled: Bool {
        if case .gunScheduled = self { true } else { false }
    }
}

extension OutputCalibration {
    static func fake(
        routeID: String = "headphones",
        isBuiltInSpeaker: Bool = false,
        correction: TimeInterval = 0.04,
        uncertainty: TimeInterval = 0.005
    ) -> OutputCalibration {
        OutputCalibration(
            routeID: routeID,
            routeName: routeID,
            isBuiltInSpeaker: isBuiltInSpeaker,
            correction: correction,
            uncertainty: uncertainty,
            clickCount: 6,
            date: .now
        )
    }
}
