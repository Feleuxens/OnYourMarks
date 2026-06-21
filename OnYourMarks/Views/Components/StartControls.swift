//
//  StartControls.swift
//  OnYourMarks
//
//  Created by Felix on 12.06.26.
//

import SwiftUI

struct StartControls: View {
    let isRunning: Bool
    let onStart: () -> Void
    let onAbort: () -> Void

    var body: some View {
        if isRunning {
            Button("Abbrechen", action: onAbort)
                .buttonStyle(PillButtonStyle(fill: .secondary, text: .chalk))
        } else {
            Button("Start", action: onStart)
                .buttonStyle(PillButtonStyle(fill: .signalYellow))
        }
    }
}


struct PillButtonStyle: ButtonStyle {
    var fill: Color
    var text: Color = .warmInk

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .bold()
            .padding()
            .frame(minWidth: 120)
            .foregroundStyle(text)
            .background(fill, in: RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.8 : 1)   // Press feedback
    }
}
