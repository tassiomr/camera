import SwiftUI
import TRDesignSystem

// Camera-specific pieces built only from TR Design System tokens. The theme is
// chosen once, here, and applied in `TRCameraApp`; no view names a theme.
// Everything over the live preview renders in dark mode (see `CameraScreen`);
// sheets follow the system.

extension TRTheme {
    /// The app's theme: the single identity shared by every TR app.
    static let app = TRTheme.luminousStudio
}

extension TRColors {
    /// Recording state (REC dot, record button, preview outline), from the
    /// theme's `recording` token. Falls back to the destructive action color
    /// for themes that don't declare one.
    var recording: TRColorToken { custom["recording"] ?? action.destructive }
}

extension TRIcon {
    static let lookFilter = TRIcon("lookFilter", systemName: "camera.filters")
    static let presets = TRIcon("presets", systemName: "square.stack.3d.up")
    static let beat = TRIcon("beat", systemName: "metronome")
    static let zebra = TRIcon("zebra", systemName: "line.diagonal")
    static let peaking = TRIcon("peaking", systemName: "scope")
    static let falseColor = TRIcon("falseColor", systemName: "paintpalette")
    static let lut = TRIcon("lut", systemName: "cube")
    static let histogram = TRIcon("histogram", systemName: "chart.bar")
    static let waveformScope = TRIcon("waveformScope", systemName: "waveform.path.ecg")
    static let lensProfile = TRIcon("lensProfile", systemName: "cpu")
    static let zoomContinuous = TRIcon("zoomContinuous", systemName: "plus.magnifyingglass")
    static let rackFocus = TRIcon("rackFocus", systemName: "arrow.left.arrow.right")
    static let film = TRIcon("film", systemName: "film")
    static let filmStack = TRIcon("filmStack", systemName: "film.stack")
    static let cameraUnavailable = TRIcon("cameraUnavailable", systemName: "video.slash")
    static let cameraPermission = TRIcon("cameraPermission", systemName: "video.badge.ellipsis")
}

/// Round AUTO / MAN toggle used on parameter cards.
struct AutoPill: View {
    @Environment(\.trTheme) private var theme
    var isAuto: Bool
    var label = "AUTO"

    var body: some View {
        let c = theme.colors
        Text(label)
            .trTextStyle(.caption2)
            .fontWeight(.bold)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(isAuto ? c.action.onPrimary : c.action.onSecondary)
            .frame(width: theme.metrics.minimumHitTarget, height: theme.metrics.minimumHitTarget)
            .background(Circle().fill(isAuto ? c.action.primary : c.action.secondary))
    }
}

struct ParameterCard: View {
    @Environment(\.trTheme) private var theme
    var title: String
    var value: String
    var isAuto: Bool
    var isActive = false
    var badge: String? = nil
    var compact = false
    var onToggleAuto: () -> Void
    var onTap: () -> Void

    /// Fixed card width in the horizontal portrait strip, so values don't reflow the row.
    private static let compactWidth: CGFloat = 142

    var body: some View {
        let c = theme.colors
        let shape = RoundedRectangle.tr(theme.shape.card)
        VStack(alignment: .leading, spacing: compact ? theme.spacing.stack.tight : theme.spacing.stack.regular) {
            HStack(spacing: theme.spacing.xxs) {
                Text(title).trTextStyle(.overline).foregroundStyle(c.foreground.secondary).lineLimit(1).fixedSize()
                if let badge { TRBadge(verbatim: badge, tone: .warning) }
            }
            HStack {
                Button(action: onToggleAuto) { AutoPill(isAuto: isAuto) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title) automático \(isAuto ? "ligado" : "desligado")")
                Spacer(minLength: theme.spacing.xxs)
                Text(value)
                    .trTextStyle(compact ? .metricSmall : .metric)
                    .foregroundStyle(c.foreground.primary)
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .contentTransition(.numericText())
            }
        }
        .padding(theme.spacing.inset.tight + theme.spacing.xxs)
        .frame(width: compact ? Self.compactWidth : nil)
        .trSurface(.raised, in: shape, fill: isActive ? c.surface.selected : c.background.tertiary)
        .overlay(shape.strokeBorder(c.border.focus.opacity(isActive ? 1 : 0), lineWidth: TRBorder.default))
        .contentShape(shape)
        .onTapGesture(perform: onTap)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// The record control. No DS component covers it (proposed as `TRRecordButton`).
struct RecordButton: View {
    @Environment(\.trTheme) private var theme
    var isRecording: Bool
    var action: () -> Void

    /// Outer ring diameter; the inner shape morphs from a disc to a rounded square.
    private static let diameter: CGFloat = 78

    var body: some View {
        let c = theme.colors
        let inner = Self.diameter - 12
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(isRecording ? c.recording : c.border.strong, lineWidth: TRBorder.emphasized + 1)
                    .frame(width: Self.diameter, height: Self.diameter)
                RoundedRectangle.tr(isRecording ? theme.shape.control : inner / 2)
                    .fill(c.recording)
                    .frame(width: isRecording ? inner / 2 : inner, height: isRecording ? inner / 2 : inner)
            }
            .trAnimation(.snappy, value: isRecording)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .medium), trigger: isRecording)
        .accessibilityLabel(isRecording ? "Parar gravação" : "Iniciar gravação")
    }
}

/// Horizontal tick dial over a discrete list of values. Drag to change.
/// No DS equivalent yet (the DS roadmap lists a numeric stepper and range slider).
struct StepDial: View {
    @Environment(\.trTheme) private var theme
    var count: Int
    @Binding var index: Int
    var label: (Int) -> String
    var spacing: CGFloat = 14
    var onCommit: () -> Void = {}

    @State private var dragStartIndex: Int?

    var body: some View {
        let c = theme.colors
        GeometryReader { geo in
            let mid = geo.size.width / 2
            ZStack {
                Canvas { ctx, size in
                    for i in 0..<count {
                        let x = mid + CGFloat(i - index) * spacing
                        guard x > -spacing, x < size.width + spacing else { continue }
                        let major = i % 3 == 0
                        let rect = CGRect(x: x - 0.75, y: size.height * (major ? 0.45 : 0.58), width: 1.5, height: size.height * (major ? 0.35 : 0.22))
                        let fade = 1 - min(1, abs(x - mid) / mid)
                        ctx.fill(Path(rect), with: .style(c.foreground.primary.opacity(0.2 + 0.6 * fade)))
                    }
                }
                Capsule().fill(c.foreground.accent).frame(width: 3, height: geo.size.height * 0.55).offset(y: geo.size.height * 0.12)
                Text(label(index))
                    .trTextStyle(.metricSmall)
                    .foregroundStyle(c.foreground.accent)
                    .offset(y: -geo.size.height * 0.36)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { g in
                    if dragStartIndex == nil { dragStartIndex = index }
                    let delta = Int((-g.translation.width / spacing).rounded())
                    let next = min(max((dragStartIndex ?? index) + delta, 0), count - 1)
                    if next != index { index = next }
                }
                .onEnded { _ in dragStartIndex = nil; onCommit() })
        }
        .frame(height: 78)
        .sensoryFeedback(.selection, trigger: index)
        .accessibilityElement()
        .accessibilityValue(label(index))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: index = min(index + 1, count - 1)
            case .decrement: index = max(index - 1, 0)
            @unknown default: break
            }
            onCommit()
        }
    }
}

/// Translucent chrome panel drawn over the live preview.
struct PreviewPanelBackground: ViewModifier {
    @Environment(\.trTheme) private var theme

    func body(content: Content) -> some View {
        content.background(RoundedRectangle.tr(theme.shape.card).fill(theme.colors.surface.overlay.opacity(0.9)))
    }
}

extension View {
    func previewPanelBackground() -> some View { modifier(PreviewPanelBackground()) }
}

/// Grouped `Form`/`List` on theme surfaces instead of the system grays.
///
/// The DS has no grouped-row token yet (proposed). Rows use `surface.overlay`,
/// which stays one step above `background.secondary` in light, dark and
/// increased contrast; with `background.secondary`/`surface.raised` the two
/// would be identical in dark mode.
private struct ThemedGroupedList: ViewModifier {
    @Environment(\.trTheme) private var theme
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(theme.colors.background.secondary)
    }
}

private struct ThemedListRow: ViewModifier {
    @Environment(\.trTheme) private var theme
    func body(content: Content) -> some View {
        content.listRowBackground(Rectangle().fill(theme.colors.surface.overlay))
    }
}

extension View {
    func themedGroupedList() -> some View { modifier(ThemedGroupedList()) }
    /// Apply to the sections of a grouped list (a `Group` spreads it to each one).
    func themedListRows() -> some View { modifier(ThemedListRow()) }
}
