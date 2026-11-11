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

/// The frame rate around the gun. It sets how finely the beginning of a
/// movement can be timed: the time between two frames is the least width
/// of that interval.
nonisolated enum CameraFrameRate: Int, Codable, CaseIterable, Sendable {
    /// For cameras that reach no more.
    case fps60 = 60
    case fps120 = 120
    /// Needs good light and warms the phone faster.
    case fps240 = 240
}
