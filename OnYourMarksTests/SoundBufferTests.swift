//
//  SoundBufferTests.swift
//  OnYourMarks
//
//  Created by Felix on 25.09.26.
//

import Testing
import AVFAudio
@testable import OnYourMarks

struct SoundBufferTests {
    private func makeBuffer(
        sampleRate: Double = 48_000,
        channels: AVAudioChannelCount = 2,
        interleaved: Bool = false,
        frames: AVAudioFrameCount,
        sample: (_ channel: Int, _ frame: Int) -> Float
    ) throws -> AVAudioPCMBuffer {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channels,
                interleaved: interleaved
            )
        )
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        )
        buffer.frameLength = frames
        
        let data = try #require(buffer.floatChannelData)
        
        for frame in 0..<Int(frames) {
            for channel in 0..<Int(channels) {
                if interleaved {
                    data[0][frame * Int(channels) + channel] = sample(channel, frame)
                } else {
                    data[channel][frame] = sample(channel, frame)
                }
            }
        }
        
        return buffer
    }
    
    @Test
    func silentBufferHasNoOnset() throws {
        let buffer = try makeBuffer(frames: 4_800) { _, _ in 0 }
        
        #expect(AudioOnsetDetector.onsetOffset(in: buffer) == nil)
    }
    
    @Test
    func onsetIsFirstLoudFrameInAnyChannel() throws {
        // Transient only on the right channel, 10 ms in.
        let buffer = try makeBuffer(frames: 4_800) { channel, frame in
            channel == 1 && frame >= 480 ? 0.8 : 0
        }
        
        let onset = try #require(AudioOnsetDetector.onsetOffset(in: buffer))
        
        #expect(abs(onset - 0.010) < 0.000_001)
    }
    
    @Test
    func noiseBelowThresholdIsIgnored() throws {
        // 5 % noise floor, full-scale transient at 10 ms.
        let buffer = try makeBuffer(frames: 4_800) { _, frame in
            frame >= 480 ? 1.0 : (frame.isMultiple(of: 2) ? 0.05 : -0.05)
        }
        
        let onset = try #require(AudioOnsetDetector.onsetOffset(in: buffer))
        
        #expect(abs(onset - 0.010) < 0.000_001)
    }
    
    @Test
    func interleavedBufferIsSupported() throws {
        let buffer = try makeBuffer(interleaved: true, frames: 4_800) { channel, frame in
            channel == 1 && frame >= 240 ? -0.9 : 0
        }
        
        let onset = try #require(AudioOnsetDetector.onsetOffset(in: buffer))
        
        #expect(abs(onset - 0.005) < 0.000_001)
    }
    
    /// Decodes the real bundled sounds with AVAudioFile.
    ///
    /// Reference values from an offline ffmpeg decode of the m4a files
    /// (which includes 1024 frames of AAC encoder priming, because the
    /// files' edit lists don't mark it):
    /// gun 23.63 ms, set 42.11 ms, on your marks 29.48 ms.
    /// If AVAudioFile trims the priming instead, the onsets are ~23.2 ms
    /// earlier. The printed values tell us which one the device plays.
    @Test
    @MainActor
    func bundledSignalsDecodeWithPlausibleOnset() throws {
        for theme in SoundTheme.allCases {
            for signal in Signal.allCases {
                let name = theme.assetName(for: signal)
                
                let buffer = try SoundBufferLoader.loadBuffer(named: name)
                
                #expect(buffer.durationSeconds > 0.1, "\(name) is suspiciously short")
                
                let onset = try #require(
                    AudioOnsetDetector.onsetOffset(in: buffer),
                    "\(name) has no detectable onset"
                )
                
                #expect(onset < 0.1, "\(name) onset \(onset) s is later than expected")
                
                print(
                    "[SoundBufferTests] \(name): \(buffer.format.sampleRate) Hz, "
                    + "\(buffer.frameLength) frames, onset \(onset * 1000) ms"
                )
            }
        }
    }
}
