//
//  FieldRecordingTests.swift
//  OnYourMarksTests
//

import CoreGraphics
import Foundation
import Testing
@testable import OnYourMarks

/// Runs the starts recorded on the device through today's code. Opt-in:
/// set `TEST_RUNNER_FIELD_DATA` to a folder of recorded starts, or to one
/// (each with `start.json`, `tracking.json` and `motion.json`); the
/// simulator reads it from the Mac.
struct FieldRecordingTests {
    nonisolated static let folders = ProcessInfo.processInfo.environment["FIELD_DATA"]
        .map { RecordedStart.folders(in: URL(filePath: $0)) } ?? []
    nonisolated static let hasRecordings = !folders.isEmpty

    private func load<Value: Decodable>(_ type: Value.Type, from name: String, in folder: URL) throws -> Value {
        try JSONDecoder().decode(type, from: Data(contentsOf: folder.appending(path: name)))
    }

    @Test(.enabled(if: hasRecordings), arguments: folders)
    func theStoredFilesStillDecode(folder: URL) throws {
        let recording = try load(StartRecording.self, from: "start.json", in: folder)
        let tracking = try load([TrackingFrame].self, from: "tracking.json", in: folder)
        let motion = try load([MotionRecord].self, from: "motion.json", in: folder)

        #expect(!recording.frameTimes.isEmpty)
        #expect(!tracking.isEmpty)
        #expect(!motion.isEmpty)
    }

    /// Feeds every analysed pose of the recording to the monitor as the
    /// detector did, and reports when the movement crossed the threshold
    /// (where one pose used to confirm it) and when a second pose confirmed it.
    @Test(.enabled(if: hasRecordings), arguments: folders)
    func replayingThePosesConfirmsTheMovementOneFrameLater(folder: URL) throws {
        let recording = try load(StartRecording.self, from: "start.json", in: folder)
        let tracking = try load([TrackingFrame].self, from: "tracking.json", in: folder).sorted { $0.time < $1.time }
        let session = recording.session

        let monitoringBegan = try #require(session.events.first { $0.kind == .monitoringStarted }).time.best
        let gun = try #require(ReplayTimeline.gun(in: session))
        let recorded = try #require(session.events.first { if case .movementObserved = $0.kind { true } else { false } })

        // The recording begins just after monitoring did; its first frame
        // shows the athletes the roster was made of.
        var monitor = AthleteMotionMonitor()
        let first = try #require(tracking.first { $0.time >= monitoringBegan })
        let roster = monitor.begin(with: first.athletes, profile: session.profile.motion)
        #expect(roster.entries.map { $0.id } == session.roster?.entries.map { $0.id })

        var confirmed: [MovementObservation] = []
        var unconfirmed: [UnconfirmedMovement] = []
        var unsteady: [MonotonicTimestamp] = []

        for frame in tracking where frame.time > first.time && confirmed.count < roster.entries.count {
            let events = monitor.process(
                frame.athletes,
                camera: .measured(frame.cameraOffset ?? .zero),
                at: frame.time
            )

            for event in events {
                switch event {
                case .movement(let observation):
                    confirmed.append(observation)
                case .movementUnconfirmed(let movement):
                    unconfirmed.append(movement)
                case .unsteady(let observation) where observation.time < gun.earliest:
                    // As the engine does before the gun.
                    unsteady.append(observation.time)
                    monitor.resettle(observation.athleteID)
                default:
                    break
                }
            }
        }

        let movement = try #require(confirmed.first)
        let wait = movement.confirmedAt.seconds - movement.time.seconds
        let framesBetween = tracking.filter { $0.time > movement.time && $0.time < movement.confirmedAt }.count

        Attachment.record(
            """
            gun heard: \(gun.best.seconds) (\(gun.earliest.seconds) to \(gun.latest.seconds))
            recorded movement: \(recorded.time.earliest.seconds) to \(recorded.time.latest.seconds)
            replayed crossing (one pose, the old rule): \(movement.time.seconds), \
            \((movement.time.seconds - gun.best.seconds) * 1000) ms after the gun
            replayed onset: \(movement.onset.earliest.seconds) to \(movement.onset.latest.seconds)
            confirmed by the next pose: \(movement.confirmedAt.seconds), \(wait * 1000) ms later, \
            \(framesBetween) analysed frames between
            unconfirmed crossings: \(unconfirmed.map { "\($0.time.seconds) \($0.reason)" })
            unsteady before the gun: \(unsteady.map(\.seconds))
            """,
            named: "Replayed trigger"
        )

        // The movement keeps the time the recording gave it; only the report waits.
        #expect(movement.onset == recorded.time)
        #expect(movement.confirmedAt > movement.time)
        #expect(wait <= AthleteMotionMonitor.confirmationWait)
    }
}
