//
//  SecondPassFieldTests.swift
//  OnYourMarksTests
//

import CoreGraphics
import CoreVideo
import Foundation
import Testing
import Vision
@testable import OnYourMarks

extension VideoRecordingTests {
/// The second pass over every recorded start in `TEST_RUNNER_FIELD_DATA`,
/// and what the compressed video does to the onset analysis. Each test
/// reports its numbers as an attachment; the expectations only hold what
/// must be true of any recording. Among the suites that use the video
/// encoder: decoding a whole recording keeps the simulator busy for minutes.
struct SecondPassFieldTests {
    private static let gunLookaround: ClosedRange<TimeInterval> = -0.1...0.25

    private func starts() throws -> [RecordedStart] {
        let folders = RecordedStart.folders(in: try #require(FieldDataReplayTests.fieldData))
        try #require(!folders.isEmpty)
        return try folders.map(RecordedStart.load(from:))
    }

    private func ms(_ seconds: TimeInterval) -> String {
        String(format: "%+.1f ms", seconds * 1000)
    }

    /// What Vision says about one decoded frame, error included: `PoseTracker`
    /// passes errors over.
    private func poseDiagnosis(of start: RecordedStart, at time: TimeInterval) async throws -> String {
        struct Diagnosed: Error {}
        var diagnosis = "no frame"

        do {
            _ = try await RecordedVideoReader.read(start.videoURL, frameTimes: start.recording.frameTimes) { picture, frameTime in
                guard frameTime.seconds >= time else { return }

                let request = VNDetectHumanBodyPoseRequest()
                do {
                    try picture.withUnsafeBuffer { try VNImageRequestHandler(cvPixelBuffer: $0, orientation: .right).perform([request]) }
                    diagnosis = "\(request.results?.count ?? 0) bodies, no error"
                } catch {
                    diagnosis = "error: \(error)"
                }
                throw Diagnosed()
            }
        } catch is Diagnosed {}
        return diagnosis
    }

    @Test(.enabled(if: FieldDataReplayTests.hasFieldData))
    func theSecondPassRunsOverEveryRecordedStart() async throws {
        for start in try starts() {
            let recording = start.recording
            let name = start.directory.lastPathComponent
            let analysis = try #require(try await SecondPassAnalyser().analyse(start))
            let gun = StartReplay.gun(in: recording.session)?.heard.best.seconds ?? 0

            #expect(analysis.frames.decoded == recording.frameTimes.count, "\(name)")
            #expect(analysis.frames.unmatched == 0, "\(name)")

            let livePosed = start.tracking.count { frame in frame.athletes.contains { $0.isVisible } }
            var lines = [
                name,
                "frames: \(recording.frameTimes.count) recorded, \(analysis.frames.decoded) decoded, \(analysis.frames.unmatched) unmatched",
                "frames with a pose: live \(livePosed) of \(start.tracking.count) analysed, second pass \(analysis.frames.withPose)",
                String(format: "second pass took %.1f s (this machine, not the device)", analysis.duration),
                "times from the gun's heard time",
            ]

            for athlete in analysis.athletes {
                let live = recording.results.first { $0.athleteID == athlete.athleteID }
                let movement = start.recording.session.events.first {
                    if case .movementObserved = $0.kind { $0.athleteID == athlete.athleteID } else { false }
                }

                func interval(_ estimate: TimeEstimate?) -> String {
                    estimate.map { "\(ms($0.earliest.seconds - gun)) … \(ms($0.latest.seconds - gun))" } ?? "none"
                }
                func duration(_ estimate: DurationEstimate?) -> String {
                    estimate.map { "\(ms($0.best)) (\(ms($0.earliest)) … \(ms($0.latest)), width \(ms($0.width)))" } ?? "none"
                }

                lines += [
                    "athlete \(athlete.position): \(athlete.posedFrames) frames with a pose since the last rest",
                    "  poses:    live \(interval(movement?.time)), second pass \(interval(athlete.poseMovement))",
                    "  pixels:   live \(interval(live?.isRefined == true ? live?.movement : nil)), second pass \(interval(athlete.onset?.onset)), \(athlete.onset?.droppedFrames ?? 0) dropped",
                    "  reaction: live \(duration(live?.reaction))",
                    "            second pass \(duration(athlete.reaction))",
                    "  decision: live \(live.map { "\($0.decision)" } ?? "none"), second pass \(athlete.decision.map { "\($0)" } ?? "none")",
                ]
                if let change = athlete.change {
                    lines.append(
                        String(
                            format: "  change: %d frames, %d at rest, resting level %.3f, spread %.3f, certain above %.3f, peak %.1f",
                            change.values.count, change.restCount, change.levels.resting, change.levels.spread,
                            change.levels.certain, change.values.max() ?? 0
                        )
                    )
                }
                if let parameters = athlete.parameters {
                    lines.append(String(format: "  rest learned over %.2f s, looked %.2f s back", parameters.restDuration, parameters.lookback))
                }

                // Where pose detection works, the second pass sees the athlete.
                if analysis.frames.withPose > 0 {
                    #expect(athlete.posedFrames > 0, "\(name)")
                }
            }

            if analysis.frames.withPose == 0 {
                lines.append("pose detection on the frame at the gun: " + (try await poseDiagnosis(of: start, at: gun)))
            }

            Attachment.record(lines.joined(separator: "\n"), named: "Second pass \(name)")
        }
    }

    /// The live grids were sampled from the camera's buffers; the second
    /// pass samples the compressed video. How far apart are they, and what
    /// does that do to the change and to the onset found?
    @Test(.enabled(if: FieldDataReplayTests.hasFieldData))
    func gridsFromTheVideoAgainstTheLiveOnes() async throws {
        for start in try starts() {
            let name = start.directory.lastPathComponent

            for record in start.motion {
                let wanted = Set(record.samples.map { $0.time })
                var decoded: [MonotonicTimestamp: [UInt8]] = [:]

                _ = try await RecordedVideoReader.read(start.videoURL, frameTimes: start.recording.frameTimes) { picture, time in
                    guard wanted.contains(time) else { return }
                    decoded[time] = picture.withUnsafeBuffer { buffer in
                        MotionSampler.cells(
                            of: buffer,
                            in: MotionSampler.bufferRegion(
                                for: record.region,
                                bufferWidth: CVPixelBufferGetWidth(buffer),
                                bufferHeight: CVPixelBufferGetHeight(buffer)
                            )
                        )
                    }
                }

                // Cell by cell.
                var differences: [Double] = []
                var frameMeans: [Double] = []
                var largest = 0
                for sample in record.samples {
                    guard let cells = decoded[sample.time] else { continue }
                    let frame = zip(sample.cells, cells).map { Double(Int($0) - Int($1)) }
                    differences += frame
                    frameMeans.append(frame.reduce(0, +) / Double(frame.count))
                    largest = max(largest, frame.map { Int(abs($0)) }.max() ?? 0)
                }
                let count = Double(max(differences.count, 1))
                let meanAbsolute = differences.map(abs).reduce(0, +) / count
                let rms = (differences.map { $0 * $0 }.reduce(0, +) / count).squareRoot()
                let bias = differences.reduce(0, +) / count
                // Without each frame's overall brightness, which the analysis takes out.
                var centred: [Double] = []
                var index = 0
                for sample in record.samples where decoded[sample.time] != nil {
                    let mean = frameMeans[index]
                    centred += zip(sample.cells, decoded[sample.time]!).map { Double(Int($0) - Int($1)) - mean }
                    index += 1
                }
                let centredRMS = (centred.map { $0 * $0 }.reduce(0, +) / Double(max(centred.count, 1))).squareRoot()

                let videoSamples = record.samples.compactMap { sample in decoded[sample.time].map { MotionSample(time: sample.time, cells: $0) } }
                #expect(videoSamples.count == record.samples.count, "\(name)")

                var lines = [
                    "\(name), athlete \(start.recording.session.roster?.position(of: record.athleteID) ?? 0)",
                    "\(record.samples.count) live samples, \(videoSamples.count) found in the video",
                    String(
                        format: "cells (0…255): mean |live − video| %.2f, RMS %.2f, mean live − video %+.2f, largest %d, RMS without each frame's brightness %.2f",
                        meanAbsolute, rms, bias, largest, centredRMS
                    ),
                ]

                // The change signal and the onset from each.
                let confirmation = start.recording.session.events.first {
                    if case .movementObserved = $0.kind { $0.athleteID == record.athleteID } else { false }
                }?.time.latest

                if let confirmation,
                   let live = MotionOnsetAnalyzer.series(in: record.samples, until: confirmation),
                   let video = MotionOnsetAnalyzer.series(in: videoSamples, until: confirmation) {
                    let gun = StartReplay.gun(in: start.recording.session)?.heard.best.seconds ?? 0
                    let liveOnset = MotionOnsetAnalyzer.onset(in: record.samples, confirmedAt: confirmation)
                    let videoOnset = MotionOnsetAnalyzer.onset(in: videoSamples, confirmedAt: confirmation)
                    let restRatio = zip(live.values.prefix(live.restCount), video.values.prefix(video.restCount))
                        .map { $1 / max($0, 0.000_001) }.sorted()
                    let movingRatio = zip(live.values.dropFirst(live.restCount), video.values.dropFirst(video.restCount))
                        .map { $1 / max($0, 0.000_001) }.sorted()

                    lines += [
                        String(
                            format: "change, live: resting %.3f, spread %.3f, certain above %.3f, at confirmation %.1f",
                            live.levels.resting, live.levels.spread, live.levels.certain, live.values.last ?? 0
                        ),
                        String(
                            format: "change, video: resting %.3f, spread %.3f, certain above %.3f, at confirmation %.1f",
                            video.levels.resting, video.levels.spread, video.levels.certain, video.values.last ?? 0
                        ),
                        String(
                            format: "video / live, median: %.3f at rest, %.3f in the last 0.4 s",
                            restRatio.isEmpty ? 0 : restRatio[restRatio.count / 2],
                            movingRatio.isEmpty ? 0 : movingRatio[movingRatio.count / 2]
                        ),
                        "onset from live grids:  " + (liveOnset.map { "\(ms($0.interval.earliest.seconds - gun)) … \(ms($0.interval.latest.seconds - gun))" } ?? "none"),
                        "onset from video grids: " + (videoOnset.map { "\(ms($0.interval.earliest.seconds - gun)) … \(ms($0.interval.latest.seconds - gun))" } ?? "none"),
                    ]
                    lines.append("frame  from gun   live change   video change")
                    for (index, time) in live.times.enumerated() where time.seconds - gun > 0.2 && time.seconds - gun < 0.31 {
                        lines.append(String(format: "%4d  %+7.1f ms  %10.2f  %10.2f", index, (time.seconds - gun) * 1000, live.values[index], video.values[index]))
                    }
                }

                Attachment.record(lines.joined(separator: "\n"), named: "Grids \(name)")
            }
        }
    }

    /// Whether the picture changes when the gun sounds, before any athlete
    /// could react: the phone's speaker may shake the phone. Measured on
    /// the whole picture and on what lies beside the athletes.
    @Test(.enabled(if: FieldDataReplayTests.hasFieldData))
    func thePictureAroundTheGun() async throws {
        for start in try starts() {
            let name = start.directory.lastPathComponent
            guard let gun = StartReplay.gun(in: start.recording.session)?.heard else { continue }

            let athleteRegions = start.motion.map { $0.region }
            let left = athleteRegions.map { $0.minX }.min() ?? 0.5
            let right = athleteRegions.map { $0.maxX }.max() ?? 0.5
            var regions: [(String, CGRect)] = [("whole picture", CGRect(x: 0, y: 0, width: 1, height: 1))]
            if left > 0.1 {
                regions.append(("left of the athletes", CGRect(x: 0, y: 0, width: left, height: 1)))
            }
            if right < 0.9 {
                regions.append(("right of the athletes", CGRect(x: right, y: 0, width: 1 - right, height: 1)))
            }
            regions += start.motion.map { ("athlete region", $0.region) }

            var samples: [[MotionSample]] = Array(repeating: [], count: regions.count)
            _ = try await RecordedVideoReader.read(start.videoURL, frameTimes: start.recording.frameTimes) { picture, time in
                guard time.seconds > gun.best.seconds - 2.5, time.seconds < gun.best.seconds + 0.5 else { return }

                picture.withUnsafeBuffer { buffer in
                    let width = CVPixelBufferGetWidth(buffer)
                    let height = CVPixelBufferGetHeight(buffer)

                    for (index, region) in regions.enumerated() {
                        if let cells = MotionSampler.cells(
                            of: buffer,
                            in: MotionSampler.bufferRegion(for: region.1, bufferWidth: width, bufferHeight: height)
                        ) {
                            samples[index].append(MotionSample(time: time, cells: cells))
                        }
                    }
                }
            }

            var lines = [
                name,
                String(format: "gun heard %.6f (± %.1f ms), times below from its best value", gun.best.seconds, (gun.latest.seconds - gun.best.seconds) * 1000),
                "rest ends 50 ms before the gun; 'certain' and 'foot' as the onset analysis defines them",
            ]

            // Rest ends shortly before the gun; the curve runs past it.
            let end = MonotonicTimestamp(seconds: gun.best.seconds + Self.gunLookaround.upperBound)
            var parameters = MotionOnsetAnalyzer.Parameters.live
            parameters.lookback = Self.gunLookaround.upperBound + 0.05

            var curves: [(String, MotionOnsetAnalyzer.ChangeSeries)] = []
            for (index, region) in regions.enumerated() {
                guard let series = MotionOnsetAnalyzer.series(in: samples[index], until: end, parameters: parameters) else {
                    lines.append("\(region.0): no series")
                    continue
                }
                curves.append((region.0, series))

                let levels = series.levels
                let firstCertain = series.values.indices.first { $0 >= series.restCount && series.values[$0] > levels.certain }
                var foot = firstCertain
                while let current = foot, current > series.restCount,
                      series.values[current - 1] > levels.resting + levels.beginningRise {
                    foot = current - 1
                }
                let peak = series.values.indices.dropFirst(series.restCount).max { series.values[$0] < series.values[$1] }

                lines.append(
                    String(
                        format: "%@: resting %.3f, spread %.3f, certain above %.3f; ",
                        region.0, levels.resting, levels.spread, levels.certain
                    )
                    + "first certain " + (firstCertain.map { ms(series.times[$0].seconds - gun.best.seconds) } ?? "none")
                    + ", its foot after " + (foot.map { $0 > 0 ? ms(series.times[$0 - 1].seconds - gun.best.seconds) : "none" } ?? "none")
                    + ", peak " + (peak.map { String(format: "%.2f at %@", series.values[$0], ms(series.times[$0].seconds - gun.best.seconds)) } ?? "none")
                )
            }

            if let first = curves.first {
                lines.append("frame from gun  " + curves.map { $0.0 }.joined(separator: " | "))
                for time in first.1.times where Self.gunLookaround.contains(time.seconds - gun.best.seconds) {
                    let values = curves.map { curve in
                        curve.1.times.firstIndex(of: time).map { String(format: "%8.2f", curve.1.values[$0]) } ?? "       -"
                    }
                    lines.append(String(format: "%+8.1f ms  ", (time.seconds - gun.best.seconds) * 1000) + values.joined(separator: "   "))
                }
            }

            Attachment.record(lines.joined(separator: "\n"), named: "Around the gun \(name)")
        }
    }
}
}
