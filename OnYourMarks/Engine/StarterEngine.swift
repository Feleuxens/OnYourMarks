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
@MainActor
final class StarterEngine {
    private(set) var state: StarterState = .idle
    private(set) var isRunning: Bool = false
    
    /// Kept for compatability with current UI
    private(set) var lastReactionTime: TimeInterval?
    
    private(set) var lastReactionEstimate: DurationEstimate?
    private(set) var lastDecision: StartDecision?
    
    private(set) var currentSession: StartSession?
    private(set) var lastSession: StartSession?
    
    private let player: SignalPlayer
    private let movementDetector: MovementDetector
    
    private let clock: MonotonicClock
    private let decisionEngine: DecisionEngine
    
    private var sequenceTask: Task<Void, Never>?
    
    /// Kept until precise audio timing is implemented
    private var gunTime: TimeEstimate?
    
    private var monitoringActive: Bool = false
    
    var onRunEnded: (() -> Void)?
    var onError: ((String) -> Void)?
    
    private enum SequenceOutcome {
        case completed
        case cancelled
        case failed(String)
    }
    
    convenience init(
        player: SignalPlayer,
        movementDetector: MovementDetector
    ) {
        self.init(
            player: player,
            movementDetector: movementDetector,
            clock: SystemMonotonicClock(),
            decisionEngine: DecisionEngine()
        )
    }
    
    init(
        player: SignalPlayer,
        movementDetector: MovementDetector,
        clock: MonotonicClock,
        decisionEngine: DecisionEngine
    ) {
        self.player = player
        self.movementDetector = movementDetector
        self.clock = clock
        self.decisionEngine = decisionEngine
        
        self.movementDetector.onMovement = { [weak self] moveTime in
            self?.handleMovement(at: moveTime)
        }
    }
    
    func start(config: StartConfig) {
        guard !isRunning else { return }
        
        player.stop()
        
        gunTime = nil
        lastReactionTime = nil
        lastReactionEstimate = nil
        lastDecision = nil
        monitoringActive = false
        
        let profile = config.startType.profile
        let now = clock.now()
        
        currentSession = StartSession(
            startType: config.startType,
            profile: profile,
            createdAt: now
        )
        
        isRunning = true
        
        sequenceTask = Task { [weak self] in
            guard let self else { return }
            
            let outcome = await runSequence(config: config)
            
            // abort() or triggerFalseStart() runs own cleanup after cancellation
            guard !Task.isCancelled else { return }
            
            switch outcome {
            case .completed:
                self.finishRun(outcome: .completed)
                
            case .failed(let message):
                self.onError?(message)
                self.finishRun(outcome: .failed(message))
                
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
        stopMovementMonitoring()
        
        gunTime = nil
        setState(.idle)
        isRunning = false
        
        finalizeSession(
            outcome: .aborted
        )
        
        onRunEnded?()
    }
    
    private func finishRun(outcome: StartSessionOutcome) {
        guard isRunning else { return }
        
        sequenceTask = nil
        
        player.stop()
        stopMovementMonitoring()
        
        gunTime = nil
        setState(.idle)
        isRunning = false
        
        finalizeSession(outcome: outcome)
        
        onRunEnded?()
    }
    
    private func handleMovement(
        at rawMoveTime: TimeInterval
    ) {
        guard state == .waitForStart || state == .start else { return }
        
        guard let profile = currentSession?.profile else { return }
        
        // For now movementTime comes from CMSampleBuffer timestamp
        // Todo for later will map capture timestamps
        let movementTime = TimeEstimate.exact(MonotonicTimestamp(seconds: rawMoveTime))
        
        record(
            .movementObserved,
            at: movementTime,
            source: .cameraLocal
        )
        
        guard let gunTime else {
            let decision = StartDecision.definiteFalseStart
            
            lastDecision = decision
            
            record(
                .decision(decision),
                at: movementTime,
                source: .system
            )
            
            triggerFalseStart()
            return
        }
        
        let reaction = movementTime.duration(since: gunTime)
        
        lastReactionEstimate = reaction
        lastReactionTime = reaction.best
        
        record(
            .reactionMeasured(reaction),
            at: movementTime,
            source: .cameraLocal
        )
        
        let decision = decisionEngine.evaluateReaction(reaction, profile: profile)
        
        lastDecision = decision
        
        record(
            .decision(decision),
            at: movementTime,
            source: .system
        )
        
        switch decision {
        case .definiteFalseStart:
            triggerFalseStart()
            
        case .uncertain,
                .legal,
                .notApplicable:
            stopMovementMonitoring()
        }
    }
    
    
    private func triggerFalseStart() {
        guard isRunning, state != .falseStart else { return }
        
        sequenceTask?.cancel()
        
        player.stop()
        stopMovementMonitoring()
        
        setState(.falseStart)
        
        sequenceTask = Task { [weak self] in
            guard let self else { return }
            
            await self.player.playRecall(times: 3, gap: 0.30)
            
            guard !Task.isCancelled else { return }
            
            self.finishRun(outcome: .falseStart)
        }
    }
    
    private func runSequence(config: StartConfig) async -> SequenceOutcome {
        let phases = buildSequence(config: config)
        
        for phase in phases {
            guard !Task.isCancelled else {
                return .cancelled
            }
            
            setState(phase.state)
            
            if phase.state == .waitForStart {
                startMovementMonitoring()
            }
            // this currently ignores audio schedule latency
            if phase.state == .start {
                let time = TimeEstimate.exact(clock.now())
                
                gunTime = time
                
                record(.gunPlaybackRequest, at: time, source: .audioLocal)
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
        let profile = config.startType.profile
        
        switch profile.startType {
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
    
    private func setState(_ newState: StarterState) {
        guard state != newState else {
            return
        }
        
        state = newState
        
        record(.stateChanged(newState), source: .system)
    }
    
    private func startMovementMonitoring() {
        guard !monitoringActive else {
            return
        }
        
        movementDetector.startMonitoring()
        monitoringActive = true
        
        record(.monitoringStarted, source: .system)
    }
    
    private func stopMovementMonitoring() {
        guard monitoringActive else {
            return
        }
        
        movementDetector.stopMonitoring()
        monitoringActive = false
        
        record(.monitoringStopped, source: .system)
    }

    private func record(
        _ kind: StartEventKind,
        at time: TimeEstimate? = nil,
        source: MeasurementSource,
        athleteID: AthleteID? = nil
    ) {
        guard currentSession != nil else {
            return
        }
        
        let eventTime = time ?? TimeEstimate.exact(clock.now())
        
        currentSession?.record(kind, at: eventTime, source: source, athleteID: athleteID)
    }
    
    private func finalizeSession(outcome: StartSessionOutcome) {
        guard var session = currentSession else {
            return
        }
        
        session.finish(outcome, at: .exact(clock.now()))
        
        lastSession = session
        currentSession = nil
    }
}
