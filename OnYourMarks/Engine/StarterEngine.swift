//
//  StarterEngine.swift
//  OnYourMarks
//
//  Created by Felix on 12.06.26.
//

import Foundation
import OSLog

struct Phase: Equatable {
    let state: StarterState
    let duration: TimeInterval?
    let signal: Signal?
}

@Observable
@MainActor
final class StarterEngine {
    private(set) var state: StarterState = .idle
    private(set) var isRunning: Bool = false
    
    /// Same as `lastReactionEstimate?.best`; kept for a simple reaction-time display.
    private(set) var lastReactionTime: TimeInterval?
    
    private(set) var lastReactionEstimate: DurationEstimate?
    private(set) var lastDecision: StartDecision?
    
    private(set) var currentSession: StartSession?
    private(set) var lastSession: StartSession?
    
    private let player: SignalPlayer
    private let movementDetector: MovementDetector
    
    private let clock: MonotonicClock
    private let decisionEngine: DecisionEngine
    
    private var sequenceTask: Task<Void, Never>?
    
    /// When the gun is heard, set once it has started.
    /// Before that, any movement is a false start.
    private var gunTime: TimeEstimate?
    private var scheduledGun: ScheduledSignal?
    
    /// Long enough for the first render cycles to have passed.
    private static let gunMeasurementDelay: TimeInterval = 0.05
    
    /// Recall shots after a false start, and the pause between them.
    private static let recallShots = 3
    private static let recallGap: TimeInterval = 0.30
    
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "OnYourMarks",
        category: "Engine"
    )
    
    private var monitoringActive: Bool = false
    
    var onRunEnded: (() -> Void)?
    var onError: ((String) -> Void)?
    
    private enum SequenceOutcome {
        case completed
        case cancelled
        case failed(String)
    }
    
    convenience init(
        player: SignalPlayer,
        movementDetector: MovementDetector
    ) {
        self.init(
            player: player,
            movementDetector: movementDetector,
            clock: SystemMonotonicClock(),
            decisionEngine: DecisionEngine()
        )
    }
    
    init(
        player: SignalPlayer,
        movementDetector: MovementDetector,
        clock: MonotonicClock,
        decisionEngine: DecisionEngine
    ) {
        self.player = player
        self.movementDetector = movementDetector
        self.clock = clock
        self.decisionEngine = decisionEngine
        
        self.movementDetector.onMovement = { [weak self] moveTime in
            self?.handleMovement(at: moveTime)
        }
    }
    
    func start(config: StartConfig) {
        guard !isRunning else { return }
        
        player.stop()
        
        gunTime = nil
        scheduledGun = nil
        lastReactionTime = nil
        lastReactionEstimate = nil
        lastDecision = nil
        monitoringActive = false
        
        let profile = config.startType.profile
        let now = clock.now()
        
        currentSession = StartSession(
            startType: config.startType,
            profile: profile,
            createdAt: now
        )
        
        isRunning = true
        
        sequenceTask = Task { [weak self] in
            guard let self else { return }
            
            let outcome = await runSequence(config: config)
            
            // abort() or triggerFalseStart() runs own cleanup after cancellation
            guard !Task.isCancelled else { return }
            
            switch outcome {
            case .completed:
                self.finishRun(outcome: .completed)
                
            case .failed(let message):
                self.onError?(message)
                self.finishRun(outcome: .failed(message))
                
            case .cancelled:
                break
            }
        }
    }
    
    func abort(reason: String? = nil) {
        guard isRunning else { return }
        
        sequenceTask?.cancel()
        sequenceTask = nil
        
        player.stop()
        stopMovementMonitoring()
        
        gunTime = nil
        scheduledGun = nil
        setState(.idle)
        isRunning = false
        
        finalizeSession(
            outcome: reason.map(StartSessionOutcome.failed) ?? .aborted
        )
        
        onRunEnded?()
    }
    
    private func finishRun(outcome: StartSessionOutcome) {
        guard isRunning else { return }
        
        sequenceTask = nil
        
        player.stop()
        stopMovementMonitoring()
        
        gunTime = nil
        scheduledGun = nil
        setState(.idle)
        isRunning = false
        
        finalizeSession(outcome: outcome)
        
        onRunEnded?()
    }
    
    private func handleMovement(
        at rawMoveTime: TimeInterval
    ) {
        guard state == .waitForStart || state == .start else { return }
        
        guard let profile = currentSession?.profile else { return }
        
        // For now movementTime comes from CMSampleBuffer timestamp
        // Todo for later will map capture timestamps
        let movementTime = TimeEstimate.exact(MonotonicTimestamp(seconds: rawMoveTime))
        
        record(
            .movementObserved,
            at: movementTime,
            source: .cameraLocal
        )
        
        guard let gunTime else {
            let decision = StartDecision.definiteFalseStart
            
            logger.info("Movement before the gun: false start")
            
            lastDecision = decision
            
            record(
                .decision(decision),
                at: movementTime,
                source: .system
            )
            
            triggerFalseStart()
            return
        }
        
        let reaction = movementTime.duration(since: gunTime)
        
        lastReactionEstimate = reaction
        lastReactionTime = reaction.best
        
        record(
            .reactionMeasured(reaction),
            at: movementTime,
            source: .cameraLocal
        )
        
        let decision = decisionEngine.evaluateReaction(reaction, profile: profile)
        
        lastDecision = decision
        
        logger.info(
            """
            Reaction \(reaction.best * 1000, format: .fixed(precision: 1)) ms \
            (\(reaction.earliest * 1000, format: .fixed(precision: 1)) to \
            \(reaction.latest * 1000, format: .fixed(precision: 1)) ms): \
            \(String(describing: decision), privacy: .public)
            """
        )
        
        record(
            .decision(decision),
            at: movementTime,
            source: .system
        )
        
        switch decision {
        case .definiteFalseStart:
            triggerFalseStart()
            
        case .uncertain,
                .legal,
                .notApplicable:
            stopMovementMonitoring()
        }
    }
    
    private func triggerFalseStart() {
        guard isRunning, state != .falseStart else { return }
        
        sequenceTask?.cancel()
        
        player.stop()
        stopMovementMonitoring()
        
        setState(.falseStart)
        
        sequenceTask = Task { [weak self] in
            guard let self else { return }
            
            await self.player.playRecall(times: Self.recallShots, gap: Self.recallGap)
            
            guard !Task.isCancelled else { return }
            
            self.finishRun(outcome: .falseStart)
        }
    }
    
    private func runSequence(config: StartConfig) async -> SequenceOutcome {
        let phases = buildSequence(config: config)
        
        for phase in phases {
            guard !Task.isCancelled else {
                return .cancelled
            }
            
            setState(phase.state)
            
            switch phase.state {
            case .preparing:
                // The preflight runs within the initial wait and only
                // extends it when it takes longer.
                let ready = MonotonicTimestamp(seconds: clock.now().seconds + (phase.duration ?? 0))
                
                do {
                    try await runPreflight()
                } catch {
                    return .failed(String(localized: "The start could not be prepared: \(error.localizedDescription)"))
                }
                
                guard !Task.isCancelled, await sleep(until: ready) else { return .cancelled }
                
            case .waitForStart:
                startMovementMonitoring()
                
                // The gun goes on the audio clock now, so the hold ends exactly
                // as scheduled however late this task wakes up.
                let requested = MonotonicTimestamp(seconds: clock.now().seconds + (phase.duration ?? 0))
                
                guard let gun = player.schedule(.go, at: requested) else {
                    return .failed(String(localized: "The start signal could not be played."))
                }
                
                scheduledGun = gun
                record(.gunScheduled(gun.basis), at: gun.audibleOnset, source: .audioLocal)
                
                // Off the timing path: the gun no longer depends on this task.
                player.logTimingDiagnostics(label: "Gun scheduled")
                
                guard await sleep(until: gun.renderStart) else { return .cancelled }
                
            case .start:
                // Already playing from the schedule.
                gunTime = scheduledGun?.audibleOnset
                
                // Read back early: the estimate extrapolates over the time
                // since the start, so any clock drift grows with it.
                let duration = player.duration(of: .go)
                let measureAfter = min(Self.gunMeasurementDelay, duration)
                
                guard await sleep(for: measureAfter) else { return .cancelled }
                recordMeasuredGun()
                guard await sleep(for: duration - measureAfter) else { return .cancelled }
                
            default:
                if let signal = phase.signal {
                    guard player.play(signal) else {
                        return .failed(String(localized: "The start signal could not be played."))
                    }
                    
                    guard await sleep(for: player.duration(of: signal)) else { return .cancelled }
                } else if let duration = phase.duration {
                    guard await sleep(for: duration) else { return .cancelled }
                }
            }
        }
        return .completed
    }
    
    private func runPreflight() async throws {
        let began = clock.now().seconds
        let preflight = try await player.prepareForStart()
        let timing = preflight.gunTiming
        
        record(.audioPrepared(preflight), source: .audioLocal)
        
        logger.info(
            """
            Preflight took \((self.clock.now().seconds - began) * 1000, format: .fixed(precision: 0)) ms: \
            \(timing.route?.name ?? "no output", privacy: .public), \
            \(preflight.sampleRate, format: .fixed(precision: 0)) Hz, \
            buffer \(preflight.ioBufferDuration * 1000, format: .fixed(precision: 1)) ms, \
            latency \(timing.outputLatency * 1000, format: .fixed(precision: 1)) ms, \
            correction \((timing.calibration?.correction ?? 0) * 1000, format: .fixed(precision: 1)) ms, \
            ±\(timing.uncertainty * 1000, format: .fixed(precision: 1)) ms
            """
        )
        
        if preflight.isCalibrationMissing {
            logger.notice("Wireless output without calibration: the gun time is only an estimate")
        }
    }
    
    /// False if cancelled.
    private func sleep(for seconds: TimeInterval) async -> Bool {
        do {
            try await Task.sleep(for: .seconds(max(0, seconds)))
            return true
        } catch {
            return false
        }
    }
    
    private func sleep(until time: MonotonicTimestamp) async -> Bool {
        await sleep(for: time.seconds - clock.now().seconds)
    }
    
    /// Records when the gun was actually heard, as read back from the render timeline.
    private func recordMeasuredGun() {
        guard let scheduled = scheduledGun else { return }
        
        guard let measured = player.measuredPlayback(of: .go) else {
            logger.error("Gun playback could not be measured")
            return
        }
        
        record(.gunPlaybackMeasured, at: measured.audibleOnset, source: .audioLocal)
        
        let deviation = measured.renderStart.seconds - scheduled.renderStart.seconds
        
        if abs(deviation) > OutputTiming.maximumScheduleDeviation {
            logger.error("Gun started \(deviation * 1000, format: .fixed(precision: 3)) ms off its schedule")
        } else {
            logger.info("Gun started \(deviation * 1_000_000, format: .fixed(precision: 1)) µs from its schedule")
        }
    }
    
    func buildSequence(config: StartConfig) -> [Phase] {
        switch config.startType {
        case .block:
            return [
                Phase(state: .preparing, duration: config.blockTimeToReady, signal: nil),
                Phase(state: .onYourMarks, duration: nil, signal: .onYourMarks),
                Phase(state: .waitForSet, duration: config.blockTimeToSet, signal: nil),
                Phase(state: .set, duration: nil, signal: .set),
                Phase(state: .waitForStart, duration: randomTimeToStart(config.blockTimeToStartMin, config.blockTimeToStartMax), signal: nil),
                Phase(state: .start, duration: nil, signal: .go),
            ]
        case .standing:
            return [
                Phase(state: .preparing, duration: config.standingTimeToReady, signal: nil),
                Phase(state: .onYourMarks, duration: nil, signal: .onYourMarks),
                Phase(state: .waitForStart, duration: randomTimeToStart(config.standingTimeToStartMin, config.standingTimeToStartMax), signal: nil),
                Phase(state: .start, duration: nil, signal: .go),
            ]
        }
    }
    
    private func randomTimeToStart(_ a: Double, _ b: Double) -> TimeInterval {
        Double.random(in: min(a, b)...max(a, b))
    }
    
    private func setState(_ newState: StarterState) {
        guard state != newState else {
            return
        }
        
        state = newState
        
        record(.stateChanged(newState), source: .system)
    }
    
    private func startMovementMonitoring() {
        guard !monitoringActive else {
            return
        }
        
        movementDetector.startMonitoring()
        monitoringActive = true
        
        record(.monitoringStarted, source: .system)
    }
    
    private func stopMovementMonitoring() {
        guard monitoringActive else {
            return
        }
        
        movementDetector.stopMonitoring()
        monitoringActive = false
        
        record(.monitoringStopped, source: .system)
    }

    private func record(
        _ kind: StartEventKind,
        at time: TimeEstimate? = nil,
        source: MeasurementSource,
        athleteID: AthleteID? = nil
    ) {
        guard currentSession != nil else {
            return
        }
        
        let eventTime = time ?? TimeEstimate.exact(clock.now())
        
        currentSession?.record(kind, at: eventTime, source: source, athleteID: athleteID)
    }
    
    private func finalizeSession(outcome: StartSessionOutcome) {
        guard var session = currentSession else {
            return
        }
        
        session.finish(outcome, at: .exact(clock.now()))
        
        lastSession = session
        currentSession = nil
    }
}
