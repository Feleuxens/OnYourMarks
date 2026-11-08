//
//  AudioControllerTests.swift
//  OnYourMarksTests
//

import Testing
import AVFoundation
@testable import OnYourMarks

/// Runs against the real audio session, which the simulator supports.
/// Serialized because every controller shares the one system session.
@MainActor
@Suite(.serialized)
struct AudioControllerTests {
    @Test(arguments: SoundTheme.allCases)
    func loadsEverySignalOfTheTheme(theme: SoundTheme) {
        let controller = AudioController(theme: theme)
        
        for signal in Signal.allCases {
            #expect(controller.duration(of: signal) > 0.1, "\(signal) not loaded")
            #expect(controller.onsetOffsets[signal] != nil, "\(signal) has no onset")
        }
    }
    
    @Test
    func playFailsWithoutActiveSession() {
        let controller = AudioController(theme: .eng1)
        
        #expect(!controller.isSessionActive)
        #expect(!controller.play(.go))
    }
    
    @Test
    func deactivatingInactiveSessionIsSafe() async {
        let controller = AudioController(theme: .eng1)
        
        await controller.deactivateSession()
        
        #expect(!controller.isSessionActive)
    }
    
    @Test(arguments: SoundTheme.allCases)
    func reloadingThemeKeepsSignalsLoaded(theme: SoundTheme) {
        let controller = AudioController(theme: .eng1)
        
        controller.loadSounds(theme)
        
        for signal in Signal.allCases {
            #expect(controller.duration(of: signal) > 0.1, "\(signal) lost after reload")
        }
    }
    
    // MARK: - With an active session
    
    /// An active controller that records each unexpected stop it reports.
    private func activeController() async throws -> (AudioController, StopRecorder) {
        let controller = AudioController(theme: .eng1)
        let recorder = StopRecorder()
        controller.onUnexpectedStop = { recorder.reasons.append($0) }
        
        try await controller.activateSession()
        return (controller, recorder)
    }
    
    /// Lets the async notification handlers hop to the main actor and run.
    private func settle() async {
        for _ in 0..<50 {
            await Task.yield()
        }
    }
    
    @Test
    func activationEnablesPlaybackAndDeactivationStopsIt() async throws {
        let (controller, recorder) = try await activeController()
        
        #expect(controller.isSessionActive)
        #expect(controller.play(.go))
        
        await controller.deactivateSession()
        
        #expect(!controller.isSessionActive)
        #expect(!controller.play(.go))
        // Our own deactivation is not mistaken for the system taking audio away.
        await settle()
        #expect(recorder.reasons.isEmpty)
    }
    
    @Test
    func repeatedTransitionsStaySerialized() async throws {
        let controller = AudioController(theme: .eng1)
        
        // Requested back to back without waiting, as quick taps would.
        // Main-actor tasks start in the order they're created.
        let first = Task { try await controller.activateSession() }
        let second = Task { await controller.deactivateSession() }
        let third = Task { try await controller.activateSession() }
        
        try await first.value
        await second.value
        try await third.value
        
        #expect(controller.isSessionActive)
        #expect(controller.play(.go))
        
        await controller.deactivateSession()
    }
    
    @Test
    func changingThemeWhileActiveKeepsEngineRunning() async throws {
        let (controller, recorder) = try await activeController()
        
        controller.loadSounds(.eng1)
        
        for signal in Signal.allCases {
            #expect(controller.play(signal), "\(signal) not playable after reload")
        }
        #expect(recorder.reasons.isEmpty)
        
        await controller.deactivateSession()
    }
    
    @Test
    func sessionBecomingInactiveStopsPlaybackAndReports() async throws {
        let (controller, recorder) = try await activeController()
        
        controller.handleSessionBecameInactive()
        // A second report of the same loss (e.g. route change right after) stays silent.
        controller.handleSessionBecameInactive()
        
        #expect(recorder.reasons.count == 1)
        #expect(!controller.isSessionActive)
        #expect(!controller.play(.go))
        
        await controller.deactivateSession()
    }
    
    @Test
    func mediaServicesResetRebuildsAndReports() async throws {
        let (controller, recorder) = try await activeController()
        
        NotificationCenter.default.post(
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance()
        )
        await settle()
        
        #expect(recorder.reasons.count == 1)
        #expect(!controller.isSessionActive)
        for signal in Signal.allCases {
            #expect(controller.duration(of: signal) > 0.1, "\(signal) lost after reset")
        }
        
        // The rebuilt engine can be used for the next start.
        try await controller.activateSession()
        #expect(controller.play(.go))
        await controller.deactivateSession()
    }
    
    @Test
    func routeNotificationWithoutOutputChangeIsIgnored() async throws {
        let (controller, recorder) = try await activeController()
        
        // Also posted for category changes; only a different set of outputs counts.
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
        await settle()
        
        #expect(recorder.reasons.isEmpty)
        #expect(controller.isSessionActive)
        
        await controller.deactivateSession()
    }
    
    @Test
    func configurationChangeOfAnotherEngineIsIgnored() async throws {
        let (controller, recorder) = try await activeController()
        let otherEngine = AVAudioEngine()
        
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: otherEngine)
        await settle()
        
        #expect(recorder.reasons.isEmpty)
        #expect(controller.isSessionActive)
        
        await controller.deactivateSession()
    }
    
    @Test
    func notificationsWhileInactiveAreIgnored() async {
        let controller = AudioController(theme: .eng1)
        let recorder = StopRecorder()
        controller.onUnexpectedStop = { recorder.reasons.append($0) }
        
        let session = AVAudioSession.sharedInstance()
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: session)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nil)
        controller.handleSessionBecameInactive()
        await settle()
        
        #expect(recorder.reasons.isEmpty)
    }
}

@MainActor
private final class StopRecorder {
    var reasons: [String] = []
}

