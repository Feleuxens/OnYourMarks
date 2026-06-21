//
//  TrackBackground.swift
//  OnYourMarks
//
//  Created by Felix on 12.06.26.
//

import SwiftUI

struct TrackBackground: View {
    var body: some View {
        LinearGradient(colors: [.trackOrange, .trackFlame, .trackRed],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(alignment: .bottom) {
                TrackLanes()
                    .stroke(.white.opacity(0.12),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(height: 200)
            }
            .ignoresSafeArea()
            .opacity(0.9)
    }
}

struct TrackLanes: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for i in 0..<4 {
            let y = rect.height * (0.05 + 0.3 * Double(i))  // three lanes, heights
            let dip = rect.height * 0.16  // curved
            path.move(to: CGPoint(x: -20, y: y))
            path.addQuadCurve(
                to: CGPoint(x: rect.width + 20, y: y),
                control: CGPoint(x: rect.width / 2, y: y - dip))
        }
        return path
    }
}
