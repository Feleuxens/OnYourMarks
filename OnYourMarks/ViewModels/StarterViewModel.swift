//
//  StarterViewModel.swift
//  OnYourMarks
//
//  Created by Felix on 11.06.26.
//

import SwiftUI
import Foundation

@Observable
class StarterViewModel {
    var config: StartConfig
    private let configStore = ConfigStore()
    let engine: StarterEngine
    private let player: AudioController
    private var task: Task<Void, Never>?
    
    var isRunning: Bool {
        engine.state != .idle
    }
    
    init() {
        self.config = ConfigStore().load()
        let player = AudioController()
        self.player = player
        self.engine = StarterEngine(player: player)
    }
    
    func start() {
        configStore.save(config)
        player.activateSession()
        task = Task {
            await engine.start(type: config.startType, config: config)
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
}
