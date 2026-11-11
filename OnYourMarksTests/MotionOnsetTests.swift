//
//  MotionOnsetTests.swift
//  OnYourMarksTests
//

import CoreVideo
import Foundation
import Testing
import Vision
@testable import OnYourMarks

struct MotionSamplerTests {
    /// A buffer whose brightness is given per pixel.
    private func buffer(
        width: Int,
        height: Int,
        format: OSType = kCVPixelFormatType_OneComponent8,
        brightness: (Int, Int) -> UInt8
    ) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, format, nil, &created)
        let buffer = try #require(created)

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let isPlanar = CVPixelBufferGetPlaneCount(buffer) > 0
        let base = try #require(isPlanar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer))
            .assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = isPlanar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)

        for y in 0..<height {
            for x in 0..<width {
                base[y * bytesPerRow + x] = brightness(x, y)
            }
        }
        return buffer
    }

    @Test
    func theRegionSurroundsTheJointsWithAMargin() throws {
        let region = try #require(
            MotionSampler.region(around: [.neck: CGPoint(x: 0.4, y: 0.6), .root: CGPoint(x: 0.5, y: 0.4)])
        )

        #expect(abs(region.minX - (0.4 - 0.1 * MotionSampler.regionPadding)) < 0.000_001)
        #expect(abs(region.maxX - (0.5 + 0.1 * MotionSampler.regionPadding)) < 0.000_001)
        #expect(abs(region.minY - (0.4 - 0.2 * MotionSampler.regionPadding)) < 0.000_001)
        #expect(abs(region.maxY - (0.6 + 0.2 * MotionSampler.regionPadding)) < 0.000_001)
    }

    @Test
    func theRegionStaysInsideThePicture() throws {
        let region = try #require(
            MotionSampler.region(around: [.neck: CGPoint(x: 0.02, y: 0.99), .root: CGPoint(x: 0.3, y: 0.5)])
        )

        #expect(region.minX == 0)
        #expect(region.maxY == 1)
        #expect(MotionSampler.region(around: [:]) == nil)
    }

    /// The buffer lies on its side: the picture's top is its left, the
    /// picture's right its top.
    @Test
    func uprightRegionsAreTurnedIntoTheBuffer() {
        let region = MotionSampler.bufferRegion(
            for: CGRect(x: 0.2, y: 0.5, width: 0.2, height: 0.4), bufferWidth: 1920, bufferHeight: 1080
        )

        #expect(abs(region.minX - 192) < 0.001)
        #expect(abs(region.width - 768) < 0.001)
        #expect(abs(region.minY - 648) < 0.001)
        #expect(abs(region.height - 216) < 0.001)
    }

    @Test(arguments: [kCVPixelFormatType_OneComponent8, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
    func cellsAreTheAverageBrightnessOfTheirPartOfTheRegion(format: OSType) throws {
        // Dark on the left, bright on the right, and something else outside the region.
        let picture = try buffer(width: 400, height: 240, format: format) { x, y in
            guard (100..<300).contains(x), (40..<200).contains(y) else { return 77 }
            return x < 200 ? 20 : 220
        }

        let cells = try #require(MotionSampler.cells(of: picture, in: CGRect(x: 100, y: 40, width: 200, height: 160)))
        let size = MotionSampler.gridSize

        // The scaling smooths the edge between the halves, so the cells
        // next to it are left out.
        #expect(cells.count == size * size)
        #expect((0..<size).allSatisfy { row in
            (0..<size / 2 - 2).allSatisfy { abs(Int(cells[row * size + $0]) - 20) <= 2 }
                && (size / 2 + 2..<size).allSatisfy { abs(Int(cells[row * size + $0]) - 220) <= 2 }
        })
    }

    @Test
    func aRegionReachingOutOfTheBufferIsCutOff() throws {
        let picture = try buffer(width: 200, height: 100) { _, _ in 90 }

        let cells = try #require(MotionSampler.cells(of: picture, in: CGRect(x: 150, y: -50, width: 200, height: 100)))
        #expect(cells.allSatisfy { abs(Int($0) - 90) <= 1 })

        #expect(MotionSampler.cells(of: picture, in: CGRect(x: 300, y: 0, width: 50, height: 50)) == nil)
    }

    @Test
    func aPictureWithoutABrightnessPlaneIsNotSampled() throws {
        var created: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &created)

        #expect(MotionSampler.cells(of: try #require(created), in: CGRect(x: 0, y: 0, width: 64, height: 64)) == nil)
    }
}

struct MotionTimelineTests {
    private func sample(at seconds: TimeInterval) -> MotionSample {
        MotionSample(time: MonotonicTimestamp(seconds: seconds), cells: [1, 2, 3])
    }

    private let region = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.5)

    @Test
    func onlyWatchedAthletesAreKept() {
        var timeline = MotionTimeline()
        let watched = AthleteID(), other = AthleteID()
        timeline.setRegions([watched: region])

        timeline.append(sample(at: 1), for: watched)
        timeline.append(sample(at: 1), for: other)

        #expect(timeline.samples(for: watched).count == 1)
        #expect(timeline.samples(for: other).isEmpty)
    }

    @Test
    func oldSamplesAreDropped() {
        var timeline = MotionTimeline()
        let athlete = AthleteID()
        timeline.setRegions([athlete: region])

        for step in 0..<100 {
            timeline.append(sample(at: Double(step) * 0.1), for: athlete)
        }

        let kept = timeline.samples(for: athlete)
        #expect(kept.last?.time.seconds == 9.9)
        #expect(abs((kept.first?.time.seconds ?? 0) - (9.9 - MotionTimeline.retention)) < 0.051)
    }

    @Test
    func aChangedOrRemovedRegionStartsAfresh() {
        var timeline = MotionTimeline()
        let moved = AthleteID(), kept = AthleteID(), gone = AthleteID()
        timeline.setRegions([moved: region, kept: region, gone: region])

        for athlete in [moved, kept, gone] {
            timeline.append(sample(at: 1), for: athlete)
        }

        timeline.setRegions([moved: region.offsetBy(dx: 0.1, dy: 0), kept: region])

        #expect(timeline.samples(for: moved).isEmpty)
        #expect(timeline.samples(for: kept).count == 1)
        #expect(timeline.samples(for: gone).isEmpty)

        timeline.reset()
        #expect(timeline.regions.isEmpty)
        #expect(timeline.samples(for: kept).isEmpty)
    }
}

struct MotionOnsetAnalyzerTests {
    private let cellCount = MotionSampler.gridSize * MotionSampler.gridSize

    /// A textured picture with a little noise that differs from frame to
    /// frame. From `movingSince` on, a growing part of it changes, up to half.
    private func cells(frame: Int, movingSince: Int? = nil, flicker: Int = 0) -> [UInt8] {
        (0..<cellCount).map { cell in
            var value = 60 + (cell * 37) % 120
            value += ((frame &* 31 &+ cell &* 17) % 3) - 1
            value += flicker

            // Never the whole picture: that would be a change of brightness.
            if let movingSince, frame >= movingSince, cell < min((frame - movingSince + 1) * 80, cellCount / 2) {
                value += 50
            }
            return UInt8(clamping: value)
        }
    }

    /// Frames at a steady rate; `missing` ones never arrived.
    private func samples(
        count: Int,
        rate: Double = 120,
        movingSince: Int? = nil,
        missing: Set<Int> = [],
        flickering: Bool = false
    ) -> [MotionSample] {
        (0..<count).filter { !missing.contains($0) }.map { frame in
            MotionSample(
                time: MonotonicTimestamp(seconds: 10 + Double(frame) / rate),
                cells: cells(frame: frame, movingSince: movingSince, flicker: flickering ? (frame % 2) * 12 : 0)
            )
        }
    }

    private func time(ofFrame frame: Int, rate: Double = 120) -> MonotonicTimestamp {
        MonotonicTimestamp(seconds: 10 + Double(frame) / rate)
    }

    @Test(arguments: [60.0, 120.0, 240.0])
    func theBeginningLiesBetweenTheLastRestingFrameAndTheFirstMovingOne(rate: Double) throws {
        let count = Int(rate * 0.8)
        let begins = Int(rate * 0.6)
        let recorded = samples(count: count, rate: rate, movingSince: begins)

        let onset = try #require(
            MotionOnsetAnalyzer.onset(in: recorded, confirmedAt: time(ofFrame: count - 1, rate: rate))
        )

        #expect(onset.interval.earliest == time(ofFrame: begins - 1, rate: rate))
        #expect(onset.interval.latest == time(ofFrame: begins, rate: rate))
        #expect(onset.interval.best > onset.interval.earliest && onset.interval.best < onset.interval.latest)
        #expect(abs((onset.interval.latest.seconds - onset.interval.earliest.seconds) - 1 / rate) < 0.000_001)
        #expect(onset.droppedFrames == 0)
    }

    @Test
    func droppedFramesWidenTheInterval() throws {
        // The two frames before the first moving one never arrived.
        let recorded = samples(count: 100, movingSince: 70, missing: [68, 69])

        let onset = try #require(MotionOnsetAnalyzer.onset(in: recorded, confirmedAt: time(ofFrame: 99)))

        #expect(onset.interval.earliest == time(ofFrame: 67))
        #expect(onset.interval.latest == time(ofFrame: 70))
        #expect(onset.droppedFrames == 2)
    }

    @Test
    func aDroppedFirstMovingFrameMovesTheLateEnd() throws {
        let recorded = samples(count: 100, movingSince: 70, missing: [70])

        let onset = try #require(MotionOnsetAnalyzer.onset(in: recorded, confirmedAt: time(ofFrame: 99)))

        #expect(onset.interval.earliest == time(ofFrame: 69))
        #expect(onset.interval.latest == time(ofFrame: 71))
        #expect(onset.droppedFrames == 1)
    }

    @Test
    func flickeringLightIsNotABeginning() throws {
        let recorded = samples(count: 100, movingSince: 70, flickering: true)

        let onset = try #require(MotionOnsetAnalyzer.onset(in: recorded, confirmedAt: time(ofFrame: 99)))

        #expect(onset.interval.latest == time(ofFrame: 70))
    }

    @Test
    func framesAfterTheConfirmationAndBeforeTheLookbackAreLeftOut() throws {
        // Three seconds at rest, then the movement; later frames don't matter.
        let recorded = samples(count: 480, movingSince: 400)

        let onset = try #require(MotionOnsetAnalyzer.onset(in: recorded, confirmedAt: time(ofFrame: 420)))

        #expect(onset.interval.latest == time(ofFrame: 400))
    }

    @Test
    func noStatementWithoutADifferenceAtTheConfirmation() {
        #expect(MotionOnsetAnalyzer.onset(in: samples(count: 100), confirmedAt: time(ofFrame: 99)) == nil)
    }

    @Test
    func noStatementWhenThePictureNeverShowedRest() {
        let recorded = samples(count: 100, movingSince: 5)

        #expect(MotionOnsetAnalyzer.onset(in: recorded, confirmedAt: time(ofFrame: 99)) == nil)
    }

    @Test
    func noStatementFromTooFewFrames() {
        #expect(MotionOnsetAnalyzer.onset(in: [], confirmedAt: time(ofFrame: 0)) == nil)

        // The athlete had only just become still: too little rest to compare with.
        let recorded = samples(count: 12, movingSince: 6)
        #expect(MotionOnsetAnalyzer.onset(in: recorded, confirmedAt: time(ofFrame: 11)) == nil)

        // At the idle rate the resting stretch holds only a few frames.
        let slow = samples(count: 15, rate: 15, movingSince: 12)
        #expect(MotionOnsetAnalyzer.onset(in: slow, confirmedAt: time(ofFrame: 14, rate: 15)) == nil)
    }

    @Test
    func overallBrightnessDoesNotCountAsDifference() {
        let rest = cells(frame: 0)
        let reference = rest.map { Double($0) - rest.reduce(0.0) { $0 + Double($1) } / Double(rest.count) }

        #expect(MotionOnsetAnalyzer.difference(of: rest.map { $0 + 10 }, from: reference) < 0.000_001)
        #expect(MotionOnsetAnalyzer.difference(of: cells(frame: 0, movingSince: 0), from: reference) > 1)
    }
}
