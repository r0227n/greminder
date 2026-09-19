import SwiftUI

/// A scrolling window of microphone measurements. Silence keeps the dotted baseline visible.
struct VoiceWaveformView: View {
    let levels: [Float]

    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 3.5
            let barWidth: CGFloat = 1.2
            let count = max(1, Int(size.width / spacing))
            let visible = levels.suffix(count)
            let emptyCount = count - visible.count
            var bars = Path()
            for index in 0 ..< count {
                let level = index < emptyCount ? 0 : CGFloat(visible[visible.startIndex + index - emptyCount])
                let height = max(1.5, min(1, max(0, level)) * (size.height - 8))
                let x = size.width - CGFloat(count - index) * spacing
                bars.addRoundedRect(
                    in: CGRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height),
                    cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2),
                )
            }
            context.fill(bars, with: .color(.red))
        }
        .accessibilityHidden(true)
    }
}
