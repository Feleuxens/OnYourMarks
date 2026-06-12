//
//  ConfigStore.swift
//  OnYourMarks
//
//  Created by Felix on 12.06.26.
//

import Foundation

struct ConfigStore {
    private let key = "starterConfig"

    func load() -> StartConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
              let config = try? JSONDecoder().decode(StartConfig.self, from: data)
        else {
            return .standard
        }
        return config
    }

    func save(_ config: StartConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
