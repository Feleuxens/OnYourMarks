//
//  AthleteMotionMonitor.swift
//  OnYourMarks
//

import CoreGraphics
import Foundation

/// Watches every athlete on the roster: whether they hold still, and their
/// first movement once they do.
nonisolated struct AthleteMotionMonitor: Sendable {
    private(set) var roster: AthleteRoster?
    private var stability: [AthleteID: AthleteStability] = [:]
    private var trackStates: [AthleteID: AthleteTrackState] = [:]
    private var wasReady = false

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

        for member in members {
            stability[member.id] = AthleteStability(profile: profile)
            trackStates[member.id] = member.state
        }

        wasReady = isReady
        return roster
    }

    mutating func end() {
        roster = nil
        stability = [:]
        trackStates = [:]
        wasReady = false
    }

    /// Makes an athlete, or with nil everyone, become still again before
    /// they count as ready.
    mutating func resettle(_ athlete: AthleteID?) {
        for id in stability.keys where athlete == nil || athlete == id {
            stability[id]?.resettle()
        }
        wasReady = isReady
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
        var events: [DetectorEvent] = []
        guard roster != nil else { return events }

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

            let event = stability[athlete.id]?.process(joints, aspectRatio: athlete.pose.aspectRatio, at: time)
            let observation = MovementObservation(
                time: time,
                onset: stability[athlete.id]?.onset,
                athleteID: athlete.id,
                quality: athlete.quality
            )

            switch event {
            case .started:
                events.append(.movement(observation))
            case .unsteady:
                events.append(.unsteady(observation))
            case .becameStable, nil:
                break
            }
        }

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
