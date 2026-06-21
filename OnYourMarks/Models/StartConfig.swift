//
//  StartConfig.swift
//  OnYourMarks
//
//  Created by Felix on 11.06.26.
//

struct StartConfig: Codable {
    var sliderReadyClamp: Double = 20
    var blockTimeToReady: Double = 2 {
        didSet { blockTimeToReady = blockTimeToReady.clamped(to: 0...sliderReadyClamp) }
    }
    var standingTimeToReady: Double = 2 {
        didSet { standingTimeToReady = standingTimeToReady.clamped(to: 0...sliderReadyClamp) }
    }
    
    var sliderSetClamp: Double = 30
    var blockTimeToSet: Double = 12 {
        didSet { blockTimeToSet = blockTimeToSet.clamped(to: 0...sliderSetClamp) }
    }
    
    var sliderStartMinClamp: Double = 10
    var blockTimeToStartMin: Double = 1 {
        didSet { blockTimeToStartMin = blockTimeToStartMin.clamped(to: 0...sliderStartMinClamp) }
    }
    var standingTimeToStartMin: Double = 1 {
        didSet { standingTimeToStartMin = standingTimeToStartMin.clamped(to: 0...sliderStartMinClamp) }
    }
    
    var sliderStartMaxClamp: Double = 10
    var blockTimeToStartMax: Double = 2 {
        didSet { blockTimeToStartMax = blockTimeToStartMax.clamped(to: 0...sliderStartMaxClamp) }
    }
    var standingTimeToStartMax: Double = 2 {
        didSet { standingTimeToStartMax = standingTimeToStartMax.clamped(to: 0...sliderStartMaxClamp) }
    }
    
    var startType: StartType = StartType.block
    var soundTheme: SoundTheme = SoundTheme.eng1
    
    static let standard = StartConfig()
    
    
    init() {}
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StartConfig.standard   // Defaults as fallback

        startType = try c.decodeIfPresent(StartType.self, forKey: .startType) ?? d.startType
        
        blockTimeToReady = try c.decodeIfPresent(Double.self, forKey: .blockTimeToReady) ?? d.blockTimeToReady
        blockTimeToSet = try c.decodeIfPresent(Double.self, forKey: .blockTimeToSet) ?? d.blockTimeToSet
        blockTimeToStartMin = try c.decodeIfPresent(Double.self, forKey: .blockTimeToStartMin) ?? d.blockTimeToStartMin
        blockTimeToStartMax = try c.decodeIfPresent(Double.self, forKey: .blockTimeToStartMax) ?? d.blockTimeToStartMax
        
        standingTimeToReady = try c.decodeIfPresent(Double.self, forKey: .standingTimeToReady) ?? d.standingTimeToReady
        standingTimeToStartMin = try c.decodeIfPresent(Double.self, forKey: .standingTimeToStartMin) ?? d.standingTimeToStartMin
        standingTimeToStartMax = try c.decodeIfPresent(Double.self, forKey: .standingTimeToStartMax) ?? d.standingTimeToStartMax
        
        soundTheme = try c.decodeIfPresent(SoundTheme.self, forKey: .soundTheme) ?? d.soundTheme
    }
    
}
extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(range.upperBound, max(self, range.lowerBound))
    }
}
