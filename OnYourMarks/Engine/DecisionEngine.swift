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
}


