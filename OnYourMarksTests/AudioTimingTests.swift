//
//  AudioTimingTests.swift
//  OnYourMarks
//
//  Created by Felix on 28.08.26.
//

import Testing
@testable import OnYourMarks

struct AudioTimingTests {
    @Test
    func hostClockRoundTrip() {
        let bridge = AudioHostClockBridge()

        let original = MonotonicTimestamp(
            seconds: 12_345.678_901
        )

        let hostTime = bridge.hostTime(
            for: original
        )

        let converted = bridge.timestamp(
            forHostTime: hostTime
        )

        let difference = abs(
            converted.seconds -
            original.seconds
        )

        // Conversion through Mach host ticks should be
        // more precise than anything relevant to a 10 ms target.
        #expect(difference < 0.000_001)
    }
}

/// What can be checked without an active audio session.
@MainActor
struct AudioControllerTests {
    @Test
    func loadsEverySignalOfTheTheme() {
        let controller = AudioController(theme: .eng1)
        
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
    
    @Test
    func reloadingThemeKeepsSignalsLoaded() {
        let controller = AudioController(theme: .eng1)
        
        controller.loadSounds(.eng1)
        
        for signal in Signal.allCases {
            #expect(controller.duration(of: signal) > 0.1, "\(signal) lost after reload")
        }
    }
}

