//
//  CalibrationStore.swift
//  OnYourMarks
//

import Foundation
import OSLog

/// Keeps one calibration per output route.
struct CalibrationStore {
    private let key = "outputCalibrations"
    private let defaults: UserDefaults

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "OnYourMarks",
        category: "Config"
    )

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [String: OutputCalibration] {
        guard let data = defaults.data(forKey: key) else { return [:] }

        do {
            return try JSONDecoder().decode([String: OutputCalibration].self, from: data)
        } catch {
            logger.error("Could not decode calibrations: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    func save(_ calibrations: [String: OutputCalibration]) {
        do {
            defaults.set(try JSONEncoder().encode(calibrations), forKey: key)
        } catch {
            logger.error("Could not save calibrations: \(error.localizedDescription, privacy: .public)")
        }
    }
}
