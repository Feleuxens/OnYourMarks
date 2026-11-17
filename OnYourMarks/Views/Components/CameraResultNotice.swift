//
//  CameraResultNotice.swift
//  OnYourMarks
//

import SwiftUI

/// Shown with the result of a start when the camera did not deliver what
/// the times rely on: the precision rate, or frames after the gun.
struct CameraResultNotice: View {
    /// What the precision window delivered, if it fell short.
    let shortfall: PrecisionRateDelivery?
    let failedAfterTheGun: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let shortfall {
                let delivered = Int((shortfall.deliveredFrameRate ?? 0).rounded())
                let requested = Int(shortfall.requestedFrameRate.rounded())

                notice(Text("The camera delivered \(delivered) of \(requested) frames per second, so the movement times are less precise."))
            }

            if failedAfterTheGun {
                notice(Text("The camera stopped after the gun. Athletes without a time could not be judged."))
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.warmInk)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.signalYellow, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("cameraResultNotice")
    }

    private func notice(_ text: Text) -> some View {
        Label {
            text
        } icon: {
            Image(systemName: "camera.badge.ellipsis")
        }
    }
}

#Preview {
    CameraResultNotice(
        shortfall: PrecisionRateDelivery(
            requestedFrameRate: 120,
            deliveredFrameRate: 15,
            frames: 30,
            dropped: 0,
            longestGap: 0.067,
            exposureDurations: nil,
            isoValues: nil
        ),
        failedAfterTheGun: true
    )
}
