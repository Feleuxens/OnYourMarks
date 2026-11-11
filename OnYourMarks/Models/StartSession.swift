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

nonisolated enum MeasurementSource: Equatable, Hashable, Codable, Sendable {
    case system
    case cameraLocal
    case audioLocal
    case manual
    
    case remoteCamera(UUID)
    case remoteSignal(UUID)
    
    case externalSensor(String)
}

nonisolated enum StartSessionOutcome: Equatable, Codable, Sendable {
    case completed
    case aborted
    case falseStart
    case failed(String)
}

nonisolated enum StartEventKind: Equatable, Codable, Sendable {
    case sessionStarted
    
    case stateChanged(StarterState)
    
    case monitoringStarted
    case monitoringStopped
    
    /// The movement detector switched to full speed ahead of the gun.
    case precisionWindowBegan
    case precisionWindowEnded
    
    /// The camera's frames are being written to the start's video, from
    /// the first frame captured after this.
    case recordingBegan
    case recordingEnded
    
    /// The silent check before the first command passed.
    case audioPrepared(AudioPreflight)
    
    /// The gun was placed on the audio clock; the event time is when it will
    /// be heard, derived from the attached output, latency and calibration.
    case gunScheduled(SignalTimingBasis)
    
    /// Read back from the audio render timeline after the gun started;
    /// the event time is when it was heard.
    case gunPlaybackMeasured
    
    /// The athletes found when monitoring began; only they are judged.
    case rosterEstablished(AthleteRoster)
    
    /// An athlete on the roster was hidden, lost or found again.
    case athleteTrackingChanged(AthleteTrackState)
    
    /// With how well the athlete was tracked in the frame that showed it,
    /// if the detector knows.
    case movementObserved(TrackingQuality?)
    
    /// Every athlete the detector can judge holds still; the gun is armed next.
    case athletesReady
    
    /// An athlete left the resting pose without starting. Not a fault.
    case athleteUnsteady(TrackingQuality?)
    
    /// The pending gun was taken back because an athlete was unsteady.
    case gunCancelled
    
    case reactionMeasured(DurationEstimate)
    
    /// The beginning of a movement was looked up frame by frame; the event
    /// time is the refined beginning.
    case movementOnsetRefined(OnsetRefinement)
    
    /// The reaction that follows from the refined beginning.
    case reactionRefined(DurationEstimate)
    
    /// The refined reaction is judged differently from the live one. Too
    /// late for a recall: the athletes are running.
    case decisionRevised(StartDecision)
    
    case decision(StartDecision)
    
    case sessionEnded(StartSessionOutcome)
}

nonisolated struct StartEvent: Identifiable, Equatable, Codable, Sendable {
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

nonisolated struct StartSession: Identifiable, Equatable, Codable, Sendable {
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
