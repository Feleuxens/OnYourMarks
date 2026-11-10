//
//  MovementDetector.swift
//  OnYourMarks
//
//  Created by Felix on 17.07.26.
//

import Foundation

protocol MovementDetector: AnyObject {
    var onMovement: ((TimeInterval) -> Void)? { get set }
    func startMonitoring()
    func stopMonitoring()
    
    /// The stretch around the gun in which a movement has to be timed as
    /// precisely as possible. Begins before the gun, so the detector is at
    /// full speed when it fires. Both calls are safe to repeat.
    func beginPrecisionWindow()
    func endPrecisionWindow()
}
