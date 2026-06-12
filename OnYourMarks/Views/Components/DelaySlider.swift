//
//  IntervalTimer.swift
//  OnYourMarks
//
//  Created by Felix on 11.06.26.
//

import SwiftUI

struct DelaySlider: View {
    @Binding var time: Double
    let isRunning: Bool
    let range: ClosedRange<Double>
    let step: Double
    var isFocused: FocusState<Bool>.Binding
    
    var body: some View {
        HStack {
            Slider(value: $time, in: range, step: step).tint(.signalYellow).disabled(isRunning)
            HStack(spacing: 4) {
                TextField("0.0", value: $time, format: .number)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.decimalPad)
                    .frame(width: 26)
                    .focused(isFocused)
                    .foregroundStyle(.warmInk)
                Text("s").foregroundStyle(.graphite)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.warmPaper))
            .contentShape(Rectangle())
            .onTapGesture { isFocused.wrappedValue = true }
            .opacity(!isRunning ? 1 : 0.5)
            
        }.padding(.horizontal, 14)
    }
}


