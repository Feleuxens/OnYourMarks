//
//  AthleteMotionMonitor.swift
//  OnYourMarks
//

import CoreGraphics
import Foundation

/// Watches every athlete on the roster: whether they hold still, and their
/// first movement once they do.
///
/// A movement takes two pieces of evidence: the pose that crossed the
/// threshold and the athlete's next judged pose agreeing with it. Before the
/// gun a movement recalls the start, and shortly after it one too fast does,
/// so a single wrong pose from pose detection must not be able to. The
/// movement is still timed from the first pose; only its report waits.
nonisolated struct AthleteMotionMonitor: Sendable {
    /// How long a crossing pose waits for the athlete's next judged pose.
    /// Normally that is the next analysed frame: about 11 ms at the
    /// precision rate (88 poses a second measured at 120 fps), 67 ms at the
    /// idle rate. The bound only matters when poses are missing: one frame
    /// at the idle rate under serious pressure (5 fps, 0.2 s) still counts,
    /// and at 15 fps two missed poses do. A crossing that waits longer is
    /// given up, not confirmed: a recall that comes a frame late is
    /// harmless, one that comes from a single wrong pose is not. Reasoned.
    static let confirmationWait: TimeInterval = 0.25

    private(set) var roster: AthleteRoster?
    private var stability: [AthleteID: AthleteStability] = [:]
    private var trackStates: [AthleteID: AthleteTrackState] = [:]
    private var wasReady = false

    /// Crossings waiting for a second pose, by athlete.
    private var candidates: [AthleteID: MovementObservation] = [:]
    /// Given up outside of a frame; reported with the next one.
    private var droppedCandidates: [DetectorEvent] = []

    /// Where each roster athlete stands between moving and stable.
    var phases: [AthleteID: AthleteStability.Phase] {
        stability.mapValues { $0.phase }
    }

    /// The part of the picture each stable athlete takes up at rest, for
    /// watching it frame by frame. An athlete who has to settle again has none.
    var regions: [AthleteID: CGRect] {
        stability.compactMapValues { $0.restingPose.flatMap(MotionSampler.region(around:)) }
    }

    /// Whether every athlete that can be seen holds still. A hidden athlete
    /// can't be judged and doesn't hold up the start; neither does an empty
    /// roster.
    ///
    /// Hidden is what the tracker calls occluded or lost, not one frame
    /// without a pose: pose detection misses a moving athlete now and then,
    /// and each miss would arm the gun for a frame.
    var isReady: Bool {
        guard roster != nil else { return false }

        return stability.allSatisfy { $0.value.phase == .stable || trackStates[$0.key] != .tracked }
    }

    /// Fixes the roster: every athlete that is tracked now, visible or not.
    /// Tentative and lost tracks are left out; nothing says an athlete is there.
    ///
    /// The athletes arrive ordered from left to right; that order numbers them.
    mutating func begin(with athletes: [TrackedAthlete], profile: MotionProfile) -> AthleteRoster {
        let members = athletes.filter { $0.state == .tracked || $0.state == .occluded }

        let roster = AthleteRoster(
            entries: members.enumerated().map {
                AthleteRoster.Entry(id: $0.element.id, position: $0.offset + 1, quality: $0.element.quality)
            }
        )

        self.roster = roster
        stability = [:]
        trackStates = [:]
        candidates = [:]
        droppedCandidates = []

        for member in members {
            stability[member.id] = AthleteStability(profile: profile)
            trackStates[member.id] = member.state
        }

        wasReady = isReady
        return roster
    }

    /// Ends the monitoring. Returns the crossings that were still waiting
    /// for a second pose, given up.
    @discardableResult
    mutating func end() -> [DetectorEvent] {
        let unconfirmed = droppedCandidates + giveUp(candidates.keys, because: .monitoringEnded)

        roster = nil
        stability = [:]
        trackStates = [:]
        candidates = [:]
        droppedCandidates = []
        wasReady = false
        return unconfirmed
    }

    /// Makes an athlete, or with nil everyone, become still again before
    /// they count as ready.
    mutating func resettle(_ athlete: AthleteID?) {
        droppedCandidates += giveUp(candidates.keys.filter { athlete == nil || athlete == $0 }, because: .resettled)

        for id in stability.keys where athlete == nil || athlete == id {
            stability[id]?.resettle()
        }
        wasReady = isReady
    }

    /// What an athlete's next judged pose says about a crossing.
    enum Confirmation: Equatable, Sendable {
        case confirmed
        /// The pose is back under the threshold: the crossing stood alone.
        case contradicted
        /// The pose came after `confirmationWait`, e.g. after a stall. It
        /// says nothing about the crossing's frame any more, and confirming
        /// it would time the movement from that frame.
        case expired
    }

    /// The two-pose rule, for the live monitor and the second pass alike.
    /// A crossing that isn't confirmed is withdrawn from `stability`; the
    /// pose then counts like any other.
    static func confirm(
        crossingAt crossing: MonotonicTimestamp,
        by joints: AthleteStability.Joints,
        aspectRatio: CGFloat,
        at time: MonotonicTimestamp,
        stability: inout AthleteStability
    ) -> Confirmation {
        let confirmation: Confirmation = if time.seconds - crossing.seconds > confirmationWait {
            .expired
        } else if let movement = stability.movement(of: joints, aspectRatio: aspectRatio),
                  movement > stability.profile.movementThreshold {
            .confirmed
        } else {
            .contradicted
        }

        if confirmation != .confirmed {
            stability.withdrawStart()
        }
        return confirmation
    }

    /// Withdraws the athletes' crossings and reports them, oldest first.
    private mutating func giveUp(
        _ athletes: some Sequence<AthleteID>,
        because reason: UnconfirmedMovement.Reason
    ) -> [DetectorEvent] {
        let given = athletes
            .compactMap { id in candidates.removeValue(forKey: id).map { (id, $0) } }
            .sorted { $0.1.time < $1.1.time }

        return given.map { id, candidate in
            stability[id]?.withdrawStart()
            return .movementUnconfirmed(UnconfirmedMovement(candidate, athleteID: id, reason: reason))
        }
    }

    /// Takes the athletes of one frame and returns what happened in it.
    ///
    /// - Parameter camera: what the camera's own movement did to the frame.
    ///   A measured shift is taken out of every joint, so the athletes are
    ///   judged as if the camera stood still. Without one nobody is judged
    ///   in this frame, and once the camera is lost everyone has to become
    ///   still again: what moved in the picture may have been the camera.
    mutating func process(
        _ athletes: [TrackedAthlete],
        camera: CameraShift = .measured(.zero),
        at time: MonotonicTimestamp
    ) -> [DetectorEvent] {
        guard roster != nil else { return [] }

        var events = droppedCandidates
        droppedCandidates = []

        for athlete in athletes {
            guard let previousState = trackStates[athlete.id] else { continue }

            if athlete.state != previousState {
                trackStates[athlete.id] = athlete.state
                events.append(
                    .trackingChanged(AthleteTrackingChange(athleteID: athlete.id, state: athlete.state, time: time))
                )
            }

            // An unseen athlete still has the old pose; it says nothing new.
            guard athlete.isVisible, let cameraOffset = camera.offset else { continue }

            let joints = athlete.pose.joints.mapValues {
                CGPoint(x: $0.x - cameraOffset.x, y: $0.y - cameraOffset.y)
            }

            if let candidate = candidates.removeValue(forKey: athlete.id), var athleteStability = stability[athlete.id] {
                let confirmation = Self.confirm(
                    crossingAt: candidate.time,
                    by: joints,
                    aspectRatio: athlete.pose.aspectRatio,
                    at: time,
                    stability: &athleteStability
                )
                stability[athlete.id] = athleteStability

                switch confirmation {
                case .confirmed:
                    events.append(.movement(candidate.confirmed(at: time, quality: athlete.quality)))
                    continue

                // This frame is judged like any other.
                case .contradicted:
                    events.append(.movementUnconfirmed(UnconfirmedMovement(candidate, athleteID: athlete.id, reason: .contradicted)))
                case .expired:
                    events.append(.movementUnconfirmed(UnconfirmedMovement(candidate, athleteID: athlete.id, reason: .notSeenAgain)))
                }
            }

            let event = stability[athlete.id]?.process(joints, aspectRatio: athlete.pose.aspectRatio, at: time)
            let observation = MovementObservation(
                time: time,
                onset: stability[athlete.id]?.onset,
                athleteID: athlete.id,
                quality: athlete.quality
            )

            switch event {
            case .started:
                candidates[athlete.id] = observation
            case .unsteady:
                events.append(.unsteady(observation))
            case .becameStable, nil:
                break
            }
        }

        let overdue = candidates.filter { time.seconds - $0.value.time.seconds > Self.confirmationWait }.keys
        events += giveUp(camera == .lost ? Array(candidates.keys) : Array(overdue), because: .notSeenAgain)

        if camera == .lost {
            for id in stability.keys {
                stability[id]?.resettle()
            }
        }

        if isReady != wasReady {
            wasReady = isReady
            events.append(.readinessChanged(wasReady))
        }
        return events
    }
}
