//
//  StarterEngine.swift
//  OnYourMarks
//
//  Created by Felix on 12.06.26.
//

import Foundation
import QuartzCore

struct Phase: Equatable {
    let state: StarterState
    let duration: TimeInterval?
    let signal: Signal?
}


@Observable @MainActor
final class StarterEngine {
    private(set) var state: StarterState = .idle
    private(set) var isRunning: Bool = false
    
    private(set) var lastReactionTime: TimeInterval?
    private let player: SignalPlayer
    private let movementDetector: MovementDetector
    
    private var sequenceTask: Task<Void, Never>?
    private var shotTime: TimeInterval? = nil
    
    var onRunEnded: (() -> Void)?
    var onError: ((String) -> Void)?
    
    private enum SequenceOutcome {
        case completed
        case cancelled
        case failed(String)
    }

    init(player: SignalPlayer, movementDetector: MovementDetector) {
        self.player = player
        self.movementDetector = movementDetector
        
        self.movementDetector.onMovement = { [weak self] moveTime in
                self?.handleMovement(at: moveTime)
            }
    }
    
    func start(config: StartConfig) {
        guard !isRunning else { return }
        
        player.stop()
                
        shotTime = nil
        lastReactionTime = nil
        isRunning = true
        
        sequenceTask = Task { [weak self] in
            guard let self else { return }
            
            let outcome = await runSequence(config: config)
            
            // abort() or triggerFalseStart() runs own cleanup after cancellation
            guard !Task.isCancelled else { return }
            
            switch outcome {
            case .completed:
                self.finishRun()
                
            case .failed(let message):
                self.onError?(message)
                self.finishRun()
            
            case .cancelled:
                break
            }
        }
    }
    
    func abort() {
        guard isRunning else { return }
        
        sequenceTask?.cancel()
        sequenceTask = nil
        
        player.stop()
        movementDetector.stopMonitoring()
        
        shotTime = nil
        state = .idle
        isRunning = false
        
        onRunEnded?()
    }
    
    private func finishRun() {
        guard isRunning else { return }
        
        sequenceTask = nil
        
        player.stop()
        movementDetector.stopMonitoring()
        
        shotTime = nil
        state = .idle
        isRunning = false
        
        onRunEnded?()
    }
    
    private func handleMovement(at moveTime: TimeInterval) {
        guard state == .waitForStart || state == .start else { return }

        switch shotTime {
        case nil:
            triggerFalseStart()

        case let shot?:
            let reaction = moveTime - shot
            
            if reaction < 0.100 {
                triggerFalseStart()
            } else {
                lastReactionTime = reaction
                movementDetector.stopMonitoring()
            }
        }
    }
    
    
    
    private func triggerFalseStart() {
        guard isRunning, state != .falseStart else { return }
        
        sequenceTask?.cancel()
        
        player.stop()
        movementDetector.stopMonitoring()
        
        state = .falseStart
        
        sequenceTask = Task { [weak self] in
            guard let self else { return }
            
            await self.player.playRecall(times: 3, gap: 0.35)
            
            guard !Task.isCancelled else { return }
            
            self.finishRun()
        }
    }
    
    private func runSequence(config: StartConfig) async -> SequenceOutcome {
        let phases = buildSequence(config: config)

        for phase in phases {
            guard !Task.isCancelled else {
                return .cancelled
            }

            state = phase.state

            if state == .waitForStart {
                movementDetector.startMonitoring()
            }
            // this currently ignores audio schedule latency
            if state == .start {
                shotTime = CACurrentMediaTime()
            }
            
            if let signal = phase.signal {
                guard player.play(signal) else {
                    return .failed("Could not play \(signal)")
                }
                
                do {
                    try await Task.sleep(for: .seconds(player.duration(of: signal)))
                } catch {
                    return .cancelled
                }
            } else if let duration = phase.duration {
                do { try await Task.sleep(for: .seconds(duration)) }
                catch { return .cancelled }
            }
        }
        return .completed
    }
    
    func buildSequence(config: StartConfig) -> [Phase] {
        switch config.startType {
        case .block:
            return [
                Phase(state: .preparing, duration: config.blockTimeToReady, signal: nil),
                Phase(state: .onYourMarks, duration: nil, signal: Signal.onYourMarks),
                Phase(state: .waitForSet, duration: config.blockTimeToSet, signal: nil),
                Phase(state: .set, duration: nil, signal: Signal.set),
                Phase(state: .waitForStart, duration: randomTimeToStart(config.blockTimeToStartMin, config.blockTimeToStartMax), signal: nil),
                Phase(state: .start, duration: nil, signal: Signal.go),
            ]
        case .standing:
            return [
                Phase(state: .preparing, duration: config.standingTimeToReady, signal: nil),
                Phase(state: .onYourMarks, duration: nil, signal: Signal.onYourMarks),
                Phase(state: .waitForStart, duration: randomTimeToStart(config.standingTimeToStartMin, config.standingTimeToStartMax), signal: nil),
                Phase(state: .start, duration: nil, signal: Signal.go),
            ]
        }
    }

    private func randomTimeToStart(_ a: Double, _ b: Double) -> TimeInterval {
        return Double.random(in: min(a, b)...max(a, b))
    }
}
