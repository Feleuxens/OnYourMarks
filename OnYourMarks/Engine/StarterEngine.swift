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
    
    /// The athletes of the current or last start, fixed when monitoring began.
    private(set) var roster: AthleteRoster?
    
    /// One entry per athlete that moved, in the order they moved. A
    /// detector that doesn't tell athletes apart contributes one entry.
    private(set) var athleteResults: [AthleteStartResult] = []
    
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
    
    /// When the first false start of this run was seen. Until the
    /// collection ends, further athletes can still be found at fault.
    private var firstFalseStart: MonotonicTimestamp?
    
    /// How long after a false start movements are still taken in: the
    /// window in which another athlete's movement counts as independent,
    /// plus the time a frame needs from capture through pose detection to
    /// the engine (capture to delivery is tested to stay under 0.25 s).
    static let falseStartCollection: TimeInterval = DecisionEngine.independentMovementWindow + 0.25
    
    /// How long the athletes get to hold still, each time, before the start
    /// is given up. A starter would have them stand up well before that.
    var readinessTimeout: TimeInterval = 10
    
    /// How often the gun may be taken back for unsteadiness before the
    /// start is given up instead of holding the field any longer.
    static let maximumHoldRestarts = 3
    
    /// The sleep the sequence is in while it waits for the athletes or for
    /// the gun; cancelled to wake it early.
    private var wakeableSleep: Task<Void, Never>?
    
    /// Set when an athlete became unsteady while the gun was pending.
    private var holdWasDisturbed = false
    
    private var monitoringActive: Bool = false
    private var precisionWindowActive = false
    
    /// How long before the gun the movement detector goes to full speed.
    /// The camera needs about 0.2 s to reach its high frame rate.
    static let precisionLead: TimeInterval = 1
    
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
        
        self.movementDetector.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }
    
    func start(config: StartConfig) {
        guard !isRunning else { return }
        
        player.stop()
        
        gunTime = nil
        scheduledGun = nil
        roster = nil
        athleteResults = []
        firstFalseStart = nil
        holdWasDisturbed = false
        monitoringActive = false
        precisionWindowActive = false
        
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
                self.endRun(outcome: .completed)
                
            case .failed(let message):
                self.onError?(message)
                self.endRun(outcome: .failed(message))
                
            case .cancelled:
                break
            }
        }
    }
    
    func abort(reason: String? = nil) {
        guard isRunning else { return }
        
        sequenceTask?.cancel()
        
        endRun(outcome: reason.map(StartSessionOutcome.failed) ?? .aborted)
    }
    
    /// Everything a run leaves behind, however it ended.
    private func endRun(outcome: StartSessionOutcome) {
        guard isRunning else { return }
        
        sequenceTask = nil
        
        player.stop()
        stopMovementMonitoring()
        endPrecisionWindow()
        
        gunTime = nil
        scheduledGun = nil
        setState(.idle)
        isRunning = false
        
        finalizeSession(outcome: outcome)
        
        onRunEnded?()
    }
    
    private func handle(_ event: DetectorEvent) {
        switch event {
        case .movement(let observation):
            handleMovement(observation)
            
        case .unsteady(let observation):
            handleUnsteady(observation)
            
        case .trackingChanged(let change):
            handleTrackingChange(change)
            
        case .readinessChanged:
            // Wakes the wait for readiness; it looks at the detector itself.
            wakeableSleep?.cancel()
        }
    }
    
    private func handleMovement(
        _ observation: MovementObservation
    ) {
        let athleteID = observation.athleteID
        
        if state == .falseStart {
            // Others may have false-started too; only a detector that tells
            // athletes apart can say so.
            guard monitoringActive, athleteID != nil, let firstFalseStart else { return }
            
            // Without a gun to measure against, only a movement too close
            // to the first one to be a reaction to it is judged.
            guard gunTime != nil
                    || decisionEngine.isIndependentFalseStart(at: observation.time, afterFalseStartAt: firstFalseStart) else {
                return
            }
        } else {
            guard state == .waitForStart || state == .start else { return }
        }
        
        guard let profile = currentSession?.profile else { return }
        
        // Only athletes on the roster are judged, and each only once. A
        // report can still arrive from a frame analysed before monitoring ended.
        if let athleteID {
            guard roster?.contains(athleteID) == true,
                  !athleteResults.contains(where: { $0.athleteID == athleteID }) else {
                return
            }
        }
        
        let position = athleteID.flatMap { roster?.position(of: $0) }
        
        // For now movementTime comes from CMSampleBuffer timestamp
        // Todo for later will map capture timestamps
        let movementTime = TimeEstimate.exact(observation.time)
        
        record(
            .movementObserved(observation.quality),
            at: movementTime,
            source: movementDetector.source,
            athleteID: athleteID
        )
        
        guard let gunTime else {
            let decision = decisionEngine.evaluateMovementBeforeGun(trackingQuality: observation.quality)
            
            logger.info(
                """
                Movement before the gun\(Self.description(position: position), privacy: .public): \
                \(String(describing: decision), privacy: .public)
                """
            )
            
            conclude(
                AthleteStartResult(athleteID: athleteID, position: position, reaction: nil, decision: decision),
                at: movementTime
            )
            return
        }
        
        let reaction = movementTime.duration(since: gunTime)
        
        record(
            .reactionMeasured(reaction),
            at: movementTime,
            source: movementDetector.source,
            athleteID: athleteID
        )
        
        let decision = decisionEngine.qualify(
            decisionEngine.evaluateReaction(reaction, profile: profile),
            by: observation.quality
        )
        
        logger.info(
            """
            Reaction\(Self.description(position: position), privacy: .public) \
            \(reaction.best * 1000, format: .fixed(precision: 1)) ms \
            (\(reaction.earliest * 1000, format: .fixed(precision: 1)) to \
            \(reaction.latest * 1000, format: .fixed(precision: 1)) ms): \
            \(String(describing: decision), privacy: .public)
            """
        )
        
        conclude(
            AthleteStartResult(athleteID: athleteID, position: position, reaction: reaction, decision: decision),
            at: movementTime
        )
    }
    
    /// Stores one athlete's result and acts on it: a false start recalls the
    /// field, anything else lets the others go on being watched.
    private func conclude(_ result: AthleteStartResult, at time: TimeEstimate) {
        athleteResults.append(result)
        
        if result.decision == .definiteFalseStart, firstFalseStart == nil {
            firstFalseStart = time.best
        }
        
        record(
            .decision(result.decision),
            at: time,
            source: .system,
            athleteID: result.athleteID
        )
        
        switch result.decision {
        case .definiteFalseStart:
            triggerFalseStart()
            
        case .uncertain,
                .legal,
                .notApplicable:
            guard everyAthleteHasMoved(after: result) else { return }
            
            stopMovementMonitoring()
            endPrecisionWindow()
        }
    }
    
    /// A detector that doesn't tell athletes apart reports one movement only.
    private func everyAthleteHasMoved(after result: AthleteStartResult) -> Bool {
        guard result.athleteID != nil, let roster else { return true }
        
        return roster.entries.allSatisfy { entry in
            athleteResults.contains { $0.athleteID == entry.id }
        }
    }
    
    private func handleTrackingChange(_ change: AthleteTrackingChange) {
        guard monitoringActive, roster?.contains(change.athleteID) == true else { return }
        
        record(
            .athleteTrackingChanged(change.state),
            at: .exact(change.time),
            source: movementDetector.source,
            athleteID: change.athleteID
        )
    }
    
    private static func description(position: Int?) -> String {
        position.map { " of athlete \($0) from the left" } ?? ""
    }
    
    private func triggerFalseStart() {
        guard isRunning, state != .falseStart else { return }
        
        sequenceTask?.cancel()
        
        player.stop()
        
        setState(.falseStart)
        
        // Monitoring goes on: other athletes may have false-started as well,
        // and their frames are still on the way. endRun() ends it.
        let collectUntil = MonotonicTimestamp(seconds: clock.now().seconds + Self.falseStartCollection)
        
        sequenceTask = Task { [weak self] in
            guard let self else { return }
            
            await self.player.playRecall(times: Self.recallShots, gap: Self.recallGap)
            
            guard !Task.isCancelled, await self.sleep(until: collectUntil) else { return }
            
            self.endRun(outcome: .falseStart)
        }
    }
    
    private func runSequence(config: StartConfig) async -> SequenceOutcome {
        let phases = buildSequence(config: config)
        
        for (index, phase) in phases.enumerated() {
            guard !Task.isCancelled else {
                return .cancelled
            }
            
            setState(phase.state)
            
            let timeToGun = plannedTimeToGun(after: index, in: phases)
            
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
                
                guard !Task.isCancelled, await wait(until: ready, gunIn: timeToGun) else {
                    return .cancelled
                }
                
            case .waitForStart:
                startMovementMonitoring(profile: config.startType.profile.motion)
                
                if let outcome = await runHold(duration: phase.duration ?? 0) {
                    return outcome
                }
                
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
                    
                }
                
                let end = MonotonicTimestamp(seconds: clock.now().seconds + plannedDuration(of: phase))
                guard await wait(until: end, gunIn: timeToGun) else { return .cancelled }
            }
        }
        return .completed
    }
    
    /// Waits until the athletes hold still, then puts the gun on the audio
    /// clock and waits for it. An unsteady athlete takes the gun back and
    /// the hold begins again. Nil once the gun is playing.
    private func runHold(duration: TimeInterval) async -> SequenceOutcome? {
        var restarts = 0
        
        while true {
            let readyBy = MonotonicTimestamp(seconds: clock.now().seconds + readinessTimeout)
            
            while !movementDetector.isReady {
                guard clock.now() < readyBy else {
                    logger.notice("The athletes did not hold still in time")
                    return .failed(String(localized: "The athletes did not hold still, so the start was cancelled."))
                }
                
                guard await sleep(until: readyBy, wakeable: true) else { return .cancelled }
            }
            
            record(.athletesReady, source: movementDetector.source)
            holdWasDisturbed = false
            
            // The hold counts from here, not from the command: the gun must
            // not be predictable from the moment the athletes became still.
            // On the audio clock, so it ends exactly as scheduled however
            // late this task wakes up.
            let requested = MonotonicTimestamp(seconds: clock.now().seconds + duration)
            
            guard let gun = player.schedule(.go, at: requested) else {
                return .failed(String(localized: "The start signal could not be played."))
            }
            
            scheduledGun = gun
            record(.gunScheduled(gun.basis), at: gun.audibleOnset, source: .audioLocal)
            
            // Off the timing path: the gun no longer depends on this task.
            player.logTimingDiagnostics(label: "Gun scheduled")
            
            while !holdWasDisturbed, clock.now() < gun.renderStart {
                guard await wait(until: gun.renderStart, gunIn: 0, wakeable: true) else { return .cancelled }
            }
            
            guard holdWasDisturbed else { return nil }
            
            player.stop()
            scheduledGun = nil
            record(.gunCancelled, source: .system)
            
            restarts += 1
            logger.info("Gun taken back for unsteadiness (\(restarts) of \(Self.maximumHoldRestarts))")
            
            guard restarts <= Self.maximumHoldRestarts else {
                return .failed(String(localized: "The athletes did not hold still, so the start was cancelled."))
            }
        }
    }
    
    private func handleUnsteady(_ observation: MovementObservation) {
        // Only before the gun: afterwards everyone is supposed to move.
        guard state == .waitForStart, monitoringActive, gunTime == nil else { return }
        
        if let athleteID = observation.athleteID {
            guard roster?.contains(athleteID) == true else { return }
        }
        
        record(
            .athleteUnsteady(observation.quality),
            at: .exact(observation.time),
            source: movementDetector.source,
            athleteID: observation.athleteID
        )
        
        // They have to become still again before the gun is armed anew.
        movementDetector.resettle(observation.athleteID)
        
        if scheduledGun != nil {
            holdWasDisturbed = true
            wakeableSleep?.cancel()
        }
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
    
    private func plannedDuration(of phase: Phase) -> TimeInterval {
        phase.duration ?? phase.signal.map(player.duration(of:)) ?? 0
    }
    
    /// How long the phases between the given one and the gun are planned to take.
    private func plannedTimeToGun(after index: Int, in phases: [Phase]) -> TimeInterval {
        phases[(index + 1)...]
            .prefix { $0.state != .start }
            .reduce(0) { $0 + plannedDuration(of: $1) }
    }
    
    /// Sleeps until the deadline and, if the precision window begins before
    /// it, opens the window on the way. False if cancelled.
    ///
    /// The window is placed by the time left to the gun, not by a phase, so
    /// it works the same for every start type and however short the hold is.
    ///
    /// - Parameter gunIn: how long after the deadline the gun is planned.
    /// - Parameter wakeable: a detector event may end the sleep early; the
    ///   caller then looks at what changed and waits again.
    private func wait(until deadline: MonotonicTimestamp, gunIn: TimeInterval, wakeable: Bool = false) async -> Bool {
        let windowStart = MonotonicTimestamp(seconds: deadline.seconds + gunIn - Self.precisionLead)
        
        if windowStart <= deadline {
            guard await sleep(until: windowStart, wakeable: wakeable) else { return false }
            
            // Woken early: not the window's time yet.
            guard !wakeable || clock.now() >= windowStart else { return true }
            
            beginPrecisionWindow()
        }
        
        return await sleep(until: deadline, wakeable: wakeable)
    }
    
    /// False if cancelled.
    private func sleep(for seconds: TimeInterval) async -> Bool {
        await sleep(until: MonotonicTimestamp(seconds: clock.now().seconds + seconds))
    }
    
    /// False if cancelled. A wakeable sleep also ends when `wakeableSleep`
    /// is cancelled, and is then still true.
    private func sleep(until time: MonotonicTimestamp, wakeable: Bool = false) async -> Bool {
        let seconds = max(0, time.seconds - clock.now().seconds)
        let sleeper = Task { _ = try? await Task.sleep(for: .seconds(seconds)) }
        
        if wakeable {
            wakeableSleep = sleeper
        }
        
        await withTaskCancellationHandler {
            await sleeper.value
        } onCancel: {
            sleeper.cancel()
        }
        
        if wakeable {
            wakeableSleep = nil
        }
        
        return !Task.isCancelled
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
    
    private func startMovementMonitoring(profile: MotionProfile) {
        guard !monitoringActive else {
            return
        }
        
        let roster = movementDetector.startMonitoring(profile: profile)
        self.roster = roster
        monitoringActive = true
        
        record(.monitoringStarted, source: .system)
        record(.rosterEstablished(roster), source: movementDetector.source)
        
        logger.info("Roster: \(roster.entries.count) athletes")
    }
    
    private func stopMovementMonitoring() {
        guard monitoringActive else {
            return
        }
        
        movementDetector.stopMonitoring()
        monitoringActive = false
        
        record(.monitoringStopped, source: .system)
    }

    private func beginPrecisionWindow() {
        guard !precisionWindowActive else { return }
        
        movementDetector.beginPrecisionWindow()
        precisionWindowActive = true
        
        record(.precisionWindowBegan, source: .system)
    }
    
    private func endPrecisionWindow() {
        guard precisionWindowActive else { return }
        
        movementDetector.endPrecisionWindow()
        precisionWindowActive = false
        
        record(.precisionWindowEnded, source: .system)
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
