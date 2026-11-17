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
    
    /// What the camera the detector watches through did: frames stopping
    /// or arriving again, the precision rate, the held exposure. Also
    /// outside of monitoring.
    case camera(CameraReport)

    /// A movement one frame showed was not confirmed by a second piece of
    /// evidence, so it was never reported as a `movement`.
    case movementUnconfirmed(UnconfirmedMovement)

    /// A probed region of the picture changed from one frame to the next.
    /// Reported for every such step while probing.
    case probeChanged(ProbeObservation)
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
    /// precisely as possible. Begins with the hold, so the detector is at
    /// full speed, and its camera steady, before the gun is armed. Both
    /// calls are safe to repeat.
    func beginPrecisionWindow()
    func endPrecisionWindow()
    
    /// The camera the detector watches through. `.off` for a detector
    /// without one: a start does not wait for it.
    var cameraCondition: CameraCondition { get }
    
    /// How the camera is set up, for the record of a start. Nil without one.
    var cameraSetup: CameraSetup? { get }
    
    /// What the open precision window has delivered so far. Nil outside
    /// the window or without a camera.
    func precisionDelivery() -> PrecisionRateDelivery?

    /// Watches regions of the picture for a step instead of athletes, for
    /// measuring the app's own timing (probe mode), until `stopMonitoring()`.
    /// Nobody is judged meanwhile. A detector without a picture reports nothing.
    func startProbing(_ regions: [ProbeRegion])
}
