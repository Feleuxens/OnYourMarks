//
//  FalseStartBanner.swift
//  OnYourMarks
//

import SwiftUI

/// Names the athletes who false-started, by the numbers the preview shows
/// above them.
struct FalseStartBanner: View {
    /// Empty if the detector couldn't tell the athletes apart.
    let positions: [Int]
    
    var body: some View {
        Group {
            switch positions.count {
            case 0:
                Text("False start")
            case 1:
                Text("False start: athlete \(positions[0]) from the left")
            default:
                Text("False start: athletes \(positions.map { $0.formatted() }.formatted(.list(type: .and))) from the left")
            }
        }
        .font(.headline)
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.red, in: Capsule())
        .accessibilityIdentifier("falseStartBanner")
    }
}
