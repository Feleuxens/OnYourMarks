//
//  StarterState.swift
//  OnYourMarks
//
//  Created by Felix on 12.06.26.
//

nonisolated enum StarterState: Equatable, Sendable {
    case idle
    case preparing // before the on your marks command
    case onYourMarks
    case waitForSet
    case set
    case waitForStart
    case start
    case falseStart
}

