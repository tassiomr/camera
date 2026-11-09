import SwiftUI
import TRDesignSystem

/// Horizontal strip of creative looks. The selected look is shown live and is
/// applied to the clip automatically when recording stops (the camera itself
/// always records the clean stream).
struct LookPicker: View {
    @Environment(\.trTheme) private var theme
    @Binding var selection: VideoLook

    var body: some View {
        let c = theme.colors
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: theme.spacing.stack.regular) {
                ForEach(VideoLook.allCases) { look in
                    Button { selection = look } label: {
                        VStack(spacing: theme.spacing.stack.tight + theme.spacing.xxxs) {
                            Circle()
                                .fill(Self.swatch(look))
                                .frame(width: 44, height: 44)
                                .overlay(Circle().strokeBorder(c.border.focus.opacity(selection == look ? 1 : 0), lineWidth: TRBorder.focus).padding(-4))
                            Text(look.title)
                                .trTextStyle(.caption2)
                                .fontWeight(.semibold)
                                .foregroundStyle(selection == look ? c.foreground.accent : c.foreground.secondary)
                                .lineLimit(2).multilineTextAlignment(.center)
                                .frame(height: 26, alignment: .top)
                        }
                        .frame(width: 74)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Filtro \(look.title)")
                    .accessibilityAddTraits(selection == look ? .isSelected : [])
                }
            }
            .padding(.horizontal, theme.spacing.sm)
            .padding(.vertical, theme.spacing.stack.regular)
        }
        .previewPanelBackground()
        .sensoryFeedback(.selection, trigger: selection)
    }

    /// Small gradient that hints at each look's palette. These are previews of
    /// the image a look produces (content), not interface colors, so they stay literal.
    static func swatch(_ look: VideoLook) -> LinearGradient {
        let colors: [Color] = switch look {
        case .none: [Color(white: 0.35), Color(white: 0.6)]
        case .vivid: [.pink, .orange, .yellow]
        case .tealOrange: [Color(red: 0.05, green: 0.45, blue: 0.5), Color(red: 1, green: 0.6, blue: 0.3)]
        case .warmFilm: [Color(red: 0.55, green: 0.3, blue: 0.15), Color(red: 1, green: 0.8, blue: 0.5)]
        case .coolBlue: [Color(red: 0.1, green: 0.25, blue: 0.5), Color(red: 0.6, green: 0.8, blue: 1)]
        case .fade: [Color(white: 0.45), Color(red: 0.85, green: 0.8, blue: 0.75)]
        case .bleachBypass: [Color(white: 0.15), Color(red: 0.7, green: 0.72, blue: 0.68)]
        case .vintage: [Color(red: 0.4, green: 0.3, blue: 0.2), Color(red: 0.9, green: 0.8, blue: 0.6)]
        case .mono: [.black, .white]
        case .noir: [.black, Color(white: 0.45), .black]
        case .chrome: [Color(red: 0.2, green: 0.4, blue: 0.9), Color(red: 1, green: 0.85, blue: 0.2)]
        case .dream: [Color(red: 0.75, green: 0.6, blue: 1), Color(red: 1, green: 0.85, blue: 0.95)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
