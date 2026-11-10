//
//  UncalibratedOutputWarning.swift
//  OnYourMarks
//

import SwiftUI

/// Shown while the start would play on a wireless output without calibration.
struct UncalibratedOutputWarning: View {
    let outputName: String
    
    var body: some View {
        Label {
            Text("\(outputName) isn't calibrated, so false-start detection will be inaccurate. Calibrate it in Settings.")
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.warmInk)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.signalYellow, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("uncalibratedOutputWarning")
    }
}

#Preview {
    UncalibratedOutputWarning(outputName: "AirPods Pro")
}
