//
//  IntervalTimer.swift
//  OnYourMarks
//
//  Created by Felix on 11.06.26.
//

import SwiftUI

struct DelaySlider: View {
    let id: UInt8
    let title: String
    @Binding var time: Double
    let isRunning: Bool
    let range: ClosedRange<Double>
    let step: Double
    var focusedSlider: FocusState<UInt8?>.Binding
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                HStack(spacing: 4) {
                    TextField("", value: $time, format: .number)
                        .keyboardType(.decimalPad)
                        .focused(focusedSlider, equals: id)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 44)
                        .monospacedDigit()
                    Text("s").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { focusedSlider.wrappedValue = id }
            }
            Slider(value: $time, in: range, step: step).tint(.signalYellow)
        }
    }
}


