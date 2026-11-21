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
    
    /// Where reading the committed gun back from the render timeline
    /// stands. Nil until the gun is committed.
    private var gunReadBack: GunReadBack?
    private var gunReadBackTask: Task<Void, Never>?

    /// Movements that began once the gun was rendered and arrived before
    /// the read-back said when it was heard. They are judged against the
    /// time it gives, or as untrusted if it found nothing: a movement can
    /// arrive within the read-back's 50 ms, and judged before it, a recall
    /// would rest on a gun nothing has confirmed.
    private var heldMovements: [MovementObservation] = []
    /// Refinements of held movements; the detector sends one right after
    /// its movement. Taken in once the movement is judged.
    private var heldRefinements: [OnsetRefinement] = []

    private enum GunReadBack {
        case pending
        case measured
        /// Nothing says the gun was heard when it was scheduled.
        case failed
    }

    /// Listens for the committed gun with the microphone, if the player
    /// can. An observation only: what it finds goes into the session, not
    /// into a decision.
    private var gunHearing: Task<Void, Never>?

    /// Long enough for the first render cycles to have passed, and early:
    /// the read-back extrapolates over the time since the start, so any
    /// clock drift grows with it. Reasoned.
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
    
    /// Capture time of the last frame before the camera failed after the
    /// gun. Movements seen in later frames are not judged: the frames in
    /// between are missing, and with them where the athlete was.
    private var cameraFailedAfter: MonotonicTimestamp?
    
    /// How long a camera that was just switched on gets to deliver its
    /// first frame before the start is given up. Reasoned, not measured:
    /// starting a session takes a fraction of that.
    static let cameraStartupTimeout: TimeInterval = 2
    
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
        resetGunReadBack()
        gunHearing?.cancel()
        gunHearing = nil
        roster = nil
        athleteResults = []
        firstFalseStart = nil
        holdWasDisturbed = false
        wakeRequested = false
        wasWokenEarly = false
        monitoringActive = false
        cameraFailedAfter = nil
        
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
        
        // What the run had of the precision rate, before the window ends.
        if precisionWindowActive, let delivery = movementDetector.precisionDelivery() {
            record(.camera(.delivered(delivery)), source: movementDetector.source)
            
            if !delivery.isReached {
                logger.notice(
                    """
                    The camera delivered \(delivery.deliveredFrameRate ?? 0, format: .fixed(precision: 1)) of \
                    \(delivery.requestedFrameRate, format: .fixed(precision: 0)) fps
                    """
                )
            }
        }
        
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
        // A completed or recalled run has read the gun back; an aborted one
        // drops the movements still held for it.
        resetGunReadBack()
        // A completed run waited for it; any other run ends without it.
        gunHearing?.cancel()
        gunHearing = nil
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
        
        case .camera(let report):
            handleCamera(report)

        case .movementUnconfirmed(let movement):
            handleUnconfirmed(movement)
        }
    }
    
    /// Records what the camera did and acts on a failure: before the gun
    /// can no longer be taken back, the start is given up; after that it
    /// goes on, but nothing seen once the frames came back is judged.
    private func handleCamera(_ report: CameraReport) {
        guard isRunning else { return }
        
        record(.camera(report), source: movementDetector.source)
        
        if case .failed(let fault, let lastFrame) = report {
            if gunTime == nil, state != .falseStart {
                failForCamera(fault)
                return
            }
            
            if gunTime != nil, cameraFailedAfter == nil {
                cameraFailedAfter = lastFrame ?? clock.now()
                logger.error("The camera failed after the gun: \(String(describing: fault), privacy: .public)")
            }
        }
        
        // The hold may be waiting for a steady camera.
        wakeSequence()
    }
    
    private func failForCamera(_ fault: CameraFault) {
        logger.error("The camera failed before the gun: \(String(describing: fault), privacy: .public)")
        
        player.stop()
        
        if scheduledGun != nil {
            scheduledGun = nil
            record(.gunCancelled, source: .system)
        }
        
        let message = String(localized: "The camera stopped during the start, so the start was cancelled.")
        onError?(message)
        abort(reason: message)
    }
    
    /// Whether the camera lets the gun be armed: off, or steady in the
    /// precision window.
    private var cameraIsSteady: Bool {
        switch movementDetector.cameraCondition {
        case .off: true
        case .delivering(let isSteady): isSteady
        case .starting, .failed: false
        }
    }

    /// A movement nothing backed is not judged, only kept for the review.
    private func handleUnconfirmed(_ movement: UnconfirmedMovement) {
        guard roster?.contains(movement.athleteID) == true else { return }

        record(
            .movementUnconfirmed(movement),
            at: movement.onset,
            source: movementDetector.source,
            athleteID: movement.athleteID
        )

        logger.info(
            """
            Unconfirmed movement\(Self.description(position: self.roster?.position(of: movement.athleteID)), privacy: .public) \
            given up: \(String(describing: movement.reason), privacy: .public)
            """
        )
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
        
        // Seen or confirmed once the camera came back: no result rather
        // than one that spans the frames that are missing. Confirmation is
        // never before the crossing, so it decides for both frames.
        if let cameraFailedAfter, observation.confirmedAt > cameraFailedAfter {
            logger.notice("Movement after the camera failed: not judged")
            return
        }
        
        // Only athletes on the roster are judged, and each only once. A
        // report can still arrive from a frame analysed before monitoring ended.
        if let athleteID {
            guard roster?.contains(athleteID) == true,
                  !athleteResults.contains(where: { $0.athleteID == athleteID }),
                  !heldMovements.contains(where: { $0.athleteID == athleteID }) else {
                return
            }
        }
        
        // Only a movement over before the gun was rendered needs no time
        // for it, and is judged at once.
        if gunTime != nil, gunReadBack == .pending, let gun = scheduledGun, observation.onset.latest >= gun.renderStart {
            heldMovements.append(observation)
            return
        }
        
        judge(observation, profile: profile)
    }
    
    /// Records a movement and decides on it against the gun's time.
    private func judge(_ observation: MovementObservation, profile: StartProfile) {
        let athleteID = observation.athleteID
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

        // A detector that confirms on the frame itself has nothing to add.
        if observation.confirmedAt != observation.time {
            record(.movementConfirmed, at: .exact(observation.confirmedAt), source: movementDetector.source, athleteID: athleteID)
        }

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
        if isRunning, heldMovements.contains(where: { $0.athleteID == refinement.athleteID }) {
            heldRefinements.append(refinement)
            return
        }
        
        guard isRunning,
              let index = athleteResults.firstIndex(where: { $0.athleteID == refinement.athleteID }),
              !athleteResults[index].isRefined,
              !refinement.beganAfter(athleteResults[index].movement),
              cameraFailedAfter.map({ refinement.onset.latest <= $0 }) ?? true else {
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
        decisionEngine.judge(
            reaction,
            movement: movement,
            quality: quality,
            profile: profile,
            gunTimeIsTrusted: gunTimeIsTrusted,
            renderStart: scheduledGun?.renderStart
        )
    }
    
    /// Whether the gun's time is known well enough to hold a reaction
    /// against an athlete: not on a wireless output whose delay was never
    /// measured, and not when the gun could not be read back.
    private var gunTimeIsTrusted: Bool {
        gunReadBack != .failed && scheduledGun?.basis.isCalibrationMissing != true
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

        readBack(gun)
        listen(for: gun)
    }

    /// Reads the gun back once it has been rendered for a moment, on its
    /// own task: a recall cancels the sequence, but not the read-back the
    /// held movements wait for. Counted from the render start, not from the
    /// commit: the cancellation lead (two I/O buffers and 5 ms, 47.7 ms at
    /// the 21.3 ms measured) can be longer than the delay, and before its
    /// first rendered sample the player has nothing to read back.
    private func readBack(_ gun: ScheduledSignal) {
        let at = MonotonicTimestamp(seconds: gun.renderStart.seconds + min(Self.gunMeasurementDelay, player.duration(of: gun.signal)))
        gunReadBack = .pending

        gunReadBackTask = Task { [weak self] in
            guard let self, await self.sleep(until: at), self.gunReadBack == .pending else { return }

            self.recordMeasuredGun()
            self.judgeHeldMovements()
        }
    }

    private func judgeHeldMovements() {
        let held = heldMovements
        heldMovements = []

        guard let profile = currentSession?.profile else { return }

        for observation in held {
            judge(observation, profile: profile)
        }

        let refinements = heldRefinements
        heldRefinements = []

        for refinement in refinements {
            handleRefinement(refinement)
        }
    }

    private func resetGunReadBack() {
        gunReadBackTask?.cancel()
        gunReadBackTask = nil
        gunReadBack = nil
        heldMovements = []
        heldRefinements = []
    }

    /// Has the microphone check what the model says about the gun. Its
    /// result is recorded and shown in the review; the live decision stays
    /// with the model, which the reactions are measured against.
    private func listen(for gun: ScheduledSignal) {
        let session = currentSession?.id

        gunHearing = Task { [weak self, player] in
            let hearing = await player.hear(gun)

            guard let self, !Task.isCancelled, self.currentSession?.id == session else { return }
            self.recordHearing(hearing)
        }
    }

    private func recordHearing(_ hearing: SignalHearing) {
        switch hearing {
        case .notListening:
            break

        case .heard(let heard):
            record(.gunHeard(heard), at: heard.heard, source: .audioLocal)

            if let delay = heard.heardAfterModel {
                logger.info(
                    """
                    Gun heard \(delay.best * 1000, format: .fixed(precision: 2)) ms after the model \
                    (\(delay.earliest * 1000, format: .fixed(precision: 2)) to \
                    \(delay.latest * 1000, format: .fixed(precision: 2)) ms): \
                    \(String(describing: heard.check), privacy: .public)
                    """
                )
            }

        case .notHeard(let reason):
            record(.gunNotHeard(reason), source: .audioLocal)
            logger.notice("The microphone did not hear the gun: \(String(describing: reason), privacy: .public)")
        }
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
        
        // Read back before the stop ends the gun's playback. The movements
        // held for it are judged once the recall is under way, so that one
        // of them can't start a second recall.
        let readsBackNow = gunReadBack == .pending
        if readsBackNow {
            gunReadBackTask?.cancel()
            recordMeasuredGun()
        }
        
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
        
        if readsBackNow {
            judgeHeldMovements()
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
                
                guard !Task.isCancelled, await sleep(until: ready) else {
                    return .cancelled
                }
                
                // After the wait: a camera switched on just before gets it.
                if let outcome = await prepareCamera() {
                    return outcome
                }
            
            case .waitForStart:
                // From the beginning of the hold: the rate has time to
                // arrive, or to be repaired, before the gun is armed, and
                // the onset analysis gets the whole hold as rest.
                beginPrecisionWindow()
                startMovementMonitoring(profile: config.startType.profile.motion)
                
                if let outcome = await runHold(duration: phase.duration ?? 0) {
                    return outcome
                }
                
            case .start:
                // Already playing from the schedule.
                commitGunIfDue()
                
                guard await sleep(for: player.duration(of: .go)) else { return .cancelled }
                
                // The reaction window runs from the gun's final time.
                await gunReadBackTask?.value
                guard !Task.isCancelled, await waitForReactions() else { return .cancelled }

                // Usually over by now; the player bounds how long it takes.
                await gunHearing?.value
                
            default:
                if let signal = phase.signal {
                    guard player.play(signal) else {
                        return .failed(String(localized: "The start signal could not be played."))
                    }
                    
                }
                
                let end = MonotonicTimestamp(seconds: clock.now().seconds + plannedDuration(of: phase))
                guard await sleep(until: end) else { return .cancelled }
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
    
    /// Waits until the athletes hold still and the camera is steady, then
    /// puts the gun on the audio clock and waits for it. An unsteady athlete
    /// takes the gun back and the hold begins again. Nil once the gun is playing.
    private func runHold(duration: TimeInterval) async -> SequenceOutcome? {
        var restarts = 0
        
        while true {
            let readyBy = MonotonicTimestamp(seconds: clock.now().seconds + readinessTimeout)
            
            while !movementDetector.isReady || !cameraIsSteady {
                guard clock.now() < readyBy else {
                    guard cameraIsSteady else {
                        logger.notice("The camera did not get steady in time")
                        return .failed(String(localized: "The camera did not get ready in time, so the start was cancelled."))
                    }
                    
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
                guard await sleep(until: gun.renderStart, wakeable: true) else { return .cancelled }
                
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
    
    /// With detection on, a start only begins once frames arrive: a camera
    /// that was just switched on gets `cameraStartupTimeout` for its first
    /// one. Nil when the sequence may go on; a detector without a camera
    /// lets it go on as before.
    private func prepareCamera() async -> SequenceOutcome? {
        let deadline = MonotonicTimestamp(seconds: clock.now().seconds + Self.cameraStartupTimeout)
    
        while true {
            switch movementDetector.cameraCondition {
            case .off:
                return nil
        
            case .delivering:
                if let setup = movementDetector.cameraSetup {
                    record(.camera(.prepared(setup)), source: movementDetector.source)
                }
                return nil
            
            case .failed(let fault):
                logger.error("No frames before the start: \(String(describing: fault), privacy: .public)")
                return .failed(String(localized: "The camera isn't delivering any pictures, so the start was cancelled."))
            
            case .starting:
                guard clock.now() < deadline else {
                    logger.error("No frame within \(Self.cameraStartupTimeout, format: .fixed(precision: 1)) s of the start")
                    return .failed(String(localized: "The camera isn't delivering any pictures, so the start was cancelled."))
                }
                
                guard await sleep(until: deadline, wakeable: true) else { return .cancelled }
            }
        }
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
            gunReadBack = .failed
            record(.gunPlaybackNotMeasured, source: .audioLocal)
            return
        }
        
        gunReadBack = .measured
        record(.gunPlaybackMeasured, at: measured.audibleOnset, source: .audioLocal)
        
        let deviation = measured.renderStart.seconds - scheduled.renderStart.seconds
        
        // The read-back takes the output latency as it is now: a render on
        // schedule can still be heard off the scheduled time.
        let onsetDeviation = measured.audibleOnset.best.seconds - scheduled.audibleOnset.best.seconds
        
        if max(abs(deviation), abs(onsetDeviation)) > OutputTiming.maximumScheduleDeviation {
            logger.error(
                """
                Gun started \(deviation * 1000, format: .fixed(precision: 3)) ms and is heard \
                \(onsetDeviation * 1000, format: .fixed(precision: 3)) ms off its schedule
                """
            )
            
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
