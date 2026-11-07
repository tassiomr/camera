import SwiftUI

enum Theme {
    static let accent = Color(red: 0.243, green: 0.890, blue: 0.757)      // mint
    static let accentDeep = Color(red: 0.10, green: 0.62, blue: 0.56)
    static let background = Color.black
    static let panel = Color(white: 0.07)
    static let card = Color(white: 0.115)
    static let cardHighlight = Color(white: 0.16)
    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.62)
    static let recording = Color(red: 1, green: 0.27, blue: 0.27)
    static let warning = Color(red: 1, green: 0.78, blue: 0.2)

    static let corner: CGFloat = 18

    static func label(_ size: CGFloat = 11) -> Font { .system(size: size, weight: .semibold).width(.expanded) }
    static func value(_ size: CGFloat = 26) -> Font { .system(size: size, weight: .medium, design: .rounded).monospacedDigit() }
}

/// Small rounded AUTO / MAN pill used on parameter cards.
struct AutoPill: View {
    var isAuto: Bool
    var label = "AUTO"
    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold).width(.expanded))
            .foregroundStyle(isAuto ? Color.black : Theme.textSecondary)
            .frame(width: 40, height: 40)
            .background(Circle().fill(isAuto ? Theme.accent : Color(white: 0.2)))
    }
}

struct ParameterCard: View {
    var title: String
    var value: String
    var isAuto: Bool
    var isActive = false
    var badge: String? = nil
    var compact = false
    var onToggleAuto: () -> Void
    var onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            HStack(spacing: 6) {
                Text(title).font(Theme.label(10)).foregroundStyle(Theme.textSecondary)
                if let badge {
                    Text(badge).font(.system(size: 8, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().stroke(Theme.textSecondary.opacity(0.6)))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            HStack {
                Button(action: onToggleAuto) { AutoPill(isAuto: isAuto) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title) automático \(isAuto ? "ligado" : "desligado")")
                Spacer(minLength: 4)
                Text(value)
                    .font(Theme.value(compact ? 20 : 26))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
            }
        }
        .padding(12)
        .frame(minWidth: compact ? 130 : 0)
        .background(RoundedRectangle(cornerRadius: 14).fill(isActive ? Theme.cardHighlight : Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(isActive ? Theme.accent.opacity(0.7) : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

struct ChipButton: View {
    var title: String
    var isOn = false
    var systemImage: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 12, weight: .semibold)) }
                Text(title).font(.system(size: 11, weight: .bold).width(.expanded))
            }
            .padding(.horizontal, 10).frame(height: 32)
            .foregroundStyle(isOn ? Color.black : Theme.textPrimary)
            .background(Capsule().fill(isOn ? Theme.accent : Theme.card))
        }
        .buttonStyle(.plain)
    }
}

struct RecordButton: View {
    var isRecording: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(isRecording ? Theme.recording : Theme.accent.opacity(0.5), lineWidth: 3).frame(width: 78, height: 78)
                RoundedRectangle(cornerRadius: isRecording ? 8 : 33)
                    .fill(isRecording ? Theme.recording : Theme.accent)
                    .frame(width: isRecording ? 32 : 66, height: isRecording ? 32 : 66)
                    .shadow(color: (isRecording ? Theme.recording : Theme.accent).opacity(0.6), radius: 14)
            }
            .animation(.spring(duration: 0.3), value: isRecording)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .medium), trigger: isRecording)
        .accessibilityLabel(isRecording ? "Parar gravação" : "Iniciar gravação")
    }
}

/// Horizontal tick dial over a discrete list of values. Drag to change.
struct StepDial: View {
    var count: Int
    @Binding var index: Int
    var label: (Int) -> String
    var spacing: CGFloat = 14
    var onCommit: () -> Void = {}

    @State private var dragStartIndex: Int?

    var body: some View {
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
                        ctx.fill(Path(rect), with: .color(.white.opacity(0.2 + 0.6 * fade)))
                    }
                }
                Capsule().fill(Theme.accent).frame(width: 3, height: geo.size.height * 0.55).offset(y: geo.size.height * 0.12)
                Text(label(index)).font(Theme.value(15)).foregroundStyle(Theme.accent).offset(y: -geo.size.height * 0.3)
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
        .frame(height: 64)
        .sensoryFeedback(.selection, trigger: index)
    }
}
