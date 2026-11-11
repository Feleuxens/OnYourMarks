//
//  RecordingStore.swift
//  OnYourMarks
//

import Foundation

/// Where recorded starts live on disk: one folder per start with the clean
/// video, the start's record and the tracking data, each in its own file.
///
/// The last start sits in the temporary directory until the next one
/// replaces it; saving moves its folder into the library.
nonisolated struct RecordingStore: Sendable {
    enum Location: Sendable {
        /// The last start. The system may clear it at any time.
        case temporary
        case library
    }

    static let videoFileName = "video.mov"
    static let recordFileName = "start.json"
    static let trackingFileName = "tracking.json"

    private let temporaryDirectory: URL
    private let libraryDirectory: URL

    init(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory.appending(path: "LastStart"),
        libraryDirectory: URL = URL.applicationSupportDirectory.appending(path: "Recordings")
    ) {
        self.temporaryDirectory = temporaryDirectory
        self.libraryDirectory = libraryDirectory
    }

    func directory(of id: UUID, in location: Location) -> URL {
        root(of: location).appending(path: id.uuidString)
    }

    func videoURL(of id: UUID, in location: Location) -> URL {
        directory(of: id, in: location).appending(path: Self.videoFileName)
    }

    /// The files of a recording, for handing them to another app.
    func files(of id: UUID, in location: Location) -> [URL] {
        [Self.videoFileName, Self.recordFileName, Self.trackingFileName]
            .map { directory(of: id, in: location).appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Makes an empty temporary folder for a new recording and returns
    /// where its video goes.
    func prepare(_ id: UUID) throws -> URL {
        let directory = directory(of: id, in: .temporary)

        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        return videoURL(of: id, in: .temporary)
    }

    /// Writes the record and the tracking data beside the temporary video.
    func write(_ recording: StartRecording, tracking: [TrackingFrame]) throws {
        let directory = directory(of: recording.id, in: .temporary)
        let encoder = JSONEncoder()

        try encoder.encode(recording).write(to: directory.appending(path: Self.recordFileName), options: .atomic)
        try encoder.encode(tracking).write(to: directory.appending(path: Self.trackingFileName), options: .atomic)
    }

    /// Every complete recording at the location, newest first. A folder
    /// without a readable record or without its video is passed over.
    func recordings(in location: Location) -> [StartRecording] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root(of: location),
            includingPropertiesForKeys: nil
        )) ?? []

        return folders
            .compactMap { folder -> StartRecording? in
                guard let data = try? Data(contentsOf: folder.appending(path: Self.recordFileName)),
                      let recording = try? JSONDecoder().decode(StartRecording.self, from: data),
                      FileManager.default.fileExists(atPath: videoURL(of: recording.id, in: location).path) else {
                    return nil
                }
                return recording
            }
            .sorted { $0.date > $1.date }
    }

    func tracking(of id: UUID, in location: Location) throws -> [TrackingFrame] {
        let data = try Data(contentsOf: directory(of: id, in: location).appending(path: Self.trackingFileName))
        return try JSONDecoder().decode([TrackingFrame].self, from: data)
    }

    /// Removes every temporary recording but the given ones.
    func keepOnly(_ ids: Set<UUID>) {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        )) ?? []

        let kept = Set(ids.map { $0.uuidString })

        for folder in folders where !kept.contains(folder.lastPathComponent) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Moves the temporary recording into the library.
    func save(_ id: UUID) throws {
        try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: directory(of: id, in: .temporary),
            to: directory(of: id, in: .library)
        )
    }

    func delete(_ id: UUID, in location: Location) {
        try? FileManager.default.removeItem(at: directory(of: id, in: location))
    }

    private func root(of location: Location) -> URL {
        switch location {
        case .temporary: temporaryDirectory
        case .library: libraryDirectory
        }
    }
}
