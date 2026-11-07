import SwiftUI

struct HistogramView: View {
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
            ctx.stroke(curve(data.luma), with: .color(.white.opacity(0.85)), lineWidth: 1)
        }
        .background(Color.black.opacity(0.55))
        .overlay(alignment: .topTrailing) {
            if data.clippedFraction > 0.01 {
                Text("CLIP").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.recording).padding(3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Histograma")
    }
}

struct WaveformView: View {
    var data: ScopeData

    var body: some View {
        Canvas { ctx, size in
            let cols = ScopeData.waveColumns, rows = ScopeData.waveRows
            let cw = size.width / CGFloat(cols), rh = size.height / CGFloat(rows)
            for r in 0..<rows {
                for c in 0..<cols {
                    let v = data.waveform[r * cols + c]
                    guard v > 0.02 else { continue }
                    let rect = CGRect(x: CGFloat(c) * cw, y: size.height - CGFloat(r + 1) * rh, width: cw, height: rh)
                    ctx.fill(Path(rect), with: .color(Theme.accent.opacity(Double(v))))
                }
            }
            for level in [0.1, 0.5, 0.9] {
                let y = size.height * (1 - level)
                ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                           with: .color(.white.opacity(0.15)), lineWidth: 0.5)
            }
        }
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Waveform de luminância")
    }
}

struct AudioMeterView: View {
    var average: [Float]
    var peak: [Float]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(zip(average.indices, average)), id: \.0) { index, avg in
                let pk = index < peak.count ? peak[index] : avg
                GeometryReader { geo in
                    let h = geo.size.height
                    ZStack(alignment: .bottom) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule().fill(Self.color(for: pk)).frame(height: h * Self.normalized(avg))
                        Rectangle().fill(Self.color(for: pk)).frame(height: 2).offset(y: -h * Self.normalized(pk))
                    }
                }
                .frame(width: 4)
            }
        }
        .accessibilityLabel("Nível de áudio")
    }

    static func normalized(_ db: Float) -> CGFloat { CGFloat(min(max((db + 60) / 60, 0), 1)) }
    static func color(for peak: Float) -> Color { peak > -1 ? Theme.recording : (peak > -12 ? Theme.warning : Theme.accent) }
}
