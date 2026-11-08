//
//  StarterViewModel.swift
//  OnYourMarks
//
//  Created by Felix on 11.06.26.
//

import SwiftUI
import Foundation
import QuartzCore

@Observable
@MainActor
class StarterViewModel {
    var config: StartConfig {
        didSet {
            configStore.save(config)
            player.theme = config.soundTheme
        }
    }
    
    private let configStore: ConfigStore
    private let player: AudioSessionPlayer
    
    let cameraDetector: CameraMovementDetector
    let engine: StarterEngine
    
    var currentSession: StartSession? {
        engine.currentSession
    }
    var lastSession: StartSession? {
        engine.lastSession
    }
    
    private var cameraEnableTask: Task<Void, Never>?
    /// Audio of other apps resume after the session is desctivated.
    /// After a start that happens after a delay to let the runner start without distraction.
    private let musicResumeDelay: Duration
    private var sessionDeactivationTask: Task<Void, Never>?
    /// Set from the Start tap until the sequence runs (or the start was
    /// given up). While set, no other start can begin.
    private var startTask: Task<Void, Never>?
    
    var cameraEnabled = false
    var cameraPermissionDenied = false
    var errorMessage: String?
    
    var isStarting: Bool {
        startTask != nil
    }
    
    var isRunning: Bool {
        isStarting || engine.state != .idle
    }
    
    init(
        configStore: ConfigStore? = nil,
        cameraDetector: CameraMovementDetector? = nil,
        player: AudioSessionPlayer? = nil,
        musicResumeDelay: Duration = .seconds(2)
    ) {
        let configStore = configStore ?? ConfigStore()
        let cameraDetector = cameraDetector ?? CameraMovementDetector()
        self.configStore = configStore
        let config = configStore.load()
        self.config = config
        
        let player = player ?? AudioController(theme: config.soundTheme)
        self.player = player
        self.musicResumeDelay = musicResumeDelay
        
        self.cameraDetector = cameraDetector
        self.engine = StarterEngine(player: player, movementDetector: cameraDetector)
        
        engine.onRunEnded = { [weak self] in
            self?.runEnded()
        }
        
        engine.onError = { [weak self] message in
            self?.errorMessage = message
        }
        
        player.onUnexpectedStop = { [weak self] reason in
            self?.handleAudioFailure(reason)
        }
    }
    
    func start() {
        guard !isRunning else { return }
        
        // Within the resume delay this keeps the session (and the music paused).
        // A deactivation already talking to the system finishes first.
        // (AudioController serializes transitions on its own as well.)
        let pendingDeactivation = sessionDeactivationTask
        pendingDeactivation?.cancel()
        sessionDeactivationTask = nil
        
        startTask = Task { [weak self] in
            await pendingDeactivation?.value
            
            guard let self else { return }
            
            // No new start can begin while the handle is set,
            // so it is still ours when we clear it.
            defer { startTask = nil }
            
            // Aborted before activation began: nothing to undo.
            guard !Task.isCancelled else { return }
            
            do {
                try await player.activateSession()
            } catch {
                // Not worth showing if the user already gave up on this start.
                if !Task.isCancelled {
                    errorMessage = "The audio session could not be started: \(error.localizedDescription)"
                }
                return
            }
            
            // Aborted or sent to the background while activating.
            guard !Task.isCancelled else {
                await player.deactivateSession()
                return
            }
            
            engine.start(config: config)
        }
    }
    
    private func runEnded() {
        let delay: Duration = switch engine.lastSession?.outcome {
        case .completed?, .falseStart?:
            musicResumeDelay
        default:
            // on user abort or failure the audio can resume immediately
            .zero
        }
        
        let previous = sessionDeactivationTask
        previous?.cancel()
        
        sessionDeactivationTask = Task { [weak self] in
            await previous?.value
            
            if delay > .zero {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            
            // A new start cancelled us after the sleep had already finished.
            guard !Task.isCancelled else { return }
            
            await self?.player.deactivateSession()
        }
    }
    
    private func flushPendingSessionDeactivation() {
        let previous = sessionDeactivationTask
        previous?.cancel()
        
        sessionDeactivationTask = Task { [weak self] in
            await previous?.value
            await self?.player.deactivateSession()
        }
    }
    
    private func handleAudioFailure(_ reason: String) {
        // If no start is in progress, nothing depends on audio
        guard isRunning else { return }
        
        errorMessage = reason
        abort(reason: reason)
    }
    
    func abort() {
        abort(reason: nil)
    }
    
    private func abort(reason: String?) {
        // Activating: the start task notices and gives the session back.
        if let startTask {
            startTask.cancel()
            return
        }
        
        engine.abort(reason: reason)
    }
    
    func resetConfig() {
        config = .standard
    }

    func enableCamera() {
        guard !isRunning, !cameraEnabled, cameraEnableTask == nil else { return }
        
        cameraEnableTask = Task { [weak self] in
            let granted = await CameraPermission.request()
            
            guard let self else { return }
            
            // disableCamera can cancel this task and cleans it up
            // here we block just further execution but don't need to cleanup
            guard !Task.isCancelled else { return }
            
            defer { self.cameraEnableTask = nil }
            
            guard granted else {
                self.cameraPermissionDenied = true
                return
            }
            self.cameraPermissionDenied = false
            
            guard self.cameraDetector.configureIfNeeded() else {
                self.errorMessage = "The camera could not be configured."
                return
            }
            self.cameraDetector.startSession()
            self.cameraEnabled = true
        }
    }
    
    func disableCamera() {
        guard !isRunning else { return }
        
        stopCamera()
    }
    
    private func stopCamera() {
        cameraEnableTask?.cancel()
        cameraEnableTask = nil
        
        cameraEnabled = false
        cameraDetector.stopMonitoring()
        cameraDetector.stopSession()
    }
    
    /// App was closed or the screen was locked.
    func handleEnteredBackground() {
        if isRunning {
            abort()
        }
        
        // Not disableCamera(): an aborted start may still be finishing
        // its activation, and the camera must go off regardless.
        if cameraEnabled || cameraEnableTask != nil {
            stopCamera()
        }
        flushPendingSessionDeactivation()
    }
}
