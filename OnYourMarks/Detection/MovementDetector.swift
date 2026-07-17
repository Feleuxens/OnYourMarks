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
}
