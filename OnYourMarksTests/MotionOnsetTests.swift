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
    func theRecordsHoldEveryWatchedAthletesSamplesFromTheLeft() throws {
        var timeline = MotionTimeline()
        let left = AthleteID(), right = AthleteID(), unseen = AthleteID()
        timeline.setRegions([right: region.offsetBy(dx: 0.5, dy: 0), left: region, unseen: region.offsetBy(dx: 0.2, dy: 0)])

        timeline.append(sample(at: 1), for: right)
        timeline.append(sample(at: 1), for: left)
        timeline.append(sample(at: 2), for: left)

        #expect(timeline.records == [
            MotionRecord(athleteID: left, region: region, samples: [sample(at: 1), sample(at: 2)]),
            MotionRecord(athleteID: right, region: region.offsetBy(dx: 0.5, dy: 0), samples: [sample(at: 1)])
        ])

        let stored = try JSONDecoder().decode([MotionRecord].self, from: JSONEncoder().encode(timeline.records))
        #expect(stored == timeline.records)
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
    private static let cellCount = MotionSampler.gridSize * MotionSampler.gridSize

    /// What the camera sees of one athlete's region over a stretch of time.
    private struct Scene {
        var rate = 120.0
        /// From this frame on a growing part of the picture changes, up to half.
        var movingSince: Int?
        /// Frames that never arrived.
        var missing: Set<Int> = []
        /// Every other frame is brighter as a whole.
        var flickering = false
        /// How far the whole picture is shifted sideways at a time, in
        /// cells: an athlete swaying or a camera shaking.
        var shift: (TimeInterval) -> Double = { _ in 0 }

        func time(ofFrame frame: Int) -> MonotonicTimestamp {
            MonotonicTimestamp(seconds: 10 + Double(frame) / rate)
        }

        private func texture(_ cell: Int) -> Double {
            Double(60 + abs(cell * 37) % 120)
        }

        func cells(frame: Int) -> [UInt8] {
            let shift = shift(Double(frame) / rate)

            return (0..<cellCount).map { cell in
                // A shifted picture shows a share of each cell's neighbour.
                let neighbour = texture(cell + (shift < 0 ? -1 : 1))
                var value = texture(cell) + (neighbour - texture(cell)) * abs(shift)

                // A little noise that differs from frame to frame.
                value += Double((frame &* 31 &+ cell &* 17) % 3) - 1

                if flickering {
                    value += Double(frame % 2) * 12
                }

                // Never the whole picture: that would be a change of brightness.
                if let movingSince, frame >= movingSince, cell < min((frame - movingSince + 1) * 16, cellCount / 2) {
                    value += 50
                }
                return UInt8(clamping: Int(value.rounded()))
            }
        }

        func samples(_ frames: Range<Int>) -> [MotionSample] {
            frames.filter { !missing.contains($0) }.map { MotionSample(time: time(ofFrame: $0), cells: cells(frame: $0)) }
        }
    }

    /// The beginning of a movement that pose detection confirmed in the
    /// last frame.
    private func onset(in scene: Scene, frames: Int) -> MotionOnsetAnalyzer.Onset? {
        MotionOnsetAnalyzer.onset(in: scene.samples(0..<frames), confirmedAt: scene.time(ofFrame: frames - 1))
    }

    @Test(arguments: [60.0, 120.0, 240.0])
    func theBeginningLiesBetweenTheLastRestingFrameAndTheFirstMovingOne(rate: Double) throws {
        let begins = Int(rate * 0.8)
        let scene = Scene(rate: rate, movingSince: begins)

        let onset = try #require(onset(in: scene, frames: Int(rate)))

        #expect(onset.interval.earliest == scene.time(ofFrame: begins - 1))
        #expect(onset.interval.latest == scene.time(ofFrame: begins))
        #expect(onset.interval.best > onset.interval.earliest && onset.interval.best < onset.interval.latest)
        #expect(abs((onset.interval.latest.seconds - onset.interval.earliest.seconds) - 1 / rate) < 0.000_001)
        #expect(onset.droppedFrames == 0)
    }

    @Test
    func droppedFramesWidenTheInterval() throws {
        // The two frames before the first moving one never arrived.
        let scene = Scene(movingSince: 100, missing: [98, 99])

        let onset = try #require(onset(in: scene, frames: 125))

        #expect(onset.interval.earliest == scene.time(ofFrame: 97))
        #expect(onset.interval.latest == scene.time(ofFrame: 100))
        #expect(onset.droppedFrames == 2)
    }

    @Test
    func aDroppedFirstMovingFrameMovesTheLateEnd() throws {
        let scene = Scene(movingSince: 100, missing: [100])

        let onset = try #require(onset(in: scene, frames: 125))

        #expect(onset.interval.earliest == scene.time(ofFrame: 99))
        #expect(onset.interval.latest == scene.time(ofFrame: 101))
        #expect(onset.droppedFrames == 1)
    }

    @Test
    func flickeringLightIsNotABeginning() throws {
        let scene = Scene(movingSince: 100, flickering: true)

        let onset = try #require(onset(in: scene, frames: 125))

        #expect(onset.interval.earliest == scene.time(ofFrame: 99))
        #expect(onset.interval.latest == scene.time(ofFrame: 100))
    }

    /// A standing athlete sways the whole time. Against one resting picture
    /// that is a difference long before the start.
    @Test
    func aSwayingAthleteBeginsWithTheStart() throws {
        let scene = Scene(movingSince: 240) { 0.2 * sin(2 * .pi * 0.4 * $0) }

        let onset = try #require(onset(in: scene, frames: 265))

        // A restless picture can take a frame longer to make it certain.
        #expect(onset.interval.earliest == scene.time(ofFrame: 239))
        #expect(onset.interval.latest >= scene.time(ofFrame: 240))
        #expect(onset.interval.latest <= scene.time(ofFrame: 241))
    }

    /// Leaning forward before the start moves the picture ever further from
    /// where it was, without being the start.
    @Test
    func leaningSlowlyIsNotTheBeginning() throws {
        let scene = Scene(movingSince: 240) { 0.15 * $0 }

        let onset = try #require(onset(in: scene, frames: 265))

        #expect(onset.interval.earliest == scene.time(ofFrame: 239))
        #expect(onset.interval.latest == scene.time(ofFrame: 240))
    }

    @Test
    func aShakingCameraIsNotTheBeginning() throws {
        let scene = Scene(movingSince: 240) { 0.05 * sin(2 * .pi * 9 * $0) }

        let onset = try #require(onset(in: scene, frames: 265))

        #expect(onset.interval.earliest == scene.time(ofFrame: 239))
        #expect(onset.interval.latest == scene.time(ofFrame: 240))
    }

    /// The rest that was seen can be calmer than what comes right before
    /// the start. That is at most a wider interval, never a movement that
    /// was certain before it began.
    @Test
    func swayingThatPicksUpBeforeTheStartIsNotCertain() throws {
        let begins = 240
        // Ever faster: at the start half again as fast as rest ever was.
        let scene = Scene(movingSince: begins) { 0.4 * pow($0 / 2.2, 4) }

        let onset = try #require(onset(in: scene, frames: 265))

        #expect(onset.interval.latest >= scene.time(ofFrame: begins))
        #expect(onset.interval.latest <= scene.time(ofFrame: begins + 2))
    }

    @Test
    func framesAfterTheConfirmationAndLongBeforeItAreLeftOut() throws {
        // Three seconds at rest, then the movement; later frames don't matter.
        let scene = Scene(movingSince: 400)

        let onset = try #require(
            MotionOnsetAnalyzer.onset(in: scene.samples(0..<480), confirmedAt: scene.time(ofFrame: 420))
        )

        #expect(onset.interval.latest == scene.time(ofFrame: 400))

        let stretch = MotionOnsetAnalyzer.steadyStretch(of: scene.samples(0..<480), until: scene.time(ofFrame: 420))
        #expect(stretch.last?.time == scene.time(ofFrame: 420))
        #expect(scene.time(ofFrame: 420).seconds - (stretch.first?.time.seconds ?? 0) < 2.6)
    }

    /// The camera runs at the idle rate until shortly before the gun.
    /// Frames from then say nothing about how the picture changes from one
    /// precision frame to the next.
    @Test
    func onlyFramesAtTheRateOfTheConfirmationAreLookedAt() throws {
        let scene = Scene(movingSince: 220)
        // Every eighth frame is 15 a second.
        let idle = scene.samples(0..<120).enumerated().filter { $0.offset.isMultiple(of: 8) }.map { $0.element }
        let confirmation = scene.time(ofFrame: 244)

        let stretch = MotionOnsetAnalyzer.steadyStretch(of: idle + scene.samples(120..<245), until: confirmation)
        #expect(stretch.first?.time == scene.time(ofFrame: 120))

        let onset = try #require(MotionOnsetAnalyzer.onset(in: idle + scene.samples(120..<245), confirmedAt: confirmation))
        #expect(onset.interval.earliest == scene.time(ofFrame: 219))
        #expect(onset.interval.latest == scene.time(ofFrame: 220))

        // The precision rate began too shortly before the movement.
        let late = scene.samples(0..<180).enumerated().filter { $0.offset.isMultiple(of: 8) }.map { $0.element }
        #expect(MotionOnsetAnalyzer.onset(in: late + scene.samples(180..<245), confirmedAt: confirmation) == nil)
    }

    @Test
    func twoDroppedFramesInARowDoNotEndTheStretch() {
        let scene = Scene(missing: [60, 61])
        let stretch = MotionOnsetAnalyzer.steadyStretch(of: scene.samples(0..<120), until: scene.time(ofFrame: 119))

        #expect(stretch.first?.time == scene.time(ofFrame: 0))
    }

    /// Pose detection can be wrong about a movement; then the picture
    /// shows none.
    @Test
    func noStatementWithoutAChangeAtTheConfirmation() {
        #expect(onset(in: Scene(), frames: 125) == nil)
    }

    @Test
    func noStatementWhenThePictureChangedAllTheWayBack() {
        // The movement began before the stretch in which a beginning is looked for.
        #expect(onset(in: Scene(movingSince: 70), frames: 125) == nil)
    }

    @Test
    func noStatementFromTooFewFrames() {
        #expect(MotionOnsetAnalyzer.onset(in: [], confirmedAt: MonotonicTimestamp(seconds: 10)) == nil)

        // The athlete had only just become still: too little rest to compare with.
        #expect(onset(in: Scene(movingSince: 50), frames: 75) == nil)

        // At the idle rate the resting stretch holds only a few frames.
        #expect(onset(in: Scene(rate: 15, movingSince: 12), frames: 15) == nil)
    }

    @Test
    func theChangeAtRestIsLowAndOverallBrightnessDoesNotCount() throws {
        let scene = Scene(movingSince: 100)
        var samples = scene.samples(0..<125)

        let changes = try #require(MotionOnsetAnalyzer.changes(in: samples, confirmedAt: scene.time(ofFrame: 124)))
        let rest = changes.values.prefix(changes.restCount)

        #expect(changes.frames.last?.time == scene.time(ofFrame: 124))
        #expect(rest.allSatisfy { $0 < 1 })
        #expect(changes.values.last ?? 0 > 10)

        // One resting frame is brighter as a whole.
        let brightened = changes.frames.count - samples.count + 50
        samples[50] = MotionSample(time: samples[50].time, cells: samples[50].cells.map { $0 + 10 })

        let flashed = try #require(MotionOnsetAnalyzer.changes(in: samples, confirmedAt: scene.time(ofFrame: 124)))
        #expect(abs(flashed.values[brightened] - changes.values[brightened]) < 0.01)
    }
}
