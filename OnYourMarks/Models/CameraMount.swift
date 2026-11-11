//
//  CameraMount.swift
//  OnYourMarks
//

/// How the phone is held while it watches the athletes.
nonisolated enum CameraMount: String, Codable, CaseIterable, Sendable {
    /// Standing still: every movement in the picture is an athlete's.
    case tripod

    /// Held in the hand: the camera's own movement is taken out of the
    /// athletes'. Costs frames and is less precise than a tripod.
    case handheld
}
