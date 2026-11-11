//
//  StartProfile.swift
//  OnYourMarks
//
//  Created by Felix on 26.08.26.
//

import Foundation


/// This class sets parameters for the decision engine.
nonisolated struct StartProfile: Equatable, Sendable {
    let startType: StartType
    
    let usesSetCommand: Bool
    
    let automaticReactionThreshold: TimeInterval?
    
    /// How stillness and the first movement are judged.
    let motion: MotionProfile
    
    static let block = StartProfile(
        startType: .block,
        usesSetCommand: true,
        automaticReactionThreshold: 0.100,
        motion: .block
    )
    
    static let standing = StartProfile(
        startType: .standing,
        usesSetCommand: false,
        automaticReactionThreshold: nil,
        motion: .standing
    )
}

extension StartType {
    var profile: StartProfile {
        switch self {
        case .block: return .block
        case .standing: return .standing
        }
    }
}
