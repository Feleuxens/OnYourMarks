//
//  MovementDetector.swift
//  OnYourMarks
//
//  Created by Felix on 17.07.26.
//

import Foundation

/// What a detector reports while it monitors. One type for everything, so
/// the events of a detector can be recorded, replayed or sent from another
/// device as they are.
nonisolated enum DetectorEvent: Equatable, Sendable {
    /// An athlete started. Once per monitoring for each athlete.
    case movement(MovementObservation)
    
    /// An athlete that was holding still left the resting pose without
    /// starting: swaying, shifting, coming up slowly.
    case unsteady(MovementObservation)
    
    /// The beginning of a reported movement, found more precisely.
    case onsetRefined(OnsetRefinement)
    
    /// An athlete on the roster was hidden, lost or found again.
    case trackingChanged(AthleteTrackingChange)
    
    /// The detector's `isReady` changed.
    case readinessChanged(Bool)
    
    /// What the detector saw of an athlete frame by frame while it
    /// monitored. Reported when monitoring ends; a recording keeps it.
    case motionSampled(MotionRecord)
    
    /// The athletes as one analysed frame showed them. Reported for every
    /// analysed frame, also outside of monitoring; a recording keeps them.
    case athletesTracked(TrackingFrame)
}

protocol MovementDetector: AnyObject {
    var onEvent: ((DetectorEvent) -> Void)? { get set }
    
    /// Where this detector's measurements come from.
    var source: MeasurementSource { get }
    
    /// Whether every athlete the detector can judge is holding still. A
    /// detector that sees no one is ready: there is nothing to wait for.
    var isReady: Bool { get }
    
    /// Begins watching the athletes in view and returns them as the roster
    /// of this start. Empty if the detector sees no one or can't tell
    /// athletes apart.
    ///
    /// A movement is only reported for an athlete who has held still first;
    /// getting into position is not a movement.
    @discardableResult
    func startMonitoring(profile: MotionProfile) -> AthleteRoster
    
    /// Makes an athlete, or with nil everyone, become still again before
    /// they count as ready and are watched for a movement.
    func resettle(_ athlete: AthleteID?)
    func stopMonitoring()
    
    /// The stretch around the gun in which a movement has to be timed as
    /// precisely as possible. Begins before the gun, so the detector is at
    /// full speed when it fires. Both calls are safe to repeat.
    func beginPrecisionWindow()
    func endPrecisionWindow()
}
