//
//  CameraStateReport.swift
//  OnYourMarks
//

import Foundation
import StateReporting

/// Identifies a camera state together with its label.
@ReportableMetadata
nonisolated struct CameraStateMetadata {
    let width: Int
    let height: Int
    let frameRate: Double
}

/// Context that changes within a state.
@ReportableMetadata
nonisolated struct CameraConditionMetadata {
    let pressure: Int
    let droppedFrames: Int
}

/// Reports the camera's state to the system's state reporting, so hangs,
/// heat and energy use can be attributed to what the camera was doing.
///
/// Only called on state changes: the system rate-limits anything faster
/// than user interaction.
nonisolated struct CameraStateReport: Sendable {
    private let reporter = StateReporter.reporter(
        for: "\(Bundle.main.bundleIdentifier ?? "OnYourMarks").camera",
        stableMetadata: CameraStateMetadata.self,
        volatileMetadata: CameraConditionMetadata.self
    )

    /// A nil label means the camera is off.
    func transition(
        to label: String?,
        format: CameraFormatDescriptor?,
        frameRate: Double,
        pressure: CameraPressureLevel,
        droppedFrames: Int
    ) {
        reporter.reportTransition(
            to: label,
            stableMetadata: format.map {
                CameraStateMetadata(width: $0.width, height: $0.height, frameRate: frameRate)
            },
            volatileMetadata: CameraConditionMetadata(pressure: pressure.rawValue, droppedFrames: droppedFrames)
        )
    }

    func update(pressure: CameraPressureLevel, droppedFrames: Int) {
        reporter.reportVolatileMetadataUpdate(
            CameraConditionMetadata(pressure: pressure.rawValue, droppedFrames: droppedFrames)
        )
    }
}
