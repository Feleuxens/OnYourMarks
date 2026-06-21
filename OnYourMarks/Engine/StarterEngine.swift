//
//  StarterEngine.swift
//  OnYourMarks
//
//  Created by Felix on 12.06.26.
//

import Foundation

struct Phase: Equatable {
    let state: StarterState
    let duration: TimeInterval?
    let signal: Signal?
}


@Observable
final class StarterEngine {
    private(set) var state: StarterState = .idle
    private let player: SignalPlayer

    init(player: SignalPlayer) {
        self.player = player
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
        let phases = buildSequence(for: config.startType, config: config)
        for phase in phases {
            state = phase.state
            do {
                if Task.isCancelled {
                    state = .idle
                    return
                }
                if let duration = phase.duration {
                    try await Task.sleep(for: .seconds(duration))
                } else if let signal = phase.signal {
                    player.play(signal)
                    try? await Task.sleep(for: .seconds(player.duration(of: signal)))
                }
            } catch {
                state = .idle
            }
        }
    }

    func reset() {
        state = .idle
    }
}
