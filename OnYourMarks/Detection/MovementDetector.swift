//
//  MovementDetector.swift
//  OnYourMarks
//
//  Created by Felix on 17.07.26.
//

import Foundation

protocol MovementDetector: AnyObject {
    /// Called once per monitoring for each athlete that moves.
    var onMovement: ((MovementObservation) -> Void)? { get set }
    
    /// Called while monitoring when an athlete on the roster is hidden, lost
    /// or found again.
    var onTrackingChange: ((AthleteTrackingChange) -> Void)? { get set }
    
    /// Begins watching the athletes in view and returns them as the roster
    /// of this start. Empty if the detector sees no one or can't tell
    /// athletes apart.
    @discardableResult
    func startMonitoring() -> AthleteRoster
    func stopMonitoring()
    
    /// The stretch around the gun in which a movement has to be timed as
    /// precisely as possible. Begins before the gun, so the detector is at
    /// full speed when it fires. Both calls are safe to repeat.
    func beginPrecisionWindow()
    func endPrecisionWindow()
}
