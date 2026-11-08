//
//  SoundBuffers.swift
//  OnYourMarks
//
//  Created by Felix on 26.09.26.
//

import AVFAudio
import Foundation

nonisolated enum SoundLoadError: Error, CustomStringConvertible {
    case missingResource(String)
    case emptyFile(String)
    case bufferAllocationFailed(String)
    
    var description: String {
        switch self {
        case .missingResource(let name):
            return "Missing sound resource: \(name)"
        case .emptyFile(let name):
            return "Sound file contains no audio: \(name)"
        case .bufferAllocationFailed(let name):
            return "Could not allocate PCM buffer for: \(name)"
        }
    }
}

/// Loads sound files completely into memory
nonisolated enum SoundBufferLoader {
    /// Uncompressed formats are preferred
    static let supportedExtension = ["caf", "wav", "m4a"]

    static func url(
        forResource name: String,
        in bundle: Bundle = .main
    ) -> URL? {
        for fileExtension in supportedExtension {
            if let url = bundle.url(forResource: name, withExtension: fileExtension) {
                return url
            }
        }
        return nil
    }
    
    static func loadBuffer(
        named name: String,
        in bundle: Bundle = .main
    ) throws -> AVAudioPCMBuffer {
        guard let url = url(forResource: name, in: bundle) else {
            throw SoundLoadError.missingResource(name)
        }
        return try loadBuffer(contentsOf: url)
    }
    
    static func loadBuffer(
        contentsOf url: URL
    ) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let name = url.lastPathComponent
        
        guard file.length > 0, file.length <= Int64(UInt32.max) else {
            throw SoundLoadError.emptyFile(name)
        }
        
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw SoundLoadError.bufferAllocationFailed(name)
        }
        
        try file.read(into: buffer)
        
        guard buffer.frameLength > 0 else {
            throw SoundLoadError.emptyFile(name)
        }
        
        return buffer
    }
}

/// Detect where the actual sound starts in a sound file
nonisolated enum AudioOnsetDetector {
    /// Time from buffer's first frame to the first frame in which any
    /// channel reaches `relativeThreshold` * the buffer's absolute peak.
    ///
    /// `nil` for silent buffers or non-float formats.
    static func onsetOffset(
        in buffer: AVAudioPCMBuffer,
        relativeThreshold: Float = 0.1
    ) -> TimeInterval? {
        guard let channelData = buffer.floatChannelData,
              buffer.frameLength > 0,
              buffer.format.sampleRate > 0 else {
            return nil
        }
        
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let isInterleaved = buffer.format.isInterleaved
        let stride = buffer.stride
        
        func sample(channel: Int, frame: Int) -> Float {
            if isInterleaved {
                // Interleaved float data is exposed through the first pointer only
                return channelData[0][frame * stride + channel]
            }
            return channelData[channel][frame * stride]
        }
        
        var peak: Float = 0
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                peak = max(peak, abs(sample(channel: channel, frame: frame)))
            }
        }
        
        guard peak > 0 else { return nil }
        
        let threshold = peak * relativeThreshold
        
        for frame in 0..<frameCount {
            for channel in 0..<channelCount
                    where abs(sample(channel: channel, frame: frame)) >= threshold {
                return Double(frame) / buffer.format.sampleRate
            }
        }
        
        return nil
    }
}

extension AVAudioPCMBuffer {
    nonisolated var durationSeconds: TimeInterval {
        guard format.sampleRate > 0 else { return 0 }
        return Double(frameLength) / format.sampleRate
    }
}
