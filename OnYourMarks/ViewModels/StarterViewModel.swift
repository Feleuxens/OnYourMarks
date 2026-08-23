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
    private let player: AudioController
    
    let cameraDetector: CameraMovementDetector
    let engine: StarterEngine
    
    private var cameraEnableTask: Task<Void, Never>?
    
    var cameraEnabled = false
    var cameraPermissionDenied = false
    var errorMessage: String?
    
    var isRunning: Bool {
        engine.state != .idle
    }
    
    init(configStore: ConfigStore? = nil, cameraDetector: CameraMovementDetector? = nil) {
        let configStore = configStore ?? ConfigStore()
        let cameraDetector = cameraDetector ?? CameraMovementDetector()
        self.configStore = configStore
        let config = configStore.load()
        self.config = config
        
        let player = AudioController(theme: config.soundTheme)
        self.player = player
        
        self.cameraDetector = cameraDetector
        self.engine = StarterEngine(player: player, movementDetector: cameraDetector)
        
        engine.onRunEnded = { [weak self] in
            self?.player.deactivateSession()
        }
        
        engine.onError = { [weak self] message in
            self?.errorMessage = message
        }

    }
    
    func start() {
        guard !isRunning else { return }
        
        do {
            try player.activateSession()
        } catch {
            errorMessage = "The audio session could not be startet: \(error.localizedDescription)"
            return
        }
        
        engine.start(config: config)
    }
    
    func abort() {
        engine.abort()
    }
    
    func resetConfig() {
        config = .standard
    }

    func enableCamera() {
        guard !isRunning else { return }
        
        Task {
            guard await CameraPermission.request() else {
                cameraPermissionDenied = true
                return
            }
            cameraPermissionDenied = false
            guard cameraDetector.configureIfNeeded() else {
                errorMessage = "The camera could not be configured."
                return
            }
            cameraDetector.startSession()
            cameraEnabled = true
        }
    }
    
    func disableCamera() {
        guard !isRunning else { return }
        
        cameraEnableTask?.cancel()
        cameraEnableTask = nil
        
        cameraEnabled = false
        cameraDetector.stopMonitoring()
        cameraDetector.stopSession()
    }
}
