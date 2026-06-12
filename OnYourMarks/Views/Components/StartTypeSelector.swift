//
//  StartTypeSelector.swift
//  OnYourMarks
//
//  Created by Felix on 11.06.26.
//

import SwiftUI

struct StartTypeSelector: View {
    @Binding var selection: StartType

    var body: some View {
        HStack(spacing: 12) {
            option(.block,    image: "figure.track.and.field",    label: "Block")
            option(.standing, image: "figure.run", label: "Hochstart")
        }
    }

    private func option(_ type: StartType, image: String, label: String) -> some View {
        Button {
            selection = type
        } label: {
            VStack(spacing: 8) {
                Image(systemName: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 40)
                Text(label)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(selection == type ? Color.accentColor.opacity(0.2)
                                            : Color.gray.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selection == type ? Color.chalk : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)   // sonst färbt SwiftUI das ganze Label blau
    }
}

#Preview {
    @Previewable @State var previewStartType: StartType = .block
    StartTypeSelector(selection: $previewStartType)
}
