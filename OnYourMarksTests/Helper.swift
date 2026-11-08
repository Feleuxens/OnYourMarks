//
//  Helper.swift
//  OnYourMarks
//
//  Created by Felix on 23.08.26.
//
import Foundation
import Testing
@testable import OnYourMarks

@MainActor
class FakeSignalPlayer: SignalPlayer {
    var played: [Signal] = []
    /// Label of each diagnostics call, with how many signals had played by then.
    var diagnostics: [(label: String, playedCount: Int)] = []
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
    
    func logTimingDiagnostics(label: String) {
        diagnostics.append((label, played.count))
    }
}

struct FakeActivationError: LocalizedError {
    var errorDescription: String? { "Activation refused" }
}

/// Session player whose activation can be held open to test the "activating" window.
@MainActor
final class FakeSessionPlayer: FakeSignalPlayer, AudioSessionPlayer {
    var theme: SoundTheme = .eng1
    var onUnexpectedStop: ((String) -> Void)?
    
    private(set) var activateCount = 0
    private(set) var deactivateCount = 0
    private(set) var isSessionActive = false
    
    /// While true, activateSession() waits until releaseActivation() is called.
    var holdsActivation = false
    var activationError: Error?
    
    private var pendingActivations: [CheckedContinuation<Void, Never>] = []
    
    var isActivationPending: Bool {
        !pendingActivations.isEmpty
    }
    
    func activateSession() async throws {
        activateCount += 1
        
        if holdsActivation {
            await withCheckedContinuation { pendingActivations.append($0) }
        }
        
        if let activationError {
            throw activationError
        }
        
        isSessionActive = true
    }
    
    func deactivateSession() async {
        guard isSessionActive else { return }
        
        deactivateCount += 1
        isSessionActive = false
    }
    
    func releaseActivation() {
        let pending = pendingActivations
        pendingActivations.removeAll()
        
        for continuation in pending {
            continuation.resume()
        }
    }
    
    /// Simulates the system taking audio away (route change, call, reset).
    func failUnexpectedly(_ reason: String) {
        onUnexpectedStop?(reason)
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

/// Yields until the condition holds, failing the test after the timeout.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: () -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    
    while ContinuousClock.now < deadline {
        if condition() {
            return
        }

        await Task.yield()
    }

    #expect(condition())
}
