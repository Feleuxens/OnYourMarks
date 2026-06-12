//
//  SoundTheme.swift
//  OnYourMarks
//
//  Created by Felix on 12.06.26.
//

enum SoundTheme: String {
    case eng1
    
    var displayName: String {
        switch self {
        case .eng1:
            return "English 1"
        }
    }
    
    func assetName(for signal: Signal) -> String {
        switch self {
        case .eng1:
            switch signal {
                case .onYourMarks: return "eng1-onyourmarks"
                case .set: return "eng1-set"
                case .go: return "eng1-gun"
            }
        }
    }
}
