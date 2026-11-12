//
//  Helper.swift
//  OnYourMarks
//
//  Created by Felix on 23.08.26.
//
import Foundation
import CoreVideo
import QuartzCore
import Testing
import Vision
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
    /// How long the preflight takes, on `clock` if there is one.
    var preflightDuration: Duration = .zero
    var clock: MonotonicClock?
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
            if let clock {
                let seconds = preflightDuration / .seconds(1)
                await clock.sleep(until: MonotonicTimestamp(seconds: clock.now().seconds + seconds))
                try Task.checkCancellation()
            } else {
                try await Task.sleep(for: preflightDuration)
            }
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
    /// When the session was last given back, on the host clock.
    private(set) var deactivatedAt: TimeInterval?
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
            deactivatedAt = CACurrentMediaTime()
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
    var onEvent: ((DetectorEvent) -> Void)?
    var source = MeasurementSource.cameraLocal
    
    /// Returned as the roster of each monitoring.
    var roster = AthleteRoster.empty
    
    /// Like a detector that sees no one, the fake is ready unless told otherwise.
    private(set) var isReady = true
    /// What `isReady` becomes when an athlete is made to settle again.
    var isReadyAfterResettle = true
    
    private(set) var profiles: [MotionProfile] = []
    private(set) var resettled: [AthleteID?] = []
    
    func setReady(_ ready: Bool) {
        guard ready != isReady else { return }
        
        isReady = ready
        onEvent?(.readinessChanged(ready))
    }
    
    func resettle(_ athlete: AthleteID?) {
        resettled.append(athlete)
        isReady = isReadyAfterResettle
    }
    
    func emitUnsteady(at time: TimeInterval, athlete: AthleteID? = nil, quality: TrackingQuality? = nil) {
        onEvent?(
            .unsteady(MovementObservation(time: MonotonicTimestamp(seconds: time), athleteID: athlete, quality: quality))
        )
    }
    
    private(set) var startCount = 0
    private(set) var stopCount = 0
    
    @discardableResult
    func startMonitoring(profile: MotionProfile) -> AthleteRoster {
        startCount += 1
        profiles.append(profile)
        return roster
    }
    
    func stopMonitoring() {
        stopCount += 1
    }
    
    /// When each precision window began, on `clock`.
    private(set) var precisionBegins: [TimeInterval] = []
    var clock: MonotonicClock = SystemMonotonicClock()
    private(set) var precisionEndCount = 0
    
    var isInPrecisionWindow: Bool {
        precisionBegins.count > precisionEndCount
    }
    
    func beginPrecisionWindow() {
        precisionBegins.append(clock.now().seconds)
    }
    
    func endPrecisionWindow() {
        precisionEndCount += 1
    }
    
    /// A movement made certain at `time`. Unless `since` says when the
    /// athlete was last seen at rest, it began exactly then.
    func emitMovement(
        at time: TimeInterval,
        since: TimeInterval? = nil,
        athlete: AthleteID? = nil,
        quality: TrackingQuality? = nil
    ) {
        let onset = since.map {
            TimeEstimate(
                best: MonotonicTimestamp(seconds: ($0 + time) / 2),
                earliest: MonotonicTimestamp(seconds: $0),
                latest: MonotonicTimestamp(seconds: time)
            )
        }
        
        onEvent?(
            .movement(
                MovementObservation(
                    time: MonotonicTimestamp(seconds: time), onset: onset, athleteID: athlete, quality: quality
                )
            )
        )
    }
    
    /// The beginning of a reported movement, narrowed down to two frames.
    func emitRefinement(from earliest: TimeInterval, to latest: TimeInterval, athlete: AthleteID, droppedFrames: Int = 0) {
        onEvent?(
            .onsetRefined(
                OnsetRefinement(
                    athleteID: athlete,
                    onset: TimeEstimate(
                        best: MonotonicTimestamp(seconds: (earliest + latest) / 2),
                        earliest: MonotonicTimestamp(seconds: earliest),
                        latest: MonotonicTimestamp(seconds: latest)
                    ),
                    droppedFrames: droppedFrames
                )
            )
        )
    }
    
    func emitTrackingChange(_ state: AthleteTrackState, athlete: AthleteID, at time: TimeInterval) {
        onEvent?(
            .trackingChanged(AthleteTrackingChange(athleteID: athlete, state: state, time: MonotonicTimestamp(seconds: time)))
        )
    }
}

/// Yields until the condition holds, failing the test after the timeout.
///
/// The timeout counts the time the waiting test saw pass in its own turns,
/// not the wall clock: a turn that took longer than `waitStallLimit` counts
/// as that. Otherwise a wait fails without anything having had a chance to
/// run, when the process stood still or the main actor was held: under
/// Xcode's debugger on the device each library loaded during the run stops
/// the process (measured: 10 stops of 0.27 to 0.78 s, 4.5 s of the first
/// 5.5 s).
@MainActor
func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: () -> Bool
) async {
    let clock = ContinuousClock()
    let giveUp = clock.now + timeout * waitWallClockFactor
    var waited = Duration.zero
    var last = clock.now
    
    while waited < timeout, clock.now < giveUp {
        if condition() {
            return
        }

        await Task.yield()
        
        let now = clock.now
        waited += min(now - last, waitStallLimit)
        last = now
    }

    #expect(condition())
}

/// The longest one turn of a waiting test counts towards its timeout. A
/// turn is one round of the main actor through everything that waits, a
/// few milliseconds with all suites in parallel; longer ones are stalls.
private let waitStallLimit = Duration.milliseconds(50)

/// However little of it counted, a wait ends after this many timeouts.
private let waitWallClockFactor = 10

/// A clock that only moves when the test moves it, so what the engine does
/// at which time can be checked exactly, however long the process stood
/// still meanwhile.
@MainActor
final class ManualClock: MonotonicClock {
    private var seconds: TimeInterval
    private var sleepers: [UUID: (deadline: TimeInterval, continuation: CheckedContinuation<Void, Never>)] = [:]
    
    /// Rounds of the main actor given to whoever was woken before the time
    /// moves on. From a wake-up to the next sleep the engine needs a handful
    /// of main-actor jobs, each at most one round away.
    private static let settleRounds = 50
    
    init(startingAt seconds: TimeInterval = 1000) {
        self.seconds = seconds
    }
    
    func now() -> MonotonicTimestamp {
        MonotonicTimestamp(seconds: seconds)
    }
    
    func sleep(until time: MonotonicTimestamp) async {
        guard time.seconds > seconds, !Task.isCancelled else { return }
        
        let id = UUID()
        
        await withTaskCancellationHandler {
            await withCheckedContinuation { sleepers[id] = (time.seconds, $0) }
        } onCancel: {
            Task { @MainActor in self.wake(id) }
        }
    }
    
    /// Lets the time pass. Every sleeper is woken at exactly its own time,
    /// in order, and gets to act before the clock moves on.
    func advance(by duration: TimeInterval) async {
        let target = seconds + duration
        await settle()
        
        while let next = sleepers.values.map({ $0.deadline }).min(), next <= target {
            seconds = max(seconds, next)
            
            for (id, sleeper) in sleepers where sleeper.deadline <= seconds {
                wake(id)
            }
            
            await settle()
        }
        
        seconds = target
        await settle()
    }
    
    private func wake(_ id: UUID) {
        sleepers.removeValue(forKey: id)?.continuation.resume()
    }
    
    private func settle() async {
        for _ in 0..<Self.settleRounds {
            await Task.yield()
        }
    }
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

/// The events of one frame, by kind.
extension [DetectorEvent] {
    var movements: [MovementObservation] {
        compactMap { if case .movement(let observation) = $0 { observation } else { nil } }
    }
    
    var unsteady: [MovementObservation] {
        compactMap { if case .unsteady(let observation) = $0 { observation } else { nil } }
    }
    
    var trackingChanges: [AthleteTrackingChange] {
        compactMap { if case .trackingChanged(let change) = $0 { change } else { nil } }
    }
    
    var readiness: Bool? {
        compactMap { if case .readinessChanged(let ready) = $0 { ready } else { nil } }.last
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

/// Notes what the engine asks of a recorder.
@MainActor
final class FakeStartRecorder: StartRecorder {
    /// Whether there is something to record, like a camera that is on.
    var canRecord = true
    
    private(set) var beginCount = 0
    private(set) var tracking: [TrackingFrame] = []
    private(set) var ended: [(session: StartSession, results: [AthleteStartResult])] = []
    
    func beginRecording() -> Bool {
        guard canRecord else { return false }
        
        beginCount += 1
        return true
    }
    
    func record(_ frame: TrackingFrame) {
        tracking.append(frame)
    }
    
    func endRecording(session: StartSession, results: [AthleteStartResult]) {
        ended.append((session, results))
    }
}

/// A camera whose frames the test sends. They arrive on a queue of their
/// own, as the camera's do: a recorder's work on a frame, like opening the
/// video encoder, must not happen on the main actor.
@MainActor
final class FakeFrameSource: FrameSource {
    var isDelivering = true
    private(set) var handler: (@Sendable (CameraFrame) -> Void)?
    
    private let queue = DispatchSerialQueue(label: "test.frames")
    
    func setRecordingHandler(_ handler: (@Sendable (CameraFrame) -> Void)?) {
        self.handler = handler
    }
    
    /// Delivers one frame captured at the given host time, if a recorder
    /// listens, and returns once the recorder has taken it.
    func deliver(at time: TimeInterval, index: Int = 0) async throws {
        await deliver(try CameraFrame.synthetic(at: time, index: index))
    }
    
    func deliver(_ frame: CameraFrame) async {
        guard let handler else { return }
        
        await Self.run(handler, with: frame, on: queue)
    }
    
    /// Built outside the main actor: the closure runs on the frame queue.
    private nonisolated static func run(
        _ handler: @escaping @Sendable (CameraFrame) -> Void,
        with frame: CameraFrame,
        on queue: DispatchSerialQueue
    ) async {
        await withCheckedContinuation { continuation in
            queue.async {
                handler(frame)
                continuation.resume()
            }
        }
    }
}

extension CameraFrame {
    /// A frame in the camera's pixel format, lying on its side like the
    /// camera's, grey with a brightness that depends on the index.
    static func synthetic(at time: TimeInterval, index: Int = 0, width: Int = 640, height: Int = 360) throws -> CameraFrame {
        var created: CVPixelBuffer?
        CVPixelBufferCreate(
            nil,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &created
        )
        let buffer = try #require(created)
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        for (plane, value) in [(0, UInt8(truncatingIfNeeded: 40 + index * 7)), (1, 128)] {
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
            memset(base, Int32(value), CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        
        return CameraFrame(pixelBuffer: buffer, timestamp: MonotonicTimestamp(seconds: time), index: index)
    }
}

extension RecordingStore {
    /// A store in a folder of its own, so tests don't see each other's recordings.
    static func scratch() -> RecordingStore {
        let root = FileManager.default.temporaryDirectory.appending(path: "RecordingTests-\(UUID().uuidString)")
        
        return RecordingStore(
            temporaryDirectory: root.appending(path: "Last"),
            libraryDirectory: root.appending(path: "Library")
        )
    }
}

extension TrackedAthlete {
    /// An athlete standing upright around the given point of the picture.
    static func fake(
        id: AthleteID = AthleteID(),
        at center: CGPoint = CGPoint(x: 0.5, y: 0.5),
        time: TimeInterval = 0
    ) -> TrackedAthlete {
        TrackedAthlete(
            id: id,
            state: .tracked,
            pose: DetectedPose(
                joints: [
                    .neck: CGPoint(x: center.x, y: center.y + 0.1),
                    .root: CGPoint(x: center.x, y: center.y - 0.1),
                    .leftWrist: CGPoint(x: center.x - 0.05, y: center.y),
                ],
                confidence: 0.9,
                aspectRatio: 9.0 / 16.0
            ),
            lastSeen: MonotonicTimestamp(seconds: time),
            isVisible: true,
            quality: TrackingQuality(state: .tracked, jointCoverage: 1, confidence: 0.9, continuity: 1)
        )
    }
}

extension FakeMovementDetector {
    /// The athletes of one analysed frame.
    func emitTracking(at time: TimeInterval, athletes: [TrackedAthlete] = []) {
        onEvent?(.athletesTracked(TrackingFrame(time: MonotonicTimestamp(seconds: time), athletes: athletes)))
    }
}
