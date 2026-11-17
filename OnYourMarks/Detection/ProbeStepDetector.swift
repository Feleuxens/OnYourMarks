//
//  ProbeStepDetector.swift
//  OnYourMarks
//

import Accelerate
import CoreGraphics
import Foundation

/// A part of the picture the probe mode watches, e.g. where a light sits
/// that switches when it hears the gun.
nonisolated struct ProbeRegion: Identifiable, Equatable, Hashable, Codable, Sendable {
    let id: UUID

    /// In the upright normalized picture the athletes' regions use, y
    /// counted from the bottom.
    let rect: CGRect

    init(id: UUID = UUID(), rect: CGRect) {
        self.id = id
        self.rect = rect.standardized.intersection(Self.wholePicture)
    }

    static let wholePicture = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// Where the region's middle lies along the buffer's rows, from the
    /// first (0) to the last (1).
    ///
    /// A rolling shutter exposes the sensor's rows one after the other, so
    /// this is what a measured offset depends on, not the height in the
    /// upright picture: the buffer lies on its side (`MotionSampler.bufferRegion`),
    /// its first row is the picture's right edge. Two lights at the top and
    /// the bottom of the upright picture lie in the same rows; to measure
    /// the readout, put them at the left and the right edge. Which end the
    /// sensor reads first is for the measurement to show.
    var readoutPosition: Double {
        Double(1 - rect.midX)
    }
}

/// When a probed region changed, as two frames that follow each other.
nonisolated struct ProbeObservation: Equatable, Codable, Sendable {
    let regionID: UUID

    /// The region, with its position in the picture: the rolling shutter
    /// makes the offset depend on it.
    let region: CGRect

    /// See `ProbeRegion.readoutPosition`.
    let readoutPosition: Double

    /// From the last frame that looked like the frame before it to the
    /// first that differed. The middle is the best guess.
    let change: TimeEstimate

    /// The frame that made the change certain; the first that differed, or
    /// one after it when that one changed less.
    let certainAt: MonotonicTimestamp

    /// Frames missing between the two; they have widened the interval.
    let droppedFrames: Int

    /// How much the certain frame differed from the one before it: the
    /// mean absolute difference of the region's cells, in brightness steps
    /// of 255. Beside it what neighbouring frames differed at rest.
    let size: Double
    let restLevel: Double
    let restSpread: Double

    /// How much brighter the region got across the change, in brightness
    /// steps; negative when it got darker.
    let brightnessChange: Double
}

/// What a probe measured against the gun: the step nearest to it.
nonisolated struct ProbeResult: Equatable, Codable, Sendable {
    let observation: ProbeObservation

    /// The change's time minus the gun's heard time. Zero for a light that
    /// switches when the gun is heard and an app whose times are right.
    let offset: DurationEstimate

    /// For every region, the step nearest to the gun: a light that also
    /// switched at a command or a noise switched at other times as well.
    static func nearest(of steps: [ProbeObservation], to gun: TimeEstimate) -> [ProbeResult] {
        var nearest: [UUID: ProbeResult] = [:]
        var order: [UUID] = []

        for step in steps {
            let result = ProbeResult(observation: step, offset: step.change.duration(since: gun))

            guard let known = nearest[step.regionID] else {
                nearest[step.regionID] = result
                order.append(step.regionID)
                continue
            }

            if abs(result.offset.best) < abs(known.offset.best) {
                nearest[step.regionID] = result
            }
        }
        return order.compactMap { nearest[$0] }
    }
}

/// Finds steps in one region of the picture: frames that differ from the
/// one before them by far more than any two neighbouring frames did at rest.
///
/// A light switching on or off changes a region from one frame to the next
/// and then holds still; nothing at rest does that. So unlike the athletes'
/// onset analysis, which looks for the foot of a gradual rise and takes the
/// overall brightness out, this keeps the brightness (it is the signal) and
/// compares neighbouring frames only, which no slow drift of the light or
/// the exposure reaches.
///
/// It sees every frame, as it arrives: rest is what neighbouring frames
/// differed by in the stretch just before, a step is the first frame
/// certainly beyond that.
nonisolated struct ProbeStepDetector: Sendable {
    /// How far back rest reaches. Long enough to have seen what the camera
    /// does by itself (the recorded start at 240 fps shows a larger
    /// difference every fourth frame, a 60 Hz rhythm; room lights flicker
    /// at 100 Hz), short enough to follow an exposure that settles.
    static let restSpan: TimeInterval = 0.5

    /// Less rest than this says too little about it, as in the onset analysis.
    static let minimumRest: TimeInterval = MotionOnsetAnalyzer.minimumRest
    static let minimumRestFrames = MotionOnsetAnalyzer.minimumRestFrames

    /// How far above its resting level a frame's difference has to be, in
    /// standard deviations, for the change to be certain. As high as in
    /// the onset analysis; the difference must also exceed everything rest
    /// showed.
    static let certainFactor = MotionOnsetAnalyzer.certainFactor

    /// Above this a frame no longer looks like rest. Directly before a
    /// certain frame it is the beginning of the change: a frame that was
    /// exposed while the light switched changes partly.
    static let beginningFactor = MotionOnsetAnalyzer.beginningFactor

    /// The least step that is certain, in brightness steps of 255, for a
    /// picture so still that rest hardly varies: below one step the
    /// rounding of the cells is all there is.
    static let minimumStep = 1.0

    /// A gap of more than this many usual frame distances ends the stretch,
    /// as in the onset analysis: two dropped frames in a row still pass.
    static let largestGap = MotionOnsetAnalyzer.largestGap

    /// A gap shorter than the usual distance divided by this means the rate
    /// went up: from the idle rate to the precision rate it is a quarter or
    /// less. The exposure may change with the rate, so rest begins anew.
    static let fasterRate = 1.5

    /// The gaps the usual frame distance is taken from.
    private static let usualGapFrames = 16

    private static let madToStandardDeviation = 1.4826

    private var previous: MotionSample?
    private var gaps: [TimeInterval] = []

    /// Differences of neighbouring frames at rest, newest last.
    private var rest: [(time: MonotonicTimestamp, difference: Double)] = []

    /// Frames already past the beginning level, not yet certain: the last
    /// frame at rest before them and the first of them.
    private var rising: (before: MotionSample, first: MotionSample, dropped: Int)?
    private var risingDifferences: [(time: MonotonicTimestamp, difference: Double)] = []

    /// A reported change goes on until a frame is calm again; it is one change.
    private var isChanging = false

    /// Takes the next frame; returns a change once it is certain. The
    /// samples must be of one region and come in the order of their times.
    mutating func process(_ sample: MotionSample) -> Step? {
        defer { previous = sample }

        guard let previous, previous.cells.count == sample.cells.count, !sample.cells.isEmpty else {
            restart()
            return nil
        }

        let gap = sample.time.seconds - previous.time.seconds
        let usual = usualGap

        if let usual, gap > Self.largestGap * usual || gap < usual / Self.fasterRate {
            restart()
            return nil
        }

        gaps.append(gap)
        if gaps.count > Self.usualGapFrames {
            gaps.removeFirst()
        }

        let difference = Self.difference(between: previous.cells, and: sample.cells)
        rest.removeAll { sample.time.seconds - $0.time.seconds > Self.restSpan }

        guard let span = rest.first.map({ sample.time.seconds - $0.time.seconds }),
              rest.count >= Self.minimumRestFrames,
              span >= Self.minimumRest else {
            rest.append((sample.time, difference))
            return nil
        }

        let levels = rest.map { $0.difference }.sorted()
        let level = levels[levels.count / 2]
        let spread = Self.madToStandardDeviation * levels.map { abs($0 - level) }.sorted()[levels.count / 2]

        let certain = max(level + Self.certainFactor * spread, levels[levels.count - 1], level + Self.minimumStep)
        let beginning = max(level + Self.beginningFactor * spread, level + Self.minimumStep / 2)

        guard difference > beginning else {
            // A rise that never became certain was part of rest after all,
            // like the rhythm of the recorded start.
            if !isChanging {
                rest += risingDifferences
            }
            rising = nil
            risingDifferences = []
            isChanging = false
            rest.append((sample.time, difference))
            return nil
        }

        let droppedHere = max(0, Int((gap / (usual ?? gap)).rounded()) - 1)
        let start = rising ?? (before: previous, first: sample, dropped: droppedHere)
        rising = start
        risingDifferences.append((sample.time, difference))

        guard difference > certain, !isChanging else { return nil }

        isChanging = true

        return Step(
            change: TimeEstimate(
                best: MonotonicTimestamp(seconds: (start.before.time.seconds + start.first.time.seconds) / 2),
                earliest: start.before.time,
                latest: start.first.time
            ),
            certainAt: sample.time,
            droppedFrames: start.dropped,
            size: difference,
            restLevel: level,
            restSpread: spread,
            brightnessChange: Self.mean(of: sample.cells) - Self.mean(of: start.before.cells)
        )
    }

    struct Step: Equatable, Sendable {
        let change: TimeEstimate
        let certainAt: MonotonicTimestamp
        let droppedFrames: Int
        let size: Double
        let restLevel: Double
        let restSpread: Double
        let brightnessChange: Double
    }

    /// The median of the recent gaps; nil before there are two.
    private var usualGap: TimeInterval? {
        guard gaps.count >= 2 else { return nil }
        let sorted = gaps.sorted()
        return sorted[sorted.count / 2]
    }

    /// Frames from before a gap or a change of rate aren't compared with later ones.
    private mutating func restart() {
        gaps = []
        rest = []
        rising = nil
        risingDifferences = []
        isChanging = false
    }

    /// The mean absolute difference of two grids, in brightness steps.
    static func difference(between a: [UInt8], and b: [UInt8]) -> Double {
        let first = vDSP.integerToFloatingPoint(a, floatingPointType: Float.self)
        let second = vDSP.integerToFloatingPoint(b, floatingPointType: Float.self)
        return Double(vDSP.meanMagnitude(vDSP.subtract(second, first)))
    }

    private static func mean(of cells: [UInt8]) -> Double {
        Double(vDSP.mean(vDSP.integerToFloatingPoint(cells, floatingPointType: Float.self)))
    }
}

nonisolated extension ProbeObservation {
    init(_ step: ProbeStepDetector.Step, in region: ProbeRegion) {
        self.init(
            regionID: region.id,
            region: region.rect,
            readoutPosition: region.readoutPosition,
            change: step.change,
            certainAt: step.certainAt,
            droppedFrames: step.droppedFrames,
            size: step.size,
            restLevel: step.restLevel,
            restSpread: step.restSpread,
            brightnessChange: step.brightnessChange
        )
    }
}
