//
//  StartConfig.swift
//  OnYourMarks
//
//  Created by Felix on 11.06.26.
//

struct StartConfig: Codable {
    static let readyRange: ClosedRange<Double> = 0...20
    static let setRange: ClosedRange<Double> = 0...30
    static let startRange: ClosedRange<Double> = 0...10
    
    var blockTimeToReady: Double = 2 {
        didSet { blockTimeToReady = blockTimeToReady.clamped(to: Self.readyRange) }
    }
    var standingTimeToReady: Double = 2 {
        didSet { standingTimeToReady = standingTimeToReady.clamped(to: Self.readyRange) }
    }
    
    var blockTimeToSet: Double = 12 {
        didSet { blockTimeToSet = blockTimeToSet.clamped(to: Self.setRange) }
    }
    
    var blockTimeToStartMin: Double = 1 {
        didSet {
            blockTimeToStartMin = blockTimeToStartMin.clamped(to: Self.startRange)
        }
    }
    var standingTimeToStartMin: Double = 1 {
        didSet {
            standingTimeToStartMin = standingTimeToStartMin.clamped(to: Self.startRange)
        }
    }
    
    var blockTimeToStartMax: Double = 2 {
        didSet {
            blockTimeToStartMax = blockTimeToStartMax.clamped(to: Self.startRange)
        }
    }
    var standingTimeToStartMax: Double = 2 {
        didSet {
            standingTimeToStartMax = standingTimeToStartMax.clamped(to: Self.startRange)
        }
    }
    
    var startType: StartType = StartType.block
    var soundTheme: SoundTheme = SoundTheme.eng1
    
    static let standard = StartConfig()
    
    
    init() {}
    
    private enum CodingKeys: String, CodingKey {
        case blockTimeToReady, standingTimeToReady, blockTimeToSet, blockTimeToStartMin, blockTimeToStartMax, standingTimeToStartMin, standingTimeToStartMax, startType, soundTheme
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = StartConfig.standard   // Defaults as fallback

        startType = try container.decodeIfPresent(StartType.self, forKey: .startType) ?? defaults.startType
        
        blockTimeToReady = try container.decodeIfPresent(Double.self, forKey: .blockTimeToReady) ?? defaults.blockTimeToReady
        blockTimeToSet = try container.decodeIfPresent(Double.self, forKey: .blockTimeToSet) ?? defaults.blockTimeToSet
        blockTimeToStartMin = try container.decodeIfPresent(Double.self, forKey: .blockTimeToStartMin) ?? defaults.blockTimeToStartMin
        blockTimeToStartMax = try container.decodeIfPresent(Double.self, forKey: .blockTimeToStartMax) ?? defaults.blockTimeToStartMax
        
        standingTimeToReady = try container.decodeIfPresent(Double.self, forKey: .standingTimeToReady) ?? defaults.standingTimeToReady
        standingTimeToStartMin = try container.decodeIfPresent(Double.self, forKey: .standingTimeToStartMin) ?? defaults.standingTimeToStartMin
        standingTimeToStartMax = try container.decodeIfPresent(Double.self, forKey: .standingTimeToStartMax) ?? defaults.standingTimeToStartMax
        
        soundTheme = try container.decodeIfPresent(SoundTheme.self, forKey: .soundTheme) ?? defaults.soundTheme
        
        normalize()
    }
    
    private mutating func normalize() {
        blockTimeToReady =
            blockTimeToReady.clamped(to: Self.readyRange)

        standingTimeToReady =
            standingTimeToReady.clamped(to: Self.readyRange)

        blockTimeToSet =
            blockTimeToSet.clamped(to: Self.setRange)

        blockTimeToStartMin =
            blockTimeToStartMin.clamped(to: Self.startRange)

        blockTimeToStartMax =
            blockTimeToStartMax.clamped(to: Self.startRange)

        standingTimeToStartMin =
            standingTimeToStartMin.clamped(to: Self.startRange)

        standingTimeToStartMax =
            standingTimeToStartMax.clamped(to: Self.startRange)
    }
}
extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(range.upperBound, max(self, range.lowerBound))
    }
}
