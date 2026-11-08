//
//  AudioHostClockBridge.swift
//  OnYourMarks
//
//  Created by Felix on 28.08.26.
//

import AVFAudio
import Foundation

nonisolated struct AudioHostClockBridge: Sendable {
    func hostTime(
        for timestamp: MonotonicTimestamp
    ) -> UInt64 {
        AVAudioTime.hostTime(forSeconds: timestamp.seconds)
    }
    
    func timestamp(
        forHostTime hostTime: UInt64
    ) -> MonotonicTimestamp {
        MonotonicTimestamp(seconds: AVAudioTime.seconds(forHostTime: hostTime))
    }
    
    func audioTime(
        for timestamp: MonotonicTimestamp
    ) -> AVAudioTime {
        AVAudioTime(hostTime: hostTime(for: timestamp))
    }
}
