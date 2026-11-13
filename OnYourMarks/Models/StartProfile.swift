//
//  StartProfile.swift
//  OnYourMarks
//
//  Created by Felix on 26.08.26.
//

import Foundation


/// This class sets parameters for the decision engine.
nonisolated struct StartProfile: Equatable, Codable, Sendable {
    let startType: StartType
    
    let usesSetCommand: Bool
    
    /// A reaction that is certainly faster than this is a false start. Nil
    /// for a start that isn't judged by its reaction.
    let automaticReactionThreshold: TimeInterval?
    
    /// How stillness and the first movement are judged.
    let motion: MotionProfile
    
    /// Nobody reacts to the gun faster than this from the blocks.
    static let block = StartProfile(
        startType: .block,
        usesSetCommand: true,
        automaticReactionThreshold: 0.100,
        motion: .block
    )
    
    /// A standing start begins gradually, and its rule is only that nobody
    /// moves before the gun. So it is false when the movement was certain
    /// before the gun, and a slow beginning that reaches across the gun is
    /// uncertain. In the first recorded standing starts the picture changed
    /// for 60 ms before the movement was certain.
    static let standing = StartProfile(
        startType: .standing,
        usesSetCommand: false,
        automaticReactionThreshold: 0,
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
