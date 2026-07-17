//
//  CameraPlaceholder.swift
//  OnYourMarks
//
//  Created by Felix on 17.07.26.
//

import SwiftUI

struct CameraPlaceholder: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.graphite.opacity(0.25))

            VStack(spacing: 12) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 50))
            }
            .foregroundStyle(.chalk.opacity(0.7))
        }
    }
}
