//! The live waveform, shared by the app and the keyboard. Like the desktop
//! pill: a row of bars driven by the input level, with a little jitter so
//! it reads as a voice and not a meter.

import SwiftUI

struct Waveform: View {
    var level: Float
    var bars: Int = 14
    var color: Color = .primary

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<bars, id: \.self) { i in
                    let phase = sin(t * 7 + Double(i) * 0.9) * 0.5 + 0.5
                    let shape = 0.35 + 0.65 * sin(Double(i + 1) / Double(bars + 1) * .pi)
                    let h = 0.12 + Double(level) * shape * (0.55 + 0.45 * phase)
                    Capsule()
                        .fill(color)
                        .frame(width: 3)
                        .frame(maxHeight: .infinity)
                        .scaleEffect(x: 1, y: min(1, h), anchor: .center)
                }
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}

enum Palette {
    static let record = Color(red: 1.0, green: 0.27, blue: 0.23)   // #FF453A
    static let ok = Color(red: 0.19, green: 0.82, blue: 0.35)      // #30D158
    static let warn = Color(red: 0.90, green: 0.64, blue: 0.24)    // #E6A23C
    static let accent = Color("AccentColor")
}
