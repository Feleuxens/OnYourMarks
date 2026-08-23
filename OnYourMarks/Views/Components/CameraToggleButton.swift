//
//  CameraToogleButton.swift
//  OnYourMarks
//
//  Created by Felix on 17.07.26.
//

import SwiftUI

struct CameraToggleButton: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "camera.fill" : "camera")
                Text(isOn ? "Detection on" : "Detection off")
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
