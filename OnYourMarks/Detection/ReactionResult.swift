//
//  ReactionResult.swift
//  OnYourMarks
//
//  Created by Felix on 17.07.26.
//

import Foundation

struct ReactionResult {
    let delta: TimeInterval
    var isFalseStart: Bool { delta < 0.100 }
    var reactionTime: TimeInterval? { isFalseStart ? nil : delta }
}
