//
//  CameraFormat.swift
//  OnYourMarks
//

import AVFoundation

/// What the camera is currently needed for.
nonisolated enum CameraMode: String, Sendable {
    /// Preview and framing: a low frame rate keeps the phone cool.
    case idle

    /// Around the gun, when a movement has to be timed: the highest frame
    /// rate, held whatever the system pressure.
    case precision
}

nonisolated enum CameraPressureLevel: Int, Comparable, Sendable {
    case nominal, fair, serious, critical, shutdown

    init(_ level: AVCaptureDevice.SystemPressureState.Level) {
        self = switch level {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        case .shutdown: .shutdown
        default: .nominal
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The properties of a capture format that matter for choosing one.
nonisolated struct CameraFormatDescriptor: Equatable, Sendable {
    let width: Int
    let height: Int
    let frameRateRanges: [ClosedRange<Double>]
    let pixelFormat: OSType

    /// Whether the system may lower the frame rate by itself in low light.
    let supportsAutoFrameRate: Bool

    var maxFrameRate: Double {
        frameRateRanges.map(\.upperBound).max() ?? 0
    }

    var isSixteenByNine: Bool {
        width * 9 == height * 16
    }
}

extension CameraFormatDescriptor {
    init(_ format: AVCaptureDevice.Format) {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)

        self.init(
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            frameRateRanges: format.videoSupportedFrameRateRanges.map { $0.minFrameRate...$0.maxFrameRate },
            pixelFormat: CMFormatDescriptionGetMediaSubType(format.formatDescription),
            supportsAutoFrameRate: format.isAutoVideoFrameRateSupported
        )
    }
}

/// Picks the one format the session keeps for its whole life. Low and high
/// frame rates are both set within it, because changing the format while
/// running interrupts the stream for several hundred milliseconds.
nonisolated enum CameraFormatSelector {
    static let preferredHeight = 1080

    /// The index of the best format for reaching `frameRate`, or the fastest
    /// one if none reaches it.
    static func bestIndex(among formats: [CameraFormatDescriptor], frameRate: Double) -> Int? {
        let fastest = formats.map(\.maxFrameRate).max() ?? 0
        let required = min(frameRate, fastest)

        return formats.indices
            .filter { formats[$0].maxFrameRate >= required }
            .min { rank(formats[$0]) < rank(formats[$1]) }
    }

    /// Lower is better, compared element by element.
    private static func rank(_ format: CameraFormatDescriptor) -> [Double] {
        [
            format.isSixteenByNine ? 0 : 1,
            Double(abs(format.height - preferredHeight)),
            pixelFormatRank(format.pixelFormat),
            // Formats built for higher rates trade image quality for speed.
            format.maxFrameRate
        ]
    }

    /// 8-bit formats are the cheapest to deliver and all pose detection needs.
    private static func pixelFormatRank(_ pixelFormat: OSType) -> Double {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: 0
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: 1
        default: 2
        }
    }
}

private nonisolated func < (lhs: [Double], rhs: [Double]) -> Bool {
    lhs.lexicographicallyPrecedes(rhs)
}

nonisolated enum CameraFrameRatePolicy {
    static let idle: Double = 15
    static let precision: Double = 120

    /// Idle rate while the system asks for throttling.
    static let throttledIdle: Double = 5

    /// The precision rate is never throttled: a start in progress is worth
    /// more than the little heat a few seconds save.
    static func frameRate(for mode: CameraMode, pressure: CameraPressureLevel) -> Double {
        switch mode {
        case .precision:
            precision
        case .idle:
            pressure >= .serious ? throttledIdle : idle
        }
    }

    /// The requested rate if the format supports it, otherwise the nearest
    /// rate it does. Setting an unsupported rate on a device raises an exception.
    static func supported(_ requested: Double, in ranges: [ClosedRange<Double>]) -> Double? {
        guard !ranges.isEmpty else { return nil }

        if ranges.contains(where: { $0.contains(requested) }) {
            return requested
        }

        return ranges
            .flatMap { [$0.lowerBound, $0.upperBound] }
            .min { abs($0 - requested) < abs($1 - requested) }
    }
}
