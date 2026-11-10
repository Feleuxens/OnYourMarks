//
//  AthleteMotionMonitor.swift
//  OnYourMarks
//

import Foundation

/// Watches every athlete on the roster for their first movement.
nonisolated struct AthleteMotionMonitor: Sendable {
    struct Update: Equatable, Sendable {
        var movements: [MovementObservation] = []
        var trackingChanges: [AthleteTrackingChange] = []
    }

    private(set) var roster: AthleteRoster?
    private var motion: [AthleteID: MotionState] = [:]
    private var trackStates: [AthleteID: AthleteTrackState] = [:]

    /// Fixes the roster: every athlete that is tracked now, visible or not.
    /// Tentative and lost tracks are left out; nothing says an athlete is there.
    ///
    /// The athletes arrive ordered from left to right; that order numbers them.
    mutating func begin(with athletes: [TrackedAthlete]) -> AthleteRoster {
        let members = athletes.filter { $0.state == .tracked || $0.state == .occluded }

        let roster = AthleteRoster(
            entries: members.enumerated().map {
                AthleteRoster.Entry(id: $0.element.id, position: $0.offset + 1, quality: $0.element.quality)
            }
        )

        self.roster = roster
        motion = [:]
        trackStates = [:]

        for member in members {
            var state = MotionState()
            state.reset(monitoring: true)
            motion[member.id] = state
            trackStates[member.id] = member.state
        }
        return roster
    }

    mutating func end() {
        roster = nil
        motion = [:]
        trackStates = [:]
    }

    /// Takes the athletes of one frame. Each athlete's movement is reported once.
    mutating func process(_ athletes: [TrackedAthlete], at time: MonotonicTimestamp) -> Update {
        var update = Update()

        for athlete in athletes {
            guard let previousState = trackStates[athlete.id] else { continue }

            if athlete.state != previousState {
                trackStates[athlete.id] = athlete.state
                update.trackingChanges.append(
                    AthleteTrackingChange(athleteID: athlete.id, state: athlete.state, time: time)
                )
            }

            // An unseen athlete still has the old pose; it says nothing new.
            guard athlete.isVisible, motion[athlete.id]?.process(athlete.pose.joints) == true else { continue }

            update.movements.append(
                MovementObservation(time: time, athleteID: athlete.id, quality: athlete.quality)
            )
        }
        return update
    }
}
