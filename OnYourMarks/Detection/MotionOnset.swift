//
//  MotionOnset.swift
//  OnYourMarks
//

import Accelerate
import CoreGraphics
import CoreVideo
import Foundation

/// What one athlete's part of the picture looked like in one frame: a
/// coarse grid of brightness values.
nonisolated struct MotionSample: Equatable, Sendable {
    let time: MonotonicTimestamp
    let cells: [UInt8]
}

/// Reduces an athlete's part of a frame to a `MotionSample`. Cheap enough
/// for every frame at the camera's full rate, unlike pose detection.
nonisolated enum MotionSampler {
    /// Cells per side. Coarse on purpose: averaging takes the sensor noise
    /// out, and a limb moving a few centimetres still changes several cells.
    static let gridSize = 40

    /// How much is added around the joints on each side, as a share of
    /// their extent: joints mark the skeleton, not the outline of the body.
    static let regionPadding: CGFloat = 0.25

    /// The part of the upright, normalized picture an athlete takes up.
    static func region(around joints: DetectedPose.Joints) -> CGRect? {
        guard let first = joints.values.first else { return nil }

        var box = CGRect(origin: first, size: .zero)
        for point in joints.values {
            box = box.union(CGRect(origin: point, size: .zero))
        }

        return box
            .insetBy(dx: -box.width * regionPadding, dy: -box.height * regionPadding)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Where a region of the upright picture lies in the buffer, in pixels.
    /// The buffer lies on its side: the picture's top is the buffer's left
    /// and the picture's right the buffer's top.
    static func bufferRegion(for region: CGRect, bufferWidth: Int, bufferHeight: Int) -> CGRect {
        CGRect(
            x: (1 - region.maxY) * CGFloat(bufferWidth),
            y: (1 - region.maxX) * CGFloat(bufferHeight),
            width: region.height * CGFloat(bufferWidth),
            height: region.width * CGFloat(bufferHeight)
        )
    }

    /// The brightness grid of a region of the buffer, given in pixels: the
    /// region scaled down to the grid. Nil if the region lies outside or
    /// the buffer has no brightness plane of its own.
    ///
    /// Scaled by vImage: measured at about 0.5 ms per athlete on the
    /// iPhone 17 Pro, where a loop in Swift took 1.4 ms in a debug build.
    static func cells(of buffer: CVPixelBuffer, in region: CGRect) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        // The luma plane of the camera's formats, or a one-channel picture.
        let isPlanar = CVPixelBufferGetPlaneCount(buffer) > 0

        guard isPlanar || CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else {
            return nil
        }

        let base = isPlanar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer)
        let bytesPerRow = isPlanar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
        let width = isPlanar ? CVPixelBufferGetWidthOfPlane(buffer, 0) : CVPixelBufferGetWidth(buffer)
        let height = isPlanar ? CVPixelBufferGetHeightOfPlane(buffer, 0) : CVPixelBufferGetHeight(buffer)

        let visible = region.intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral

        guard let base, !visible.isNull, visible.width >= 1, visible.height >= 1 else { return nil }

        var source = vImage_Buffer(
            data: base + Int(visible.minY) * bytesPerRow + Int(visible.minX),
            height: vImagePixelCount(min(Int(visible.height), height - Int(visible.minY))),
            width: vImagePixelCount(min(Int(visible.width), width - Int(visible.minX))),
            rowBytes: bytesPerRow
        )

        var cells = [UInt8](repeating: 0, count: gridSize * gridSize)

        let error = cells.withUnsafeMutableBytes { bytes in
            var destination = vImage_Buffer(
                data: bytes.baseAddress,
                height: vImagePixelCount(gridSize),
                width: vImagePixelCount(gridSize),
                rowBytes: gridSize
            )
            return vImageScale_Planar8(&source, &destination, nil, vImage_Flags(kvImageNoFlags))
        }

        return error == kvImageNoError ? cells : nil
    }
}

/// The recent samples of every athlete that holds still, kept in memory so
/// that the beginning of a movement can be looked up once it is certain
/// that there was one.
nonisolated struct MotionTimeline: Sendable {
    /// How far back samples are kept. A movement is looked for within one
    /// second before it was confirmed; the rest is margin.
    static let retention: TimeInterval = 4

    /// Where each watched athlete is, in the upright normalized picture.
    private(set) var regions: [AthleteID: CGRect] = [:]
    private var samples: [AthleteID: [MotionSample]] = [:]

    /// Athletes that are no longer listed, or whose region changed, start
    /// afresh: samples of different regions can't be compared.
    mutating func setRegions(_ newRegions: [AthleteID: CGRect]) {
        for id in Set(regions.keys).union(newRegions.keys) where regions[id] != newRegions[id] {
            samples[id] = nil
        }
        regions = newRegions
    }

    mutating func append(_ sample: MotionSample, for athlete: AthleteID) {
        guard regions[athlete] != nil else { return }

        var kept = samples[athlete] ?? []
        kept.append(sample)

        if let first = kept.firstIndex(where: { sample.time.seconds - $0.time.seconds <= Self.retention }), first > 0 {
            kept.removeFirst(first)
        }
        samples[athlete] = kept
    }

    func samples(for athlete: AthleteID) -> [MotionSample] {
        samples[athlete] ?? []
    }

    mutating func reset() {
        regions = [:]
        samples = [:]
    }
}

/// Finds the frame in which a movement began, once pose detection has
/// confirmed that the athlete moved.
///
/// Pose detection says who moved and that they did, but only when the body
/// has already travelled some way, and not on every frame. The samples
/// exist for every frame: walking back from the confirmation to where the
/// picture first differed from the athlete at rest gives the beginning.
nonisolated enum MotionOnsetAnalyzer {
    /// How far before the confirmation the beginning is looked for. A
    /// movement that takes longer to reach the threshold is unsteadiness.
    static let lookback: TimeInterval = 1

    /// The first stretch of the lookback shows the athlete at rest: it
    /// gives the resting picture and how much it flickers by itself.
    static let baselineDuration: TimeInterval = 0.2

    /// Fewer frames than this say too little about the noise.
    static let minimumBaselineFrames = 8

    /// How many standard deviations above its resting level the difference
    /// has to be. High, so that noise is not taken for the beginning: a
    /// beginning found too early would make a legal start look false.
    static let noiseFactor = 6.0

    /// The least rise that counts, in brightness steps of 255, for
    /// pictures so clean that the standard deviation is next to nothing.
    static let minimumRise = 0.5

    struct Onset: Equatable, Sendable {
        /// After the last frame that still showed the athlete at rest, up
        /// to the first that didn't.
        let interval: TimeEstimate

        /// Frames missing between those two; they widen the interval.
        let droppedFrames: Int
    }

    /// Nil if the samples don't allow a statement: too few of them, no
    /// difference at the confirmation, or a difference all the way back.
    static func onset(in samples: [MotionSample], confirmedAt confirmation: MonotonicTimestamp) -> Onset? {
        let window = samples.filter {
            $0.time <= confirmation && confirmation.seconds - $0.time.seconds <= lookback
        }

        guard let start = window.first else { return nil }

        let baseline = window.prefix { $0.time.seconds - start.time.seconds <= baselineDuration }

        guard baseline.count >= minimumBaselineFrames, baseline.count < window.count else { return nil }

        let reference = restingPicture(of: Array(baseline))
        let energies = window.map { difference(of: $0.cells, from: reference) }

        let resting = energies.prefix(baseline.count)
        let mean = resting.reduce(0, +) / Double(resting.count)
        let variance = resting.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(resting.count)
        let threshold = mean + max(noiseFactor * variance.squareRoot(), minimumRise)

        // Pose detection saw a movement here; the picture has to show one too.
        guard let last = energies.indices.last, energies[last] > threshold else { return nil }

        var first = last
        while first > 0, energies[first - 1] > threshold {
            first -= 1
        }

        // Different from rest ever since the resting stretch: no beginning in sight.
        guard first > baseline.count else { return nil }

        let before = window[first - 1].time
        let at = window[first].time

        return Onset(
            interval: TimeEstimate(
                best: MonotonicTimestamp(seconds: (before.seconds + at.seconds) / 2),
                earliest: before,
                latest: at
            ),
            droppedFrames: droppedFrames(before: first, in: window)
        )
    }

    /// The average of the samples, with each one's overall brightness
    /// taken out first.
    private static func restingPicture(of samples: [MotionSample]) -> [Double] {
        guard let count = samples.first?.cells.count else { return [] }

        var sum = [Double](repeating: 0, count: count)
        for sample in samples where sample.cells.count == count {
            for (index, value) in levelled(sample.cells).enumerated() {
                sum[index] += value
            }
        }
        return sum.map { $0 / Double(samples.count) }
    }

    /// How much a sample differs from the resting picture: the mean
    /// absolute difference per cell. The overall brightness doesn't count,
    /// so flickering light or a changing exposure isn't a movement.
    static func difference(of cells: [UInt8], from reference: [Double]) -> Double {
        guard cells.count == reference.count, !cells.isEmpty else { return 0 }

        let sample = levelled(cells)
        var sum = 0.0
        for index in sample.indices {
            sum += abs(sample[index] - reference[index])
        }
        return sum / Double(sample.count)
    }

    private static func levelled(_ cells: [UInt8]) -> [Double] {
        let mean = cells.reduce(0.0) { $0 + Double($1) } / Double(max(cells.count, 1))
        return cells.map { Double($0) - mean }
    }

    /// How many frames are missing before the given one, judged by the
    /// usual distance between frames around it.
    private static func droppedFrames(before index: Int, in window: [MotionSample]) -> Int {
        let gaps = zip(window.dropFirst(), window).map { $0.time.seconds - $1.time.seconds }.sorted()

        guard !gaps.isEmpty else { return 0 }

        let usual = gaps[gaps.count / 2]
        let gap = window[index].time.seconds - window[index - 1].time.seconds

        guard usual > 0 else { return 0 }
        return max(0, Int((gap / usual).rounded()) - 1)
    }
}
