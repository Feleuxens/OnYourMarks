//
//  IntervalTimer.swift
//  OnYourMarks
//
//  Created by Felix on 11.06.26.
//

import SwiftUI

struct DelaySlider: View {
    let title: String
    @Binding var time: Double
    let isRunning: Bool
    let range: ClosedRange<Double>
    let step: Double
    var isFocused: FocusState<Bool>.Binding
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                TextField("", value: $time, format: .number)
                    .keyboardType(.decimalPad)
                    .focused(isFocused)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 44)
                    .monospacedDigit()
                    .onTapGesture { isFocused.wrappedValue = true }
                Text("s").foregroundStyle(.secondary)
            }
            Slider(value: $time, in: range, step: step).tint(.signalYellow)
        }
    }
}


