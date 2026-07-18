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
class StarterViewModel {
    var config: StartConfig
    private let configStore = ConfigStore()
    let engine: StarterEngine
    private let player: AudioController
    private var task: Task<Void, Never>?
    
    let cameraDetector = CameraMovementDetector()
    var shotTime: TimeInterval?
    var lastResult: ReactionResult?
    var falseStartActive = false
    var cameraEnabled = false
    var cameraPermissionDenied: Bool = false
    
    var isRunning: Bool {
        engine.state != .idle
    }
    
    init() {
        self.config = ConfigStore().load()
        let player = AudioController()
        self.player = player
        self.engine = StarterEngine(player: player, movementDetector: cameraDetector)
    }
    
    func start() {
        guard !isRunning else { return }  // prevent overlapping starts
        
        configStore.save(config)
        player.activateSession()
        task = Task {
            await engine.start(config: config)
            engine.reset()
            player.deactivateSession()
        }
    }
    
    func abort() {
        task?.cancel()
        task = nil
        engine.reset()
        player.deactivateSession()
    }
    
    func resetConfig() {
        config = .standard
    }

    func enableCamera() {
        Task {
            guard await CameraPermission.request() else {
                cameraPermissionDenied = true
                return
            }
            cameraDetector.configureIfNeeded()
            cameraDetector.startSession()
            cameraEnabled = true
        }
    }
    
    func disableCamera() {
        cameraEnabled = false
        cameraDetector.stopMonitoring()
        cameraDetector.stopSession()
    }
}
