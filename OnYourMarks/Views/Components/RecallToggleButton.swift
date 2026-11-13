//
//  RecallToggleButton.swift
//  OnYourMarks
//

import SwiftUI

/// Whether a false start is shot back. It is measured either way.
struct RecallToggleButton: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "arrow.uturn.backward.circle.fill" : "arrow.uturn.backward.circle")
                isOn ? Text("Recall on") : Text("Recall off")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isOn ? .warmInk : .chalk)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                isOn ? Color.signalYellow : Color.chalk.opacity(0.2),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }
}
