//
//  ConfigStore.swift
//  OnYourMarks
//
//  Created by Felix on 12.06.26.
//

import Foundation
import OSLog

struct ConfigStore {
    private let key = "starterConfig"
    private let defaults: UserDefaults
    
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "OnYourMarks",
        category: "Config"
    )
    
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> StartConfig {
        guard let data = defaults.data(forKey: key) else {
            return .standard
        }
        
        do {
            return try JSONDecoder().decode(StartConfig.self, from: data)
        } catch {
            logger.error(
                "Could not decode configuration: \(error.localizedDescription, privacy: .public)"
            )
            return .standard
        }
    }

    func save(_ config: StartConfig) {
        do {
            let data = try JSONEncoder().encode(config)
            defaults.set(data, forKey: key)
        } catch {
            logger.error("Could not save configuration: \(error.localizedDescription, privacy: .public)")
        }
    }
}
