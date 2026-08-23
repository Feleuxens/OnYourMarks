//
//  AudioController.swift
//  OnYourMarks
//
//  Created by Felix on 12.06.26.
//

import AVFoundation
import OSLog

@MainActor
final class AudioController: SignalPlayer {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "OnYourMarks",
        category: "Audio"
    )
    
    var theme: SoundTheme {
        didSet {
            guard theme != oldValue else { return }
            loadSounds(theme)
        }
    }
    
    
    private var players: [Signal: AVAudioPlayer] = [:]
    
    init(theme: SoundTheme = .eng1) {
        self.theme = theme
        loadSounds(theme)
    }
    
    func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])

        try session.setActive(true)
    }
    
    func deactivateSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        } catch {
            logger.error("Could not deacticate audio session: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    func loadSounds(_ theme: SoundTheme) {
        stop()
        players.removeAll()
        
        for signal in Signal.allCases {
            let fileName = theme.assetName(for: signal)
            
            guard let url = Bundle.main.url(forResource: fileName, withExtension: "m4a") else {
                logger.error("Missing sound file: \(fileName, privacy: .public).m4a")
                continue
            }
            
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                players[signal] = player
            } catch {
                logger.error("Could not load \(fileName, privacy: .public).m4a: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    @discardableResult
    func play(_ signal: Signal) -> Bool {
        guard let player = players[signal] else {
            logger.error("No audio player loaded for \(String(describing: signal), privacy: .public)")
            return false
        }
        
        player.currentTime = 0
        
        let started = player.play()
        
        if !started {
            logger.error("Playback failed for \(String(describing: signal), privacy: .public)")
        }
        
        return started
    }
    
    func stop() {
        for player in players.values {
            player.stop()
            player.currentTime = 0
        }
    }
    
    func playRecall(times: Int = 3, gap: TimeInterval = 0.35) async {
        guard times > 0 else { return }
        
        for index in 0..<times {
            guard !Task.isCancelled else { return }
            guard play(.go) else { return }
            
            // Wait for the sound to actually finish before waiting a short interval
            let waitTime = index == times - 1 ? duration(of: .go) : gap
            
            do {
                try await Task.sleep(for: .seconds(waitTime))
            } catch {
                return
            }
        }
    }
    
    func duration(of signal: Signal) -> TimeInterval {
        players[signal]?.duration ?? 0
    }
}

enum Signal: CaseIterable {
    case onYourMarks
    case set
    case go
}

@MainActor
protocol SignalPlayer {
    @discardableResult
    func play(_ signal: Signal) -> Bool
    
    func stop()
    
    func playRecall(times: Int, gap: TimeInterval) async
    
    func duration(of signal: Signal) -> TimeInterval
}
