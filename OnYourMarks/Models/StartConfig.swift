//
//  StartConfig.swift
//  OnYourMarks
//
//  Created by Felix on 11.06.26.
//

struct StartConfig: Codable {
    var sliderReadyClamp: Double = 20
    var timeToReady: Double = 5 {
        didSet { timeToReady = timeToReady.clamped(to: 0...sliderReadyClamp) }
    }
    
    var sliderSetClamp: Double = 30
    var timeToSet: Double = 10 {
        didSet { timeToSet = timeToSet.clamped(to: 0...sliderSetClamp) }
    }
    
    var sliderStartMinClamp: Double = 10
    var timeToStartMin: Double = 2 {
        didSet { timeToStartMin = timeToStartMin.clamped(to: 0...sliderStartMinClamp) }
    }
    
    var sliderStartMaxClamp: Double = 10
    var timeToStartMax: Double = 5 {
        didSet { timeToStartMax = timeToStartMax.clamped(to: 0...sliderStartMaxClamp) }
    }
    
    var startType: StartType = StartType.block
    
    static let standard = StartConfig()
    
    
    init() {}
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StartConfig.standard   // Defaults as fallback

        startType      = try c.decodeIfPresent(StartType.self,  forKey: .startType)      ?? d.startType
        timeToReady    = try c.decodeIfPresent(Double.self,     forKey: .timeToReady)    ?? d.timeToReady
        timeToSet      = try c.decodeIfPresent(Double.self,     forKey: .timeToSet)      ?? d.timeToSet
        timeToStartMin = try c.decodeIfPresent(Double.self,     forKey: .timeToStartMin) ?? d.timeToStartMin
        timeToStartMax = try c.decodeIfPresent(Double.self,     forKey: .timeToStartMax) ?? d.timeToStartMax
    }
    
}
extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(range.upperBound, max(self, range.lowerBound))
    }
}
