import CoreImage

/// Effects driven by the beat pulse (0…1). The same code renders the live preview
/// and the beat-synced export; the original recording is never touched.
enum BeatEffect: String, CaseIterable, Codable, Identifiable, Sendable {
    case off, punch, flash, punchFlash, shake, rgbSplit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .punch: "Zoom punch"
        case .flash: "Flash"
        case .punchFlash: "Punch + flash"
        case .shake: "Tremor"
        case .rgbSplit: "RGB split"
        }
    }

    var systemImage: String {
        switch self {
        case .off: "waveform.slash"
        case .punch: "plus.magnifyingglass"
        case .flash: "sun.max"
        case .punchFlash: "sparkles"
        case .shake: "waveform.path"
        case .rgbSplit: "circle.hexagongrid"
        }
    }

    /// Flash effects never fire more than ~3 times per second.
    var minimumBeatInterval: Double {
        switch self {
        case .flash, .punchFlash: 0.34
        default: 0
        }
    }

    /// `amount` is the beat pulse, `seed` varies the shake direction per beat.
    func apply(to input: CIImage, amount: Double, seed: Int = 0) -> CIImage {
        let a = max(0, min(1, amount))
        guard self != .off, a > 0.01 else { return input }
        let extent = input.extent
        switch self {
        case .off:
            return input
        case .punch:
            return Self.zoom(input, by: 1 + 0.08 * a)
        case .flash:
            return Self.flash(input, a)
        case .punchFlash:
            return Self.flash(Self.zoom(input, by: 1 + 0.06 * a), a * 0.8)
        case .shake:
            let angle = Double(seed % 360) * 2.39996 // golden angle: new direction each beat
            let d = 0.018 * a * extent.width
            return input.clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: cos(angle) * d, y: sin(angle) * d))
                .cropped(to: extent)
        case .rgbSplit:
            let d = 0.012 * a * extent.width
            func channel(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, dx: CGFloat) -> CIImage {
                input.clampedToExtent()
                    .applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
                    ])
                    .transformed(by: CGAffineTransform(translationX: dx, y: 0))
            }
            let red = channel(1, 0, 0, dx: d), green = channel(0, 1, 0, dx: 0), blue = channel(0, 0, 1, dx: -d)
            return red.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: green])
                .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: blue])
                .cropped(to: extent)
        }
    }

    private static func zoom(_ image: CIImage, by scale: Double) -> CIImage {
        let e = image.extent
        let t = CGAffineTransform(translationX: e.midX, y: e.midY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -e.midX, y: -e.midY)
        return image.transformed(by: t).cropped(to: e)
    }

    /// Exposure lift capped at +1 EV so highlights are not blown into a white frame.
    private static func flash(_ image: CIImage, _ a: Double) -> CIImage {
        image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 1.0 * a])
    }
}
