import AVFoundation
import SwiftUI
import TRDesignSystem

/// Hosts the low-latency AVCaptureVideoPreviewLayer and, above it, the processed
/// monitoring layer (shown only when a tool that alters the image is active).
final class PreviewUIView: UIView {
    let previewLayer: AVCaptureVideoPreviewLayer
    let monitorView = MonitorLayerView()
    var onTap: ((CGPoint, CGPoint) -> Void)?
    var onPinch: ((CGFloat, UIGestureRecognizer.State) -> Void)?

    init(previewLayer: AVCaptureVideoPreviewLayer, metal: MTLDevice?) {
        self.previewLayer = previewLayer
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(previewLayer)
        monitorView.configure(device: metal)
        monitorView.isHidden = true
        addSubview(monitorView)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
        monitorView.frame = bounds
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        onTap?(p, previewLayer.captureDevicePointConverted(fromLayerPoint: p))
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        onPinch?(g.scale, g.state)
    }
}

struct PreviewContainer: UIViewRepresentable {
    let engine: ProfessionalCaptureEngine
    var showsProcessed: Bool
    var onTap: (CGPoint, CGPoint) -> Void
    var onPinch: (CGFloat, UIGestureRecognizer.State) -> Void

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView(previewLayer: engine.previewLayer, metal: engine.monitoring.metalDevice)
        engine.monitoring.setTarget(view.monitorView)
        return view
    }

    func updateUIView(_ view: PreviewUIView, context: Context) {
        view.monitorView.isHidden = !showsProcessed
        view.onTap = onTap
        view.onPinch = onPinch
    }
}

/// Composition guides drawn inside the real video rectangle.
struct GuidesOverlay: View {
    @Environment(\.trTheme) private var theme
    var settings: MonitoringSettings
    var videoAspect: CGFloat
    var roll: Double

    var body: some View {
        let c = theme.colors
        let line = c.foreground.primary
        GeometryReader { geo in
            let rect = Self.fit(aspect: videoAspect, in: geo.size)
            ZStack {
                if let ratio = settings.aspectGuide.ratio {
                    let inner = Self.fit(aspect: CGFloat(ratio), in: rect.size).offsetBy(dx: rect.minX, dy: rect.minY)
                    Path { p in p.addRect(rect); p.addRect(inner) }
                        .fill(c.surface.scrim, style: FillStyle(eoFill: true))
                    Path { $0.addRect(inner) }.stroke(c.foreground.accent.opacity(0.8), lineWidth: 1)
                }
                if settings.thirdsGrid {
                    Path { p in
                        for i in 1...2 {
                            let x = rect.minX + rect.width * CGFloat(i) / 3
                            let y = rect.minY + rect.height * CGFloat(i) / 3
                            p.move(to: CGPoint(x: x, y: rect.minY)); p.addLine(to: CGPoint(x: x, y: rect.maxY))
                            p.move(to: CGPoint(x: rect.minX, y: y)); p.addLine(to: CGPoint(x: rect.maxX, y: y))
                        }
                    }.stroke(line.opacity(0.28), lineWidth: 0.7)
                }
                if settings.safeAreas {
                    Path { $0.addRect(rect.insetBy(dx: rect.width * 0.05, dy: rect.height * 0.05)) }
                        .stroke(line.opacity(0.4), style: StrokeStyle(lineWidth: 0.8, dash: [6, 4]))
                    Path { $0.addRect(rect.insetBy(dx: rect.width * 0.1, dy: rect.height * 0.1)) }
                        .stroke(line.opacity(0.25), style: StrokeStyle(lineWidth: 0.8, dash: [3, 4]))
                }
                if settings.centerMark {
                    Path { p in
                        p.move(to: CGPoint(x: rect.midX - 12, y: rect.midY)); p.addLine(to: CGPoint(x: rect.midX + 12, y: rect.midY))
                        p.move(to: CGPoint(x: rect.midX, y: rect.midY - 12)); p.addLine(to: CGPoint(x: rect.midX, y: rect.midY + 12))
                    }.stroke(line.opacity(0.7), lineWidth: 1)
                }
                if settings.levelIndicator {
                    let level = abs(Self.levelError(roll)) < 0.6 * .pi / 180
                    Capsule()
                        .fill(level ? c.foreground.accent : line.opacity(0.75))
                        .frame(width: 90, height: 2)
                        .rotationEffect(.radians(-Self.levelError(roll)))
                        .position(x: rect.midX, y: rect.midY)
                }
                // Corner brackets like a viewfinder.
                Path { p in
                    let l: CGFloat = 18, r = rect.insetBy(dx: 8, dy: 8)
                    for (c, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                                        (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
                        p.move(to: CGPoint(x: c.x + l * dx, y: c.y)); p.addLine(to: c); p.addLine(to: CGPoint(x: c.x, y: c.y + l * dy))
                    }
                }.stroke(line.opacity(0.85), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
    }

    /// Roll relative to the nearest upright orientation (portrait or landscape).
    static func levelError(_ roll: Double) -> Double {
        let quarter = Double.pi / 2
        return roll - (roll / quarter).rounded() * quarter
    }

    static func fit(aspect: CGFloat, in size: CGSize) -> CGRect {
        guard aspect > 0, size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        let w = min(size.width, size.height * aspect)
        let h = w / aspect
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}
