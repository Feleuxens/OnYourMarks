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
    
    /// Records the start for the review, if there is one to record with.
    private let recorder: StartRecorder?
    private var recordsVideo = false
    private var isRecording = false
    
    /// Whether a false start is recalled. If not, it is only recorded.
    private var recallsFalseStarts = true
    
    /// How long after the gun a recording goes on, at the precision rate.
    private var recordingAfterStart: TimeInterval = 0
    
    /// Ends the precision window once a recording has followed the athletes
    /// for that long. The run is over by then.
    private var followThrough: Task<Void, Never>?
    
    private let clock: MonotonicClock
    private let decisionEngine: DecisionEngine
    
    private var sequenceTask: Task<Void, Never>?
    
    /// When the gun is heard, set once it can no longer be taken back.
    /// Before that, any movement is a false start.
    private var gunTime: TimeEstimate?
    private var scheduledGun: ScheduledSignal?
    
    /// Set when the gun could not be found on the render timeline: nothing
    /// says it was heard when it was scheduled.
    private var gunWasNotMeasured = false
    
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
    
    /// The least time between the athletes becoming still again and the
    /// gun, after the gun was taken back. Whoever has just moved needs a
    /// moment to be set again, however short the configured hold is: a gun
    /// right on top of the movement draws a false start. Reasoned, not
    /// measured: the shortest hold a starter would give.
    var minimumHoldAfterDisturbance: TimeInterval = 1
    
    /// How long after the gun the athletes are watched for their start.
    /// The gun's sound is over long before a slow one: the first standing
    /// start recorded on the device reached the pose threshold 0.52 s after
    /// the gun. Whoever hasn't moved by now is not starting. Reasoned.
    var reactionWindow: TimeInterval = 1.5
    
    /// The sleep the sequence is in while it waits for the athletes or for
    /// the gun; cancelled to wake it early.
    private var wakeableSleep: Task<Void, Never>?
    
    /// A wake-up that found the sequence between two sleeps. It ends the
    /// next wakeable sleep at once instead of being lost.
    private var wakeRequested = false
    /// Whether the last wakeable sleep was ended by a wake-up.
    private var wasWokenEarly = false
    
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
        movementDetector: MovementDetector,
        recorder: StartRecorder? = nil
    ) {
        self.init(
            player: player,
            movementDetector: movementDetector,
            recorder: recorder,
            clock: SystemMonotonicClock(),
            decisionEngine: DecisionEngine()
        )
    }
    
    init(
        player: SignalPlayer,
        movementDetector: MovementDetector,
        recorder: StartRecorder? = nil,
        clock: MonotonicClock,
        decisionEngine: DecisionEngine
    ) {
        self.player = player
        self.movementDetector = movementDetector
        self.recorder = recorder
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
        gunWasNotMeasured = false
        roster = nil
        athleteResults = []
        firstFalseStart = nil
        holdWasDisturbed = false
        wakeRequested = false
        wasWokenEarly = false
        monitoringActive = false
        
        // The start before this one may still be followed by its recording.
        followThrough?.cancel()
        followThrough = nil
        endPrecisionWindow()
        
        recallsFalseStarts = config.recallsFalseStarts
        recordsVideo = config.recordsVideo
        recordingAfterStart = config.recordingAfterStart
        isRecording = false
        
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
        
        // The athletes of a completed start are filmed on, as finely as before.
        let recordingEnd = outcome == .completed ? recordingContinuesUntil : nil
        
        player.stop()
        stopMovementMonitoring()
        
        if let recordingEnd {
            followThrough = Task { [weak self] in
                await self?.clock.sleep(until: recordingEnd)
                
                guard !Task.isCancelled else { return }
                self?.endPrecisionWindow()
            }
        } else {
            endPrecisionWindow()
        }
        
        gunTime = nil
        scheduledGun = nil
        setState(.idle)
        isRunning = false
        
        let wasRecording = isRecording
        if wasRecording {
            isRecording = false
            record(.recordingEnded, source: .system)
        }
        
        finalizeSession(outcome: outcome)
        
        if wasRecording, let lastSession {
            recorder?.endRecording(
                session: lastSession,
                results: athleteResults,
                tail: recordingEnd.map { max(0, $0.seconds - clock.now().seconds) } ?? 0
            )
        }
        
        onRunEnded?()
    }
    
    /// Until when the recording of this start goes on. Nil before the gun
    /// and without a recording.
    private var recordingContinuesUntil: MonotonicTimestamp? {
        guard isRecording, let gunTime else { return nil }
        
        return MonotonicTimestamp(seconds: gunTime.best.seconds + recordingAfterStart)
    }
    
    private func handle(_ event: DetectorEvent) {
        commitGunIfDue()
        
        switch event {
        case .movement(let observation):
            handleMovement(observation)
            
        case .onsetRefined(let refinement):
            handleRefinement(refinement)
            
        case .unsteady(let observation):
            handleUnsteady(observation)
            
        case .trackingChanged(let change):
            handleTrackingChange(change)
            
        case .readinessChanged(let ready):
            // An athlete who stopped being ready without being reported
            // unsteady, e.g. one who came back into view still moving,
            // takes a pending gun back all the same.
            if !ready {
                disturbHold()
            }
            
            // Wakes the wait for readiness; it looks at the detector itself.
            wakeSequence()
            
        case .athletesTracked(let frame):
            // Also after the run: the recorder may still be showing how
            // the start went on.
            recorder?.record(frame)
            
        case .motionSampled(let motion):
            recorder?.record(motion)
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
        
        // An interval that ends with the frame that made the movement
        // certain. Judging by its late end keeps the live decision
        // conservative: a false start is only called if even that is too early.
        let movementTime = observation.onset
        
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
                AthleteStartResult(
                    athleteID: athleteID,
                    position: position,
                    movement: movementTime,
                    reaction: nil,
                    decision: decision,
                    trackingQuality: observation.quality
                )
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
        
        let decision = decide(reaction, movement: movementTime, quality: observation.quality, profile: profile)
        
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
            AthleteStartResult(
                athleteID: athleteID,
                position: position,
                movement: movementTime,
                reaction: reaction,
                decision: decision,
                trackingQuality: observation.quality
            )
        )
    }
    
    /// Takes in a closer look at when an athlete's movement began. It can
    /// turn a result into a false start or clear it, but it never recalls:
    /// by now the athletes are running, and this app is for training, where
    /// a wrong recall is worse than a missed one.
    private func handleRefinement(_ refinement: OnsetRefinement) {
        guard isRunning,
              let index = athleteResults.firstIndex(where: { $0.athleteID == refinement.athleteID }),
              !athleteResults[index].isRefined else {
            return
        }
        
        let live = athleteResults[index]
        
        record(
            .movementOnsetRefined(refinement),
            at: refinement.onset,
            source: movementDetector.source,
            athleteID: refinement.athleteID
        )
        
        // Before the gun the decision doesn't hang on the exact moment.
        guard let gunTime, live.reaction != nil, let profile = currentSession?.profile else {
            athleteResults[index] = AthleteStartResult(
                athleteID: live.athleteID,
                position: live.position,
                movement: refinement.onset,
                reaction: live.reaction,
                decision: live.decision,
                trackingQuality: live.trackingQuality,
                isRefined: true
            )
            return
        }
        
        let reaction = refinement.onset.duration(since: gunTime)
        let decision = decide(reaction, movement: refinement.onset, quality: live.trackingQuality, profile: profile)
        
        athleteResults[index] = AthleteStartResult(
            athleteID: live.athleteID,
            position: live.position,
            movement: refinement.onset,
            reaction: reaction,
            decision: decision,
            trackingQuality: live.trackingQuality,
            isRefined: true
        )
        
        record(
            .reactionRefined(reaction),
            at: refinement.onset,
            source: movementDetector.source,
            athleteID: refinement.athleteID
        )
        
        logger.info(
            """
            Refined reaction\(Self.description(position: live.position), privacy: .public) \
            \(reaction.best * 1000, format: .fixed(precision: 1)) ms \
            (\(reaction.earliest * 1000, format: .fixed(precision: 1)) to \
            \(reaction.latest * 1000, format: .fixed(precision: 1)) ms, \
            \(refinement.droppedFrames) frames dropped): \
            \(String(describing: decision), privacy: .public)
            """
        )
        
        if decision != live.decision {
            record(
                .decisionRevised(decision),
                at: refinement.onset,
                source: .system,
                athleteID: refinement.athleteID
            )
        }
    }
    
    /// Judges a reaction as far as the tracking and the gun's time carry it.
    private func decide(
        _ reaction: DurationEstimate,
        movement: TimeEstimate,
        quality: TrackingQuality?,
        profile: StartProfile
    ) -> StartDecision {
        let decision = decisionEngine.qualify(
            decisionEngine.evaluateReaction(reaction, profile: profile),
            by: quality
        )
        
        return decisionEngine.qualify(
            decision,
            gunTimeIsTrusted: gunTimeIsTrusted,
            movedBeforeRender: scheduledGun.map { movement.latest < $0.renderStart } ?? false
        )
    }
    
    /// Whether the gun's time is known well enough to hold a reaction
    /// against an athlete: not on a wireless output whose delay was never
    /// measured, and not when the gun could not be read back.
    private var gunTimeIsTrusted: Bool {
        !gunWasNotMeasured && scheduledGun?.basis.isCalibrationMissing != true
    }
    
    /// Counts the gun as fired once it can no longer be taken back, even if
    /// the sequence hasn't got there yet: the audio clock starts the gun by
    /// itself, and a detector event can reach the engine before the
    /// sequence's task runs again. Judged by `gunTime == nil`, that event
    /// would be a movement before the gun, or take back a gun that sounds.
    private func commitGunIfDue() {
        guard gunTime == nil, let gun = scheduledGun, clock.now() >= gun.cancellableUntil else { return }
        
        gunTime = gun.audibleOnset
        record(.gunCommitted, at: gun.audibleOnset, source: .audioLocal)
    }
    
    /// Stores one athlete's result and acts on it: a false start recalls the
    /// field, anything else lets the others go on being watched.
    private func conclude(_ result: AthleteStartResult) {
        let time = result.movement
        athleteResults.append(result)
        
        if result.decision == .definiteFalseStart, firstFalseStart == nil {
            firstFalseStart = time.latest
        }
        
        record(
            .decision(result.decision),
            at: time,
            source: .system,
            athleteID: result.athleteID
        )
        
        switch result.decision {
        case .definiteFalseStart where recallsFalseStarts:
            triggerFalseStart()
            
        case .definiteFalseStart,
                .uncertain,
                .legal,
                .notApplicable:
            if result.decision == .definiteFalseStart {
                // Measured and shown, but the start goes on like any other.
                record(.recallSkipped, source: .system, athleteID: result.athleteID)
            }
            
            guard everyAthleteHasMoved(after: result) else { return }
            
            stopMovementMonitoring()
            
            // A recording keeps the precision rate, for the gun that may
            // still come and for the first steps.
            if !isRecording {
                endPrecisionWindow()
            }
            
            // Nobody is left to wait for after the gun.
            wakeSequence()
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
        
        // A gun that was still pending is taken back by that.
        if gunTime == nil {
            scheduledGun = nil
        }
        
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
                commitGunIfDue()
                
                // Read back early: the estimate extrapolates over the time
                // since the start, so any clock drift grows with it.
                let duration = player.duration(of: .go)
                let measureAfter = min(Self.gunMeasurementDelay, duration)
                
                guard await sleep(for: measureAfter) else { return .cancelled }
                recordMeasuredGun()
                guard await sleep(for: duration - measureAfter) else { return .cancelled }
                guard await waitForReactions() else { return .cancelled }
                
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
    
    /// Keeps the run going after the gun's sound until every athlete on the
    /// roster has moved or the reaction window is over. Without a roster
    /// there is no one to wait for. False if the run was cancelled.
    private func waitForReactions() async -> Bool {
        guard let gunTime, roster?.entries.isEmpty == false else { return true }
        
        let end = MonotonicTimestamp(seconds: gunTime.best.seconds + reactionWindow)
        
        // The last athlete's movement ends the monitoring and wakes this.
        while monitoringActive, clock.now() < end {
            guard await sleep(until: end, wakeable: true) else { return false }
        }
        return true
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
            let hold = restarts == 0 ? duration : max(duration, minimumHoldAfterDisturbance)
            let requested = MonotonicTimestamp(seconds: clock.now().seconds + hold)
            
            guard let gun = player.schedule(.go, at: requested) else {
                return .failed(String(localized: "The start signal could not be played."))
            }
            
            scheduledGun = gun
            record(.gunScheduled(gun.basis), at: gun.audibleOnset, source: .audioLocal)
            
            // Off the timing path: the gun no longer depends on this task.
            player.logTimingDiagnostics(label: "Gun scheduled")
            
            while clock.now() < gun.renderStart {
                guard await wait(until: gun.renderStart, gunIn: 0, wakeable: true) else { return .cancelled }
                
                guard holdWasDisturbed else { continue }
                
                if clock.now() < gun.cancellableUntil {
                    break
                }
                
                // Too late to take it back without a sound: the gun fires.
                holdWasDisturbed = false
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
        
        disturbHold()
    }
    
    /// Takes a pending gun back: the hold begins again once everyone is still.
    private func disturbHold() {
        guard state == .waitForStart, gunTime == nil, scheduledGun != nil else { return }
        
        holdWasDisturbed = true
        wakeSequence()
    }
    
    /// Ends the wakeable sleep the sequence is in, or the next one it begins.
    private func wakeSequence() {
        wakeRequested = true
        wakeableSleep?.cancel()
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
            logger.notice("Wireless output without calibration: reactions after the gun stay uncertain")
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
            
            // Woken early: the caller looks at what changed first.
            guard !(wakeable && wasWokenEarly) else { return true }
            
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
        if wakeable, wakeRequested {
            wakeRequested = false
            wasWokenEarly = true
            return !Task.isCancelled
        }
        
        let sleeper = Task { [clock] in await clock.sleep(until: time) }
        
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
            wasWokenEarly = wakeRequested
            wakeRequested = false
        }
        
        return !Task.isCancelled
    }
    
    /// Records when the gun was actually heard, as read back from the render timeline.
    private func recordMeasuredGun() {
        guard let scheduled = scheduledGun else { return }
        
        guard let measured = player.measuredPlayback(of: .go) else {
            logger.error("Gun playback could not be measured")
            gunWasNotMeasured = true
            record(.gunPlaybackNotMeasured, source: .audioLocal)
            return
        }
        
        record(.gunPlaybackMeasured, at: measured.audibleOnset, source: .audioLocal)
        
        let deviation = measured.renderStart.seconds - scheduled.renderStart.seconds
        
        if abs(deviation) > OutputTiming.maximumScheduleDeviation {
            logger.error("Gun started \(deviation * 1000, format: .fixed(precision: 3)) ms off its schedule")
            
            // Most likely as measured, but wide enough for the schedule too,
            // so a reaction that depends on which is right stays uncertain.
            let revised = TimeEstimate(
                best: measured.audibleOnset.best,
                earliest: min(scheduled.audibleOnset.earliest, measured.audibleOnset.earliest),
                latest: max(scheduled.audibleOnset.latest, measured.audibleOnset.latest)
            )
            
            gunTime = revised
            record(.gunTimeRevised, at: revised, source: .audioLocal)
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
        
        // From the hold on: a false start can happen from here.
        if recordsVideo, recorder?.beginRecording() == true {
            isRecording = true
            record(.recordingBegan, source: .system)
        }
        
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
