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


@Observable
final class StarterEngine {
    private(set) var state: StarterState = .idle
    private let player: SignalPlayer
    private let movementDetector: MovementDetector
    private(set) var lastReactionTime: TimeInterval?
    
    private var shotTime: TimeInterval? = nil

    init(player: SignalPlayer, movementDetector: MovementDetector) {
        self.player = player
        self.movementDetector = movementDetector
        self.movementDetector.onMovement = { [weak self] moveTime in
                self?.handleMovement(at: moveTime)
            }
    }
    
    private func handleMovement(at moveTime: TimeInterval) {
        guard state == .waitForStart || state == .start else { return }

        switch shotTime {
        case nil:
            print("False start")
            triggerFalseStart()

        case let shot?:
            let reaction = moveTime - shot
            if reaction < 0.100 {
                print("Reaction time \(reaction)")
                triggerFalseStart()
            } else {
                lastReactionTime = reaction
                movementDetector.stopMonitoring()
            }
        }
    }
    
    private func triggerFalseStart() {
        state = .idle
        movementDetector.stopMonitoring()
        player.playRecall(times: 3, gap: 0.35)
    }
    
    func buildSequence(for type: StartType, config: StartConfig) -> [Phase] {
        switch type {
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

    func start(type: StartType, config: StartConfig) async {
        shotTime = nil
        let phases = buildSequence(for: config.startType, config: config)

        for phase in phases {
            if Task.isCancelled { break }

            state = phase.state

            if state == .waitForStart { movementDetector.startMonitoring() }
            if state == .start { shotTime = CACurrentMediaTime() }

            if let duration = phase.duration {
                do { try await Task.sleep(for: .seconds(duration)) }
                catch { break }
            } else if let signal = phase.signal {
                player.play(signal)
                try? await Task.sleep(for: .seconds(player.duration(of: signal)))
            }
        }

        state = .idle
        movementDetector.stopMonitoring()
    }
    
    func reset() {
        state = .idle
        movementDetector.stopMonitoring()
    }
}
