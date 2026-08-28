//
//  StartSession.swift
//  OnYourMarks
//
//  Created by Felix on 26.08.26.
//

import Foundation

nonisolated struct AthleteID: Hashable, Codable, Sendable {
    let rawValue: UUID
    
    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

nonisolated enum MeasurementSource: Equatable, Hashable, Sendable {
    case system
    case cameraLocal
    case audioLocal
    case manual
    
    case remoteCamera(UUID)
    case remoteSignal(UUID)
    
    case externalSensor(String)
}

nonisolated enum StartSessionOutcome: Equatable, Sendable {
    case completed
    case aborted
    case falseStart
    case failed(String)
}

nonisolated enum StartEventKind: Equatable, Sendable {
    case sessionStarted
    
    case stateChanged(StarterState)
    
    case monitoringStarted
    case monitoringStopped
    
    /// Current meaning: App asked local audio system to play the gun
    /// Upcoming: replace with schedule for precise timing
    case gunPlaybackRequest
    
    case movementObserved
    
    case reactionMeasured(DurationEstimate)
    
    case decision(StartDecision)
    
    case sessionEnded(StartSessionOutcome)
}

nonisolated struct StartEvent: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: StartEventKind
    let time: TimeEstimate
    let source: MeasurementSource
    let athleteID: AthleteID?
    
    init(
        id: UUID = UUID(),
        kind: StartEventKind,
        time: TimeEstimate,
        source: MeasurementSource,
        athleteID: AthleteID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.time = time
        self.source = source
        self.athleteID = athleteID
    }
}

nonisolated struct StartSession: Identifiable, Equatable, Sendable {
    let id: UUID
    
    let startType: StartType
    let profile: StartProfile
    
    let createdAt: MonotonicTimestamp
    
    private(set) var events: [StartEvent]
    private(set) var outcome: StartSessionOutcome?
    
    init(
        id: UUID = UUID(),
        startType: StartType,
        profile: StartProfile,
        createdAt: MonotonicTimestamp
    ) {
        self.id = id
        self.startType = startType
        self.profile = profile
        self.createdAt = createdAt
        
        self.events = [
            StartEvent(kind: .sessionStarted, time: .exact(createdAt), source: .system)
        ]
        
        self.outcome = nil
    }
    
    mutating func record(
        _ kind: StartEventKind,
        at time: TimeEstimate,
        source: MeasurementSource,
        athleteID: AthleteID? = nil
    ) {
        events.append(
            StartEvent(
                kind: kind,
                time: time,
                source: source,
                athleteID: athleteID
            )
        )
    }
    
    mutating func finish(
        _ outcome: StartSessionOutcome,
        at time: TimeEstimate
    ) {
        guard self.outcome == nil else {
            return
        }
        
        self.outcome = outcome
        
        record(.sessionEnded(outcome), at: time, source: .system)
    }
}
