//
//  Helper.swift
//  OnYourMarks
//
//  Created by Felix on 23.08.26.
//
import Foundation
@testable import OnYourMarks

@MainActor
final class FakeSignalPlayer: SignalPlayer {
    var played: [Signal] = []
    var stopCount = 0
    var recallCount = 0
    
    var failingSignal: Signal?
    
    func play(_ signal: Signal) -> Bool {
        if signal == failingSignal {
            return false
        }
        
        played.append(signal)
        return true
    }
    
    func stop() {
        stopCount += 1
    }
    
    func playRecall(times: Int, gap: TimeInterval) async {
        for _ in 0..<times {
            guard !Task.isCancelled else { return }
            
            recallCount += 1
            _ = play(.go)
        }
    }
    
    func duration(of signal: Signal) -> TimeInterval {
        0
    }
}

final class FakeMovementDetector: MovementDetector {
    var onMovement: ((TimeInterval) -> Void)?
    
    private(set) var startCount = 0
    private(set) var stopCount = 0
    
    func startMonitoring() {
        startCount += 1
    }
    
    func stopMonitoring() {
        stopCount += 1
    }
    
    func emitMovement(at time: TimeInterval) {
        onMovement?(time)
    }
}
