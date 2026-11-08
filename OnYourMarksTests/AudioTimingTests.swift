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
