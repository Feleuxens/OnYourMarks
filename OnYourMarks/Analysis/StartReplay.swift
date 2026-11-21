//
//  StartReplay.swift
//  OnYourMarks
//

import CoreGraphics
import Foundation

/// Runs the app's own logic again on a recorded start, without hardware:
/// the decision on the session's events, tracker, stability and motion
/// monitor on the recorded poses, and the onset analysis on the recorded
/// samples. Each part says what the recording stores and what the replay
/// finds, so that a change to a constant can be judged against real starts.
///
/// Every function is pure and takes what it may change as arguments.
nonisolated enum StartReplay {
    // MARK: - Gun

    /// The gun of a recorded start, as the decision used it.
    struct Gun: Equatable, Sendable {
        /// When it was heard.
        let heard: TimeEstimate

        /// When its first sample was rendered, as scheduled.
        let renderStart: MonotonicTimestamp

        /// Whether a reaction may be held against an athlete: the gun was
        /// read back from the render timeline, and its output's delay is
        /// known (`DecisionEngine.qualify(_:gunTimeIsTrusted:movedBeforeRender:)`).
        let isTrusted: Bool
    }

    /// The gun that was heard, after every event. Nil if the start never
    /// got that far.
    static func gun(in session: StartSession) -> Gun? {
        var state = GunState()

        for event in session.events {
            state.take(event)
        }
        return state.gun
    }

    /// What the engine knew about the gun at one point of the session.
    private struct GunState {
        var scheduled: (heard: TimeEstimate, basis: SignalTimingBasis)?
        var fired: (heard: TimeEstimate, basis: SignalTimingBasis)?
        /// The fired gun's render start, from its scheduled heard time: a
        /// revision widens the heard time, but the engine keeps judging by
        /// the scheduled render start, and a revision for a changed latency
        /// would put it elsewhere.
        var renderStart: MonotonicTimestamp?
        var notMeasured = false

        var gun: Gun? {
            fired.map {
                Gun(
                    heard: $0.heard,
                    renderStart: renderStart ?? StartReplay.renderStart(of: $0.heard, basis: $0.basis),
                    isTrusted: !notMeasured && !$0.basis.isCalibrationMissing
                )
            }
        }

        mutating func take(_ event: StartEvent) {
            switch event.kind {
            case .gunScheduled(let basis):
                scheduled = (event.time, basis)
            case .gunCancelled:
                scheduled = nil
            case .gunCommitted:
                fire()
            case .stateChanged(.start) where fired == nil:
                fire()
            case .gunTimeRevised:
                fired = fired.map { (event.time, $0.basis) }
            case .gunPlaybackNotMeasured:
                notMeasured = true
            default:
                break
            }
        }

        private mutating func fire() {
            fired = scheduled
            renderStart = scheduled.map { StartReplay.renderStart(of: $0.heard, basis: $0.basis) }
        }
    }

    /// The render start a scheduled gun's heard time was derived from
    /// (`SignalTimingBasis.audibleOnset(renderStart:)` backwards).
    static func renderStart(of heard: TimeEstimate, basis: SignalTimingBasis) -> MonotonicTimestamp {
        MonotonicTimestamp(
            seconds: heard.best.seconds - basis.outputLatency - basis.onsetOffset - (basis.calibration?.correction ?? 0)
        )
    }

    // MARK: - Decision

    /// One thing the engine recorded about an athlete's result, without the
    /// event's identity, so that a replay can be compared with it.
    struct Fact: Equatable, Sendable {
        let kind: StartEventKind
        let time: TimeEstimate
        let athleteID: AthleteID?
    }

    struct DecisionReplay: Equatable, Sendable {
        /// What the session recorded about the reactions and decisions.
        let stored: [Fact]
        let replayed: [Fact]

        let storedResults: [AthleteStartResult]
        let replayedResults: [AthleteStartResult]

        var isReproduced: Bool {
            stored == replayed && storedResults == replayedResults
        }
    }

    /// The kinds of event the decision produces.
    private static func isDecisionFact(_ kind: StartEventKind) -> Bool {
        switch kind {
        case .reactionMeasured, .decision, .reactionRefined, .decisionRevised: true
        default: false
        }
    }

    /// Decides again on every movement and refinement the session recorded,
    /// with what the engine knew about the gun when each arrived.
    ///
    /// - Parameter profile: nil for the session's own.
    static func decisions(
        of recording: StartRecording,
        profile: StartProfile? = nil,
        engine: DecisionEngine = DecisionEngine()
    ) -> DecisionReplay {
        let session = recording.session
        let profile = profile ?? session.profile

        var gun = GunState()
        var facts: [Fact] = []
        var results: [AthleteStartResult] = []

        // Like the engine, by the gun that is scheduled: the one that fired.
        func judge(_ reaction: DurationEstimate, movement: TimeEstimate, quality: TrackingQuality?) -> StartDecision {
            engine.judge(
                reaction,
                movement: movement,
                quality: quality,
                profile: profile,
                gunTimeIsTrusted: !gun.notMeasured && gun.scheduled?.basis.isCalibrationMissing != true,
                renderStart: gun.scheduled.map { renderStart(of: $0.heard, basis: $0.basis) }
            )
        }

        for event in session.events {
            gun.take(event)

            switch event.kind {
            case .movementObserved(let quality):
                let position = event.athleteID.flatMap { session.roster?.position(of: $0) }

                guard let heard = gun.fired?.heard else {
                    let decision = engine.evaluateMovementBeforeGun(trackingQuality: quality)
                    results.append(
                        AthleteStartResult(
                            athleteID: event.athleteID, position: position, movement: event.time,
                            reaction: nil, decision: decision, trackingQuality: quality
                        )
                    )
                    facts.append(Fact(kind: .decision(decision), time: event.time, athleteID: event.athleteID))
                    continue
                }

                let reaction = event.time.duration(since: heard)
                let decision = judge(reaction, movement: event.time, quality: quality)

                facts.append(Fact(kind: .reactionMeasured(reaction), time: event.time, athleteID: event.athleteID))
                facts.append(Fact(kind: .decision(decision), time: event.time, athleteID: event.athleteID))
                results.append(
                    AthleteStartResult(
                        athleteID: event.athleteID, position: position, movement: event.time,
                        reaction: reaction, decision: decision, trackingQuality: quality
                    )
                )

            case .movementOnsetRefined(let refinement):
                // Recorded before the engine rejected a refinement that
                // began after the movement; the engine would not take it now.
                guard let index = results.firstIndex(where: { $0.athleteID == refinement.athleteID }),
                      !refinement.beganAfter(results[index].movement) else { continue }

                let live = results[index]

                guard let heard = gun.fired?.heard, live.reaction != nil else {
                    results[index] = AthleteStartResult(
                        athleteID: live.athleteID, position: live.position, movement: refinement.onset,
                        reaction: live.reaction, decision: live.decision, trackingQuality: live.trackingQuality,
                        isRefined: true
                    )
                    continue
                }

                let reaction = refinement.onset.duration(since: heard)
                let decision = judge(reaction, movement: refinement.onset, quality: live.trackingQuality)

                results[index] = AthleteStartResult(
                    athleteID: live.athleteID, position: live.position, movement: refinement.onset,
                    reaction: reaction, decision: decision, trackingQuality: live.trackingQuality,
                    isRefined: true
                )
                facts.append(Fact(kind: .reactionRefined(reaction), time: refinement.onset, athleteID: refinement.athleteID))

                if decision != live.decision {
                    facts.append(Fact(kind: .decisionRevised(decision), time: refinement.onset, athleteID: refinement.athleteID))
                }

            default:
                break
            }
        }

        return DecisionReplay(
            stored: session.events.filter { isDecisionFact($0.kind) }.map {
                Fact(kind: $0.kind, time: $0.time, athleteID: $0.athleteID)
            },
            replayed: facts,
            storedResults: recording.results,
            replayedResults: results
        )
    }

    // MARK: - Poses

    struct PoseReplay: Equatable, Sendable {
        struct Athlete: Equatable, Sendable {
            let id: AthleteID
            let position: Int

            /// The movement as the session recorded it and as the replay found it.
            let storedMovement: TimeEstimate?
            let replayedMovement: TimeEstimate?

            /// How well the athlete was tracked in the frame of the movement.
            let quality: TrackingQuality?

            /// When the athlete was called unsteady.
            let storedUnsteady: [MonotonicTimestamp]
            let replayedUnsteady: [MonotonicTimestamp]

            /// The last frame that began a still stretch before the movement
            /// (or before monitoring ended), and the frame that made the
            /// athlete stable in it. What a second pass starts from.
            let stillSince: MonotonicTimestamp?
            let stableSince: MonotonicTimestamp?

            /// The part of the picture that was sampled at that rest.
            let region: CGRect?
        }

        let athletes: [Athlete]

        /// Frames the monitor saw, and how many of them end with phases
        /// other than the recorded ones.
        let monitoredFrames: Int
        let phaseMismatches: Int

        /// Capture time of each frame after which the replayed monitor was
        /// ready, and when the session says the engine took the athletes as
        /// ready. The engine hears it later: the frame still has to go
        /// through pose detection and reach the main actor.
        let replayedReadiness: [MonotonicTimestamp]
        let storedReadiness: [MonotonicTimestamp]

        /// Athletes in the recorded frames after the tracker's warm-up, and
        /// how many of them the replayed tracker has in another state or
        /// not at all.
        let trackedAthletes: Int
        let trackerMismatches: Int
    }

    /// Runs tracker, stability and motion monitor again on the poses of the
    /// recorded frames.
    ///
    /// The monitor is fed the tracker's recorded output, so that it is
    /// judged on its own; the tracker is fed the recorded poses and compared
    /// with that output. What the engine told the detector between two
    /// frames is placed where the recording shows it happened: monitoring
    /// begins before the first frame with phases and ends after the last,
    /// and an athlete the engine made settle again after an unsteady report
    /// is moving in the first frame after it.
    ///
    /// - Parameter profile: nil for the session's own.
    static func poses(of start: RecordedStart, profile: MotionProfile? = nil) -> PoseReplay {
        let session = start.recording.session
        let frames = start.tracking.sorted { $0.time < $1.time }
        let profile = profile ?? session.profile.motion
        let roster = session.roster ?? .empty

        let storedUnsteady = session.events.filter {
            if case .athleteUnsteady = $0.kind { true } else { false }
        }
        let storedMovements = session.events.filter {
            if case .movementObserved = $0.kind { true } else { false }
        }
        let storedReadiness = session.events.filter { $0.kind == .athletesReady }.map { $0.time.best }

        let monitored = frames.indices.filter { !frames[$0].phases.isEmpty }
        let (trackedAthletes, trackerMismatches) = replayTracker(on: frames, roster: roster, monitored: monitored)

        guard !roster.isEmpty, let first = monitored.first, let last = monitored.last else {
            return PoseReplay(
                athletes: [], monitoredFrames: 0, phaseMismatches: 0, replayedReadiness: [],
                storedReadiness: storedReadiness, trackedAthletes: trackedAthletes, trackerMismatches: trackerMismatches
            )
        }

        // A handheld start stores the camera's offset with every frame it
        // could measure; a frame without one could not be judged.
        let isHandheld = frames.contains { $0.cameraOffset != nil }

        var monitor = AthleteMotionMonitor()
        _ = monitor.begin(with: rosterAthletes(roster, in: frames[first]), profile: profile)

        var movements: [AthleteID: MovementObservation] = [:]
        var unsteady: [AthleteID: [MonotonicTimestamp]] = [:]
        var pendingResettles: Set<AthleteID> = []
        var readiness: [MonotonicTimestamp] = []
        var phaseMismatches = 0
        var lastMoving: [AthleteID: MonotonicTimestamp] = [:]
        var stillSince: [AthleteID: MonotonicTimestamp] = [:]
        var stableSince: [AthleteID: MonotonicTimestamp] = [:]
        var regions: [AthleteID: CGRect] = [:]

        // A movement is reported once a second pose confirms it, which can
        // be after the last monitored frame: a start recorded when one pose
        // was enough ended its monitoring on the crossing.
        let confirmable = frames[last].time.seconds + AthleteMotionMonitor.confirmationWait
        let end = frames[last...].lastIndex { $0.time.seconds <= confirmable } ?? last

        for (index, frame) in zip(first...end, frames[first...end]) {
            for id in pendingResettles where frame.phases[id].map({ $0 != .stable }) == true {
                monitor.resettle(id)
                pendingResettles.remove(id)
            }

            let shift: CameraShift = isHandheld ? frame.cameraOffset.map(CameraShift.measured) ?? .unmeasured : .measured(.zero)
            let previous = monitor.phases

            for event in monitor.process(frame.athletes, camera: shift, at: frame.time) {
                switch event {
                case .movement(let observation):
                    if let id = observation.athleteID {
                        movements[id] = observation
                    }
                case .unsteady(let observation):
                    guard let id = observation.athleteID else { break }
                    unsteady[id, default: []].append(observation.time)

                    // The engine settles an athlete again only for an
                    // unsteadiness it took, which it recorded.
                    if storedUnsteady.contains(where: { $0.athleteID == id && $0.time.best == observation.time }) {
                        pendingResettles.insert(id)
                    }
                case .readinessChanged(true):
                    readiness.append(frame.time)
                default:
                    break
                }
            }

            if index <= last, monitor.phases != frame.phases {
                phaseMismatches += 1
            }

            for (id, phase) in monitor.phases where movements[id] == nil {
                switch phase {
                case .moving:
                    lastMoving[id] = frame.time
                case .stable where previous[id] != .stable:
                    stableSince[id] = frame.time
                    stillSince[id] = lastMoving[id]
                case .settling, .stable:
                    break
                }
            }

            // Where the athlete was sampled when the movement came, or at the end.
            for (id, region) in monitor.regions where movements[id] == nil || movements[id]?.time == frame.time {
                regions[id] = region
            }
        }

        let athletes = roster.entries.map { entry in
            let stored = storedMovements.first { $0.athleteID == entry.id }
            let movement = movements[entry.id]
            let quality: TrackingQuality? = if case .movementObserved(let quality) = stored?.kind { quality } else { nil }

            return PoseReplay.Athlete(
                id: entry.id,
                position: entry.position,
                storedMovement: stored?.time,
                replayedMovement: movement?.onset,
                quality: movement?.quality ?? quality,
                storedUnsteady: storedUnsteady.filter { $0.athleteID == entry.id }.map { $0.time.best },
                replayedUnsteady: unsteady[entry.id] ?? [],
                stillSince: stillSince[entry.id],
                stableSince: stableSince[entry.id],
                region: regions[entry.id]
            )
        }

        return PoseReplay(
            athletes: athletes,
            monitoredFrames: last - first + 1,
            phaseMismatches: phaseMismatches,
            replayedReadiness: readiness,
            storedReadiness: storedReadiness,
            trackedAthletes: trackedAthletes,
            trackerMismatches: trackerMismatches
        )
    }

    /// The roster's athletes as the monitor got them when monitoring
    /// began: in the state the roster recorded, with the pose of the first
    /// monitored frame. Only their identity and state matter to it.
    private static func rosterAthletes(_ roster: AthleteRoster, in frame: TrackingFrame) -> [TrackedAthlete] {
        roster.entries.map { entry in
            let seen = frame.athletes.first { $0.id == entry.id }

            return TrackedAthlete(
                id: entry.id,
                state: entry.quality.state,
                pose: seen?.pose ?? DetectedPose(joints: [:], confidence: 0),
                lastSeen: seen?.lastSeen ?? frame.time,
                isVisible: seen?.isVisible ?? false,
                quality: entry.quality
            )
        }
    }

    /// Feeds the poses of every recorded frame to a new tracker and counts
    /// the recorded athletes it doesn't have in the same state. Its tracks
    /// are new, so they are matched to the recorded ones by their poses.
    /// The recorded tracker had seen frames before the recording began; the
    /// first frames, until a new track can be confirmed, are not compared.
    private static func replayTracker(
        on frames: [TrackingFrame],
        roster: AthleteRoster,
        monitored: [Int]
    ) -> (compared: Int, mismatches: Int) {
        var tracker = AthleteTracker()
        var recordedID: [AthleteID: AthleteID] = [:]
        var compared = 0
        var mismatches = 0
        let monitoring = monitored.first.flatMap { first in monitored.last.map { first...$0 } }

        for (index, frame) in frames.enumerated() {
            let isMonitored = monitoring?.contains(index) == true
            tracker.retained = isMonitored ? Set(recordedID.filter { roster.contains($0.value) }.keys) : []

            let athletes = tracker.update(with: frame.athletes.filter { $0.isVisible }.map { $0.pose }, at: frame.time)

            for athlete in athletes where athlete.isVisible && recordedID[athlete.id] == nil {
                recordedID[athlete.id] = frame.athletes.first { $0.isVisible && $0.pose == athlete.pose }?.id
            }

            guard index >= AthleteTracker.confirmationFrames else { continue }

            for recorded in frame.athletes {
                compared += 1

                let replayed = athletes.first { recordedID[$0.id] == recorded.id }
                if replayed?.state != recorded.state || replayed?.isVisible != recorded.isVisible {
                    mismatches += 1
                }
            }
        }
        return (compared, mismatches)
    }

    // MARK: - Onsets

    struct OnsetReplay: Equatable, Sendable {
        let athleteID: AthleteID
        let position: Int?

        /// The frame in which pose detection confirmed the movement.
        let confirmation: MonotonicTimestamp?

        let stored: OnsetRefinement?
        let replayed: MotionOnsetAnalyzer.Onset?

        let sampleCount: Int
    }

    /// Looks up again, in the recorded samples, where each confirmed
    /// movement began. The samples are what the live analysis had; frames
    /// after the confirmation are left out by the analysis itself.
    static func onsets(
        of start: RecordedStart,
        parameters: MotionOnsetAnalyzer.Parameters = .live
    ) -> [OnsetReplay] {
        let session = start.recording.session

        return start.motion.map { record in
            let movement = session.events.first {
                guard $0.athleteID == record.athleteID, case .movementObserved = $0.kind else { return false }
                return true
            }
            let stored = session.events.firstNonNil { event -> OnsetRefinement? in
                guard case .movementOnsetRefined(let refinement) = event.kind, refinement.athleteID == record.athleteID else {
                    return nil
                }
                return refinement
            }
            // The live observation's interval ends with the frame that confirmed it.
            let confirmation = movement?.time.latest

            return OnsetReplay(
                athleteID: record.athleteID,
                position: session.roster?.position(of: record.athleteID),
                confirmation: confirmation,
                stored: stored,
                replayed: confirmation.flatMap {
                    MotionOnsetAnalyzer.onset(in: record.samples, confirmedAt: $0, parameters: parameters)
                },
                sampleCount: record.samples.count
            )
        }
    }

    // MARK: - Report

    /// One line of a replay's table.
    struct Row: Equatable, Sendable {
        let quantity: String
        let stored: String
        let replayed: String
        let difference: String
    }

    struct Configuration: Sendable {
        var onset = MotionOnsetAnalyzer.Parameters.live
        /// Nil for the session's own.
        var profile: StartProfile?
    }

    /// The table of everything the replay compares, for one recording.
    /// Times are given from the gun, or from the first frame without one.
    static func report(for start: RecordedStart, configuration: Configuration = Configuration()) -> [Row] {
        let recording = start.recording
        let origin = gun(in: recording.session)?.heard.best ?? recording.frameTimes.first ?? MonotonicTimestamp(seconds: 0)
        let format = TimeFormat(origin: origin)

        var rows: [Row] = []

        // The decision.
        let decisions = decisions(of: recording, profile: configuration.profile)
        rows.append(
            Row(
                quantity: "decision events",
                stored: "\(decisions.stored.count)",
                replayed: "\(decisions.replayed.count)",
                difference: decisions.stored == decisions.replayed ? "same" : "differ"
            )
        )
        for (stored, replayed) in zip(recording.results, decisions.replayedResults) {
            let name = "athlete \(stored.position.map(String.init) ?? "?")"
            rows.append(
                Row(
                    quantity: "\(name) reaction",
                    stored: format.duration(stored.reaction),
                    replayed: format.duration(replayed.reaction),
                    difference: format.difference(stored.reaction?.best, replayed.reaction?.best)
                )
            )
            rows.append(
                Row(
                    quantity: "\(name) decision",
                    stored: "\(stored.decision)",
                    replayed: "\(replayed.decision)",
                    difference: stored.decision == replayed.decision ? "same" : "differ"
                )
            )
        }

        // Tracker, stability, monitor.
        let poses = poses(of: start, profile: configuration.profile?.motion)
        rows.append(
            Row(
                quantity: "tracker: athletes in other states",
                stored: "\(poses.trackedAthletes) athletes",
                replayed: "\(poses.trackerMismatches)",
                difference: poses.trackerMismatches == 0 ? "same" : "\(poses.trackerMismatches) differ"
            )
        )
        rows.append(
            Row(
                quantity: "monitor: frames with other phases",
                stored: "\(poses.monitoredFrames) frames",
                replayed: "\(poses.phaseMismatches)",
                difference: poses.phaseMismatches == 0 ? "same" : "\(poses.phaseMismatches) differ"
            )
        )
        rows.append(
            Row(
                quantity: "ready (frame → engine)",
                stored: poses.storedReadiness.map(format.time).joined(separator: ", "),
                replayed: poses.replayedReadiness.map(format.time).joined(separator: ", "),
                difference: zip(poses.storedReadiness, poses.replayedReadiness)
                    .map { format.difference($0.seconds, $1.seconds) }
                    .joined(separator: ", ")
            )
        )
        for athlete in poses.athletes {
            let name = "athlete \(athlete.position)"
            rows.append(
                Row(
                    quantity: "\(name) unsteady",
                    stored: athlete.storedUnsteady.map(format.time).joined(separator: ", "),
                    replayed: athlete.replayedUnsteady.map(format.time).joined(separator: ", "),
                    difference: athlete.storedUnsteady == athlete.replayedUnsteady ? "same" : "differ"
                )
            )
            rows.append(
                Row(
                    quantity: "\(name) movement (poses)",
                    stored: format.interval(athlete.storedMovement),
                    replayed: format.interval(athlete.replayedMovement),
                    difference: athlete.storedMovement == athlete.replayedMovement
                        ? "same" : format.difference(athlete.storedMovement?.latest.seconds, athlete.replayedMovement?.latest.seconds)
                )
            )
            if let record = start.motion.first(where: { $0.athleteID == athlete.id }) {
                rows.append(
                    Row(
                        quantity: "\(name) sampled region",
                        stored: format.region(record.region),
                        replayed: athlete.region.map(format.region) ?? "none",
                        difference: athlete.region == record.region ? "same" : "differ"
                    )
                )
            }
        }

        // The onset analysis.
        for onset in onsets(of: start, parameters: configuration.onset) {
            let name = "athlete \(onset.position.map(String.init) ?? "?")"
            rows.append(
                Row(
                    quantity: "\(name) onset (pixels, \(onset.sampleCount) samples)",
                    stored: format.interval(onset.stored?.onset),
                    replayed: format.interval(onset.replayed?.interval),
                    difference: onset.stored?.onset == onset.replayed?.interval
                        ? "same" : format.difference(onset.stored?.onset.best.seconds, onset.replayed?.interval.best.seconds)
                )
            )
        }

        // What a person saw, if anyone looked.
        if let truth = start.truth {
            for athlete in truth.athletes {
                let seen = truth.movement(of: athlete, frameTimes: recording.frameTimes)
                let live = recording.results.first { $0.position == athlete.position }?.movement
                let second = start.analysis?.athletes.first { $0.position == athlete.position }?.movement

                rows.append(
                    Row(
                        quantity: "athlete \(athlete.position) movement seen in frame \(athlete.firstMovingFrame)",
                        stored: "live " + format.interval(live),
                        replayed: "second pass " + format.interval(second),
                        difference: "seen " + format.interval(seen)
                    )
                )
            }
        }

        return rows
    }

    /// The rows as a table that reads in a monospaced font.
    static func table(_ rows: [Row], title: String) -> String {
        let header = Row(quantity: "", stored: "stored", replayed: "replayed", difference: "difference")
        let all = [header] + rows
        let widths = [
            all.map { $0.quantity.count }.max() ?? 0,
            all.map { $0.stored.count }.max() ?? 0,
            all.map { $0.replayed.count }.max() ?? 0,
        ]

        func pad(_ text: String, _ width: Int) -> String {
            text + String(repeating: " ", count: max(0, width - text.count))
        }

        let lines = all.map {
            "\(pad($0.quantity, widths[0]))  \(pad($0.stored, widths[1]))  \(pad($0.replayed, widths[2]))  \($0.difference)"
        }
        return ([title] + lines).joined(separator: "\n")
    }

    /// Times in milliseconds from an origin, finer than a frame at 240 fps.
    private struct TimeFormat {
        let origin: MonotonicTimestamp

        func time(_ time: MonotonicTimestamp) -> String {
            milliseconds(time.seconds - origin.seconds)
        }

        func interval(_ estimate: TimeEstimate?) -> String {
            guard let estimate else { return "none" }
            return "\(time(estimate.earliest)) … \(time(estimate.latest))"
        }

        func duration(_ estimate: DurationEstimate?) -> String {
            guard let estimate else { return "none" }
            return "\(milliseconds(estimate.best)) (\(milliseconds(estimate.earliest)) … \(milliseconds(estimate.latest)))"
        }

        func difference(_ stored: TimeInterval?, _ replayed: TimeInterval?) -> String {
            guard let stored, let replayed else { return stored == nil && replayed == nil ? "same" : "one missing" }
            return milliseconds(replayed - stored)
        }

        func region(_ rect: CGRect) -> String {
            String(format: "x %.3f y %.3f w %.3f h %.3f", rect.minX, rect.minY, rect.width, rect.height)
        }

        private func milliseconds(_ seconds: TimeInterval) -> String {
            String(format: "%+.1f ms", seconds * 1000)
        }
    }
}
