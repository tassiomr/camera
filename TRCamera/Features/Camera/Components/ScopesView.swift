import SwiftUI
import TRDesignSystem

// Channel colors (R, G, B, luma) are measurement conventions, not UI color,
// so they stay literal; everything around them comes from the theme.
struct HistogramView: View {
    @Environment(\.trTheme) private var theme
    var data: ScopeData

    var body: some View {
        Canvas { ctx, size in
            func curve(_ values: [Float]) -> Path {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: size.height))
                    for (i, v) in values.enumerated() {
                        let x = size.width * CGFloat(i) / CGFloat(max(1, values.count - 1))
                        p.addLine(to: CGPoint(x: x, y: size.height * (1 - CGFloat(v))))
                    }
                    p.addLine(to: CGPoint(x: size.width, y: size.height))
                    p.closeSubpath()
                }
            }
            ctx.blendMode = .plusLighter
            ctx.fill(curve(data.red), with: .color(.red.opacity(0.45)))
            ctx.fill(curve(data.green), with: .color(.green.opacity(0.45)))
            ctx.fill(curve(data.blue), with: .color(.blue.opacity(0.5)))
            ctx.blendMode = .normal
            ctx.stroke(curve(data.luma), with: .style(theme.colors.foreground.primary.opacity(0.85)), lineWidth: 1)
        }
        .background(theme.colors.surface.scrim)
        .overlay(alignment: .topTrailing) {
            if data.clippedFraction > 0.01 {
                TRBadge(verbatim: "CLIP", tone: .error, emphasis: .solid).padding(theme.spacing.xxxs)
            }
        }
        .clipShape(RoundedRectangle.tr(theme.shape.small))
        .accessibilityLabel("Histograma")
    }
}

struct WaveformView: View {
    @Environment(\.trTheme) private var theme
    var data: ScopeData

    var body: some View {
        let colors = theme.colors
        Canvas { ctx, size in
            let cols = ScopeData.waveColumns, rows = ScopeData.waveRows
            let cw = size.width / CGFloat(cols), rh = size.height / CGFloat(rows)
            for r in 0..<rows {
                for c in 0..<cols {
                    let v = data.waveform[r * cols + c]
                    guard v > 0.02 else { continue }
                    let rect = CGRect(x: CGFloat(c) * cw, y: size.height - CGFloat(r + 1) * rh, width: cw, height: rh)
                    ctx.fill(Path(rect), with: .style(colors.foreground.accent.opacity(Double(v))))
                }
            }
            for level in [0.1, 0.5, 0.9] {
                let y = size.height * (1 - level)
                ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                           with: .style(colors.foreground.primary.opacity(0.15)), lineWidth: 0.5)
            }
        }
        .background(colors.surface.scrim)
        .clipShape(RoundedRectangle.tr(theme.shape.small))
        .accessibilityLabel("Waveform de luminância")
    }
}

/// One DS level meter per channel (dBFS, peak hold, safe/hot/clip zones).
struct AudioMeterView: View {
    @Environment(\.trTheme) private var theme
    var average: [Float]
    var peak: [Float]

    var body: some View {
        HStack(spacing: theme.spacing.xxxs) {
            ForEach(Array(zip(average.indices, average)), id: \.0) { index, avg in
                TRAudioLevelMeter(level: avg, peak: index < peak.count ? peak[index] : avg, orientation: .vertical,
                                  segments: 20, label: "Nível de áudio, canal \(index + 1)")
            }
        }
    }
}
