//
//  WirelessOutputWarning.swift
//  OnYourMarks
//

import SwiftUI

/// Shown while the start would play on a wireless output. Its delay is
/// only estimated or calibrated once and can change while it plays, so
/// reaction times are less accurate than on a wired output; without a
/// calibration no false start is called with certainty.
struct WirelessOutputWarning: View {
    let outputName: String
    let isCalibrated: Bool
    
    var body: some View {
        Label {
            if isCalibrated {
                Text("\(outputName) is wireless. Its delay can change while it plays, so reaction times are less accurate. Use the iPhone speaker or a wired speaker for accurate results.")
            } else {
                Text("\(outputName) is wireless and isn't calibrated, so false-start detection will be inaccurate. Use the iPhone speaker or a wired speaker, or calibrate it in Settings.")
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.warmInk)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.signalYellow, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("wirelessOutputWarning")
    }
}

#Preview {
    VStack {
        WirelessOutputWarning(outputName: "AirPods Pro", isCalibrated: false)
        WirelessOutputWarning(outputName: "JBL Flip", isCalibrated: true)
    }
}
