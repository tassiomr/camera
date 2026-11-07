import CoreImage

/// Creative looks built only from built-in Core Image filters, so the same code
/// drives the live preview and the export of a filtered copy. Looks never touch
/// the original recording.
enum VideoLook: String, CaseIterable, Codable, Identifiable, Sendable {
    case none, vivid, tealOrange, warmFilm, coolBlue, fade, bleachBypass, vintage, mono, noir, chrome, dream

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Original"
        case .vivid: "Vivid"
        case .tealOrange: "Teal & Orange"
        case .warmFilm: "Warm Film"
        case .coolBlue: "Cool"
        case .fade: "Fade"
        case .bleachBypass: "Bleach"
        case .vintage: "Vintage"
        case .mono: "Mono"
        case .noir: "Noir"
        case .chrome: "Chrome"
        case .dream: "Dream"
        }
    }

    /// Looks are designed for display-referred (Rec.709) images. On Log footage
    /// apply them after the Log→709 LUT.
    func apply(to input: CIImage) -> CIImage {
        let extent = input.extent
        var image = input
        switch self {
        case .none:
            return input
        case .vivid:
            image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": 0.6])
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.08, kCIInputSaturationKey: 1.1])
        case .tealOrange:
            image = image.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": Self.cubeSize, "inputCubeData": Self.tealOrangeCube])
        case .warmFilm:
            image = image.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": Self.cubeSize, "inputCubeData": Self.warmFilmCube])
                .applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: 0.8, kCIInputRadiusKey: 1.5])
        case .coolBlue:
            image = image.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": Self.cubeSize, "inputCubeData": Self.coolCube])
        case .fade:
            image = image.applyingFilter("CIPhotoEffectFade")
        case .bleachBypass:
            let mono = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0, kCIInputContrastKey: 1.25])
            image = mono.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: image, kCIInputTimeKey: 0.4])
        case .vintage:
            image = image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.55])
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 0.92, kCIInputBrightnessKey: 0.02])
                .applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: 1.0, kCIInputRadiusKey: 1.4])
        case .mono:
            image = image.applyingFilter("CIPhotoEffectMono")
        case .noir:
            image = image.applyingFilter("CIPhotoEffectNoir")
        case .chrome:
            image = image.applyingFilter("CIPhotoEffectChrome")
        case .dream:
            // Radius relative to width so preview (screen size) and export (full res) match.
            let glow = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: extent.width * 0.012]).cropped(to: extent)
            image = glow.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: image])
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 0.9, kCIInputSaturationKey: 0.95])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.72, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0.68, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0.8, w: 0),
                    "inputBiasVector": CIVector(x: 0.04, y: 0.02, z: 0.06, w: 0)
                ])
        }
        return image.cropped(to: extent)
    }

    // MARK: Grading cubes
    // Generated once from simple, explicit math on display-referred values so the
    // preview and the exported copy produce the same result.

    static let cubeSize = 24

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func grade(saturation: Double, contrast: Double, shadows: SIMD3<Double>, highlights: SIMD3<Double>,
                              gain: SIMD3<Double> = .one, lift: Double = 0) -> Data {
        CubeLUT.generate(title: "look", dimension: cubeSize) { rgb in
            var c = rgb * gain
            let l = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
            c = SIMD3(repeating: l) + (c - SIMD3(repeating: l)) * saturation
            c += shadows * (1 - smoothstep(0.0, 0.55, l)) + highlights * smoothstep(0.35, 1.0, l)
            c = (c - 0.5) * contrast + 0.5
            return c * (1 - lift) + SIMD3(repeating: lift)
        }.data
    }

    static let tealOrangeCube = grade(saturation: 1.15, contrast: 1.12,
                                      shadows: SIMD3(-0.07, 0.03, 0.09), highlights: SIMD3(0.09, 0.03, -0.09))
    static let warmFilmCube = grade(saturation: 0.88, contrast: 1.06, shadows: SIMD3(0.02, 0.0, -0.03),
                                    highlights: SIMD3(0.05, 0.02, -0.04), gain: SIMD3(1.08, 1.0, 0.86), lift: 0.04)
    static let coolCube = grade(saturation: 0.9, contrast: 1.08, shadows: SIMD3(-0.03, 0.0, 0.06),
                                highlights: SIMD3(-0.03, 0.01, 0.05), gain: SIMD3(0.9, 1.0, 1.1))
}
