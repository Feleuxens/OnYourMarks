//
//  DecisionEngine.swift
//  OnYourMarks
//
//  Created by Felix on 26.08.26.
//

import Foundation

nonisolated enum StartDecision: Equatable, Sendable {
    /// The entire reaction interval is below the allowed threshold
    case definiteFalseStart
    
    /// The measurement overlaps the threshold
    case uncertain
    
    /// The entire interval is legal
    case legal
    
    /// This start profile does not make this decision
    /// from reaction time alone.
    case notApplicable
}

nonisolated struct DecisionEngine: Sendable {
    /// Nobody reacts faster than this to what they see or hear. A movement
    /// this soon after another athlete's false start was not caused by it,
    /// so it is a false start of its own.
    static let independentMovementWindow: TimeInterval = 0.100
    
    /// Whether a movement before the gun, after another athlete has already
    /// false-started, is a false start too. A later one may be a reaction to
    /// the first athlete or to the recall and is not held against anyone.
    func isIndependentFalseStart(
        at movement: MonotonicTimestamp,
        afterFalseStartAt first: MonotonicTimestamp
    ) -> Bool {
        movement.seconds - first.seconds <= Self.independentMovementWindow
    }
    
    func evaluateReaction(
        _ reaction: DurationEstimate,
        profile: StartProfile
    ) -> StartDecision {
        guard let threshold = profile.automaticReactionThreshold else {
            return .notApplicable
        }
        
        // A false start is only automatic when the latest plausible reaction is still too fast
        if reaction.latest < threshold {
            return .definiteFalseStart
        }
        
        if reaction.earliest >= threshold {
            return .legal
        }
        
        return .uncertain
    }
    
    /// Any movement between the hold and the gun is a false start.
    func evaluateMovementBeforeGun(
        trackingQuality: TrackingQuality?
    ) -> StartDecision {
        qualify(.definiteFalseStart, by: trackingQuality)
    }
    
    /// A false start is only automatic when the athlete was tracked well
    /// enough to be sure the movement was theirs. A poorly tracked one,
    /// e.g. just found again after being hidden, leaves it uncertain.
    func qualify(
        _ decision: StartDecision,
        by trackingQuality: TrackingQuality?
    ) -> StartDecision {
        guard decision == .definiteFalseStart, trackingQuality?.level == .poor else {
            return decision
        }
        
        return .uncertain
    }
}


