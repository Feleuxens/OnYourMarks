//
//  AudioController.swift
//  OnYourMarks
//
//  Created by Felix on 12.06.26.
//

import AVFoundation

@MainActor
final class AudioController: SignalPlayer {
    var theme: SoundTheme {
        didSet {
            guard theme != oldValue else { return }
            loadSounds(theme)
        }
    }
    
    
    private var players: [Signal: AVAudioPlayer] = [:]
    
    init(theme: SoundTheme = .eng1) {
        self.theme = theme
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        loadSounds(theme)
    }
    
    func activateSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [
            .allowAirPlay, .allowBluetoothA2DP, .allowBluetoothHFP
        ])
        try? AVAudioSession.sharedInstance().setActive(true)
    }
    
    func deactivateSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    
    func loadSounds(_ theme: SoundTheme) {
        players.removeAll()
        for signal in Signal.allCases {
            let fileName = theme.assetName(for: signal)
            guard let url = Bundle.main.url(forResource: fileName, withExtension: "m4a"),
                  let player = try? AVAudioPlayer(contentsOf: url) else { continue }
            player.prepareToPlay()
            players[signal] = player
        }
    }
    
    func play(_ signal: Signal) {
        let name = theme.assetName(for: signal)
        guard let player = players[signal] else {
            print("⚠️ Kein Player für '\(signal)' mit Datei '\(name)'")
            return
        }
        player.currentTime = 0
        player.play()
    }
    
    func playRecall(times: Int = 3, gap: TimeInterval = 0.35) {
        Task { @MainActor in
            for _ in 0..<times {
                play(.go)
                try? await Task.sleep(for: .seconds(gap))
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

protocol SignalPlayer {
    func play(_ signal: Signal)
    func playRecall(times: Int, gap: TimeInterval)
    func duration(of signal: Signal) -> TimeInterval
}
