//
//  ResetButton.swift
//  OnYourMarks
//
//  Created by Felix on 12.06.26.
//

import SwiftUI

struct ResetButton: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.chalk)
                .frame(width: 48, height: 48)
                .background(Color.graphite.opacity(0.25), in: Circle())
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }
}
