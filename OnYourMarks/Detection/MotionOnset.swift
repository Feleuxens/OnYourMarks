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

/// Stored with a recording. The cells are kept as one block of bytes rather
/// than as a number each.
nonisolated extension MotionSample: Codable {
    private enum CodingKeys: String, CodingKey {
        case time, cells
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.init(
            time: try container.decode(MonotonicTimestamp.self, forKey: .time),
            cells: [UInt8](try container.decode(Data.self, forKey: .cells))
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(time, forKey: .time)
        try container.encode(Data(cells), forKey: .cells)
    }
}

/// What the sampler saw of one athlete up to the end of the monitoring:
/// exactly what the onset analysis had to go on. Kept with a recording, so
/// the analysis can be run again and changed against real starts.
nonisolated struct MotionRecord: Equatable, Codable, Sendable {
    let athleteID: AthleteID

    /// The part of the upright normalized picture that was sampled.
    let region: CGRect

    let samples: [MotionSample]
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
    /// How far back samples are kept. The beginning of a movement is looked
    /// for shortly before it was confirmed, but how restless the athlete's
    /// rest was is learned from all there is (`MotionOnsetAnalyzer`).
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

    /// Everything that is kept, athlete by athlete from the left.
    var records: [MotionRecord] {
        regions
            .sorted { $0.value.minX < $1.value.minX }
            .compactMap { athlete, region in
                samples[athlete].map { MotionRecord(athleteID: athlete, region: region, samples: $0) }
            }
    }

    mutating func reset() {
        regions = [:]
        samples = [:]
    }
}

/// Finds when a movement began, once pose detection has confirmed that the
/// athlete moved.
///
/// Pose detection says who moved and that they did, but only when the body
/// has already travelled some way, and not on every frame. The samples
/// exist for every frame: walking back from the confirmation to where the
/// picture last looked the way it does at rest gives the beginning.
///
/// Rest is not a still picture. A standing athlete sways, a tripod shakes
/// in the wind, and both move every edge in the picture. So nothing is
/// compared with one resting picture, and nothing is assumed about the noise:
/// - Each frame is compared with the picture of a moment before. In that
///   moment a start gets far, swaying and leaning hardly anywhere.
/// - How much each cell changes that way is learned from the whole rest
///   before the movement, which includes the swaying and the shaking there
///   was. A cell on a restless edge has to change more to count.
nonisolated enum MotionOnsetAnalyzer {
    /// How far before the confirmation the beginning is looked for; what
    /// lies before it is rest. A movement that takes longer to reach the
    /// pose threshold is unsteadiness (`MotionProfile.unsteadyDelay`).
    static let lookback: TimeInterval = 0.4

    /// How far back the picture lies that a frame is compared with. As long
    /// as a movement is younger than this, the comparison shows all of it;
    /// a start is found well within. Longer lets more swaying in.
    static let referenceLag: TimeInterval = 0.1

    /// That picture is the average of the frames in this stretch, to take
    /// the sensor noise out of it.
    static let referenceSpan: TimeInterval = 0.05

    /// The most rest that is looked at. Long enough for a slow sway to show
    /// its fastest part.
    static let restDuration: TimeInterval = 2

    /// Less rest than this says too little about how restless it is.
    static let minimumRest: TimeInterval = 0.2
    static let minimumRestFrames = 8

    /// A gap of more than this many usual frame distances ends the stretch
    /// that is looked at: before it the camera ran at another rate (idle is
    /// a quarter of the slowest precision rate), and frames at another rate
    /// change differently from one to the next. Two dropped frames in a row
    /// still pass.
    static let largestGap = 3.5

    /// How far above its resting level the change has to be, in standard
    /// deviations of that level, for the movement to be certain. High: a
    /// beginning found too early would make a legal start look false.
    static let certainFactor = 6.0

    /// Above this the picture no longer looks like rest. Directly before a
    /// certain movement that is most likely its beginning.
    static let beginningFactor = 3.0

    /// The least resting spread a cell is given, in brightness steps of
    /// 255: below one step the rounding of the cells is all there is.
    static let cellNoiseFloor: Float = 1

    /// The least rise that counts as certain, for pictures so clean that the
    /// resting level hardly varies. The change is 1 when every cell differs
    /// by its own resting spread.
    static let minimumRise = 0.2

    /// How long before a frame "just before" is. It begins far enough back
    /// that a start has risen clearly in between, and is short enough that
    /// swaying has hardly changed.
    static let recentPast: ClosedRange<TimeInterval> = 0.03...0.08

    /// The movement is also only certain where the change reaches this
    /// share of the most it reaches up to the confirmation. The change is a
    /// square, so this is a tenth of the difference in brightness.
    static let movementShare = 0.01

    struct Onset: Equatable, Sendable {
        /// After the last frame that still looked like rest, up to the
        /// first in which the movement was certain. Two frames that follow
        /// each other when the movement shows at once.
        let interval: TimeEstimate

        /// Frames missing between those two; they widen the interval.
        let droppedFrames: Int
    }

    /// How much each frame differs from the picture a moment before it,
    /// measured by what is usual at rest.
    struct Changes: Equatable, Sendable {
        /// The frames that were judged; the first ones of a stretch have no
        /// earlier picture to be compared with.
        let frames: [MotionSample]
        let values: [Double]
        /// How many of the frames, from the first, are rest.
        let restCount: Int
    }

    /// Nil if the samples don't allow a statement: too little rest at the
    /// rate of the confirmation, no change at the confirmation, or change
    /// all the way back.
    static func onset(in samples: [MotionSample], confirmedAt confirmation: MonotonicTimestamp) -> Onset? {
        guard let changes = changes(in: samples, confirmedAt: confirmation) else { return nil }

        let values = changes.values
        let resting = values.prefix(changes.restCount).sorted()
        let level = resting[resting.count / 2]
        let deviations = resting.map { abs($0 - level) }.sorted()
        let spread = madToStandardDeviation * deviations[deviations.count / 2]

        // Rest never rose further than to its own maximum either.
        let certainRise = max(certainFactor * spread, minimumRise, resting[resting.count - 1] - level)
        let beginningRise = max(beginningFactor * spread, minimumRise / 2)
        let certain = level + certainRise

        // Pose detection saw a movement here; the picture has to show one too.
        guard let last = values.indices.last, values[last] > certain else { return nil }

        // Rest can be livelier than the stretch of it that was seen. Next to
        // what a start does to the picture that is still little.
        let peak = values[changes.restCount...].max() ?? values[last]
        let sureLevel = max(certain, movementShare * peak)

        var sure = last
        while sure > 0, values[sure - 1] > sureLevel {
            sure -= 1
        }

        // Swaying that happens to be this lively leads into the start
        // without a gap. It changes slowly, the start doesn't: the movement
        // is where the change has risen above what it was just before.
        func recent(_ index: Int) -> Double {
            recentLevel(before: index, in: changes, atLeast: level)
        }

        while sure < last, values[sure] <= recent(sure) + certainRise {
            sure += 1
        }

        // Down the rise to its foot.
        var first = sure
        while first > 0, values[first - 1] > recent(first - 1) + beginningRise {
            first -= 1
        }

        // Different from rest ever since the resting stretch: no beginning in sight.
        guard first > changes.restCount else { return nil }

        let before = changes.frames[first - 1].time
        let certainBy = changes.frames[sure].time

        // The middle: a slow beginning leaves no better guess, and whoever
        // reads "best ± tolerance" is told the interval that was found.
        return Onset(
            interval: TimeEstimate(
                best: MonotonicTimestamp(seconds: (before.seconds + certainBy.seconds) / 2),
                earliest: before,
                latest: certainBy
            ),
            droppedFrames: droppedFrames(from: first - 1, to: sure, in: changes.frames)
        )
    }

    /// The usual change shortly before a frame, and never less than the
    /// resting level. Without frames in that stretch, the resting level.
    private static func recentLevel(before index: Int, in changes: Changes, atLeast level: Double) -> Double {
        let time = changes.frames[index].time.seconds
        var values: [Double] = []

        for earlier in changes.frames.indices.prefix(index).reversed() {
            let age = time - changes.frames[earlier].time.seconds

            guard age <= recentPast.upperBound else { break }

            if age >= recentPast.lowerBound {
                values.append(changes.values[earlier])
            }
        }
        values.sort()

        return values.isEmpty ? level : max(level, values[values.count / 2])
    }

    /// Turns the median of the absolute deviations into a standard
    /// deviation, for normally distributed values.
    private static let madToStandardDeviation = 1.4826

    /// Nil without enough rest before the lookback at the rate of the confirmation.
    static func changes(in samples: [MotionSample], confirmedAt confirmation: MonotonicTimestamp) -> Changes? {
        let frames = steadyStretch(of: samples, until: confirmation)

        guard let start = frames.first?.time.seconds,
              let firstJudged = frames.firstIndex(where: { $0.time.seconds - start >= referenceLag + referenceSpan }) else {
            return nil
        }

        let restEnd = confirmation.seconds - lookback
        let restCount = frames[firstJudged...].prefix { $0.time.seconds < restEnd }.count

        guard restCount >= minimumRestFrames,
              restEnd - frames[firstJudged].time.seconds >= minimumRest,
              firstJudged + restCount < frames.count else {
            return nil
        }

        let pictures = frames.map { vDSP.integerToFloatingPoint($0.cells, floatingPointType: Float.self) }
        let cellCount = pictures[0].count

        // The sum of the frames a moment before the one looked at; it moves along.
        var sum = [Float](repeating: 0, count: cellCount)
        var lower = 0
        var upper = 0

        let squares = (firstJudged..<frames.count).map { index -> [Float] in
            let time = frames[index].time.seconds

            while upper < index, frames[upper].time.seconds <= time - referenceLag {
                vDSP.add(sum, pictures[upper], result: &sum)
                upper += 1
            }
            // Where frames are missing, the last one before the lag stands in.
            while lower < upper - 1, frames[lower].time.seconds < time - referenceLag - referenceSpan {
                vDSP.subtract(sum, pictures[lower], result: &sum)
                lower += 1
            }

            var difference = vDSP.subtract(pictures[index], vDSP.divide(sum, Float(upper - lower)))

            // The overall brightness doesn't count, so flickering light or
            // a changing exposure isn't a movement.
            difference = vDSP.add(-vDSP.mean(difference), difference)
            return vDSP.square(difference)
        }

        // Each cell's own restlessness.
        var variance = [Float](repeating: 0, count: cellCount)
        for square in squares.prefix(restCount) {
            vDSP.add(variance, square, result: &variance)
        }
        variance = vDSP.add(cellNoiseFloor * cellNoiseFloor, vDSP.divide(variance, Float(restCount)))

        return Changes(
            frames: Array(frames[firstJudged...]),
            values: squares.map { Double(vDSP.mean(vDSP.divide($0, variance))) },
            restCount: restCount
        )
    }

    /// The frames up to the confirmation that arrived at its rate: back to
    /// the first gap that is too long, and no further than is looked at.
    static func steadyStretch(of samples: [MotionSample], until confirmation: MonotonicTimestamp) -> [MotionSample] {
        let reach = restDuration + lookback + referenceLag + referenceSpan

        let window = samples.filter {
            $0.time <= confirmation
                && confirmation.seconds - $0.time.seconds <= reach
                && $0.cells.count == samples.last?.cells.count
                && !$0.cells.isEmpty
        }

        let recent = window.drop { confirmation.seconds - $0.time.seconds > lookback }
        let usual = usualGap(in: Array(recent))

        guard usual > 0 else { return [] }

        var first = window.count - 1
        while first > 0, window[first].time.seconds - window[first - 1].time.seconds <= largestGap * usual {
            first -= 1
        }
        return Array(window[first...])
    }

    /// The median distance between frames; zero for fewer than two.
    private static func usualGap(in frames: [MotionSample]) -> TimeInterval {
        let gaps = zip(frames.dropFirst(), frames).map { $0.time.seconds - $1.time.seconds }.sorted()

        return gaps.isEmpty ? 0 : gaps[gaps.count / 2]
    }

    /// How many frames are missing between two of them, judged by the
    /// usual distance between frames.
    private static func droppedFrames(from first: Int, to last: Int, in frames: [MotionSample]) -> Int {
        let usual = usualGap(in: frames)

        guard usual > 0, first < last else { return 0 }

        return (first..<last).reduce(0) { missing, index in
            let gap = frames[index + 1].time.seconds - frames[index].time.seconds
            return missing + max(0, Int((gap / usual).rounded()) - 1)
        }
    }
}
