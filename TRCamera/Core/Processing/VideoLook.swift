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
            // Shadows toward teal, highlights/skin toward orange.
            image = image.applyingFilter("CIColorPolynomial", parameters: [
                "inputRedCoefficients": CIVector(x: -0.02, y: 1.02, z: 0.08, w: -0.04),
                "inputGreenCoefficients": CIVector(x: 0.01, y: 1.0, z: 0.02, w: -0.03),
                "inputBlueCoefficients": CIVector(x: 0.06, y: 0.98, z: -0.08, w: 0.0),
                "inputAlphaCoefficients": CIVector(x: 0, y: 1, z: 0, w: 0)
            ])
            .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.1, kCIInputSaturationKey: 1.05])
        case .warmFilm:
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 5200, y: 8)
            ])
            .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.05, kCIInputSaturationKey: 0.92])
            .applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: 0.6, kCIInputRadiusKey: 1.6])
        case .coolBlue:
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 8200, y: -4)
            ])
            .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.06, kCIInputSaturationKey: 0.9])
        case .fade:
            image = image.applyingFilter("CIPhotoEffectFade")
        case .bleachBypass:
            let mono = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0, kCIInputContrastKey: 1.25])
            image = mono.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: image, kCIInputTimeKey: 0.45])
        case .vintage:
            image = image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.35])
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 0.92, kCIInputBrightnessKey: 0.02])
                .applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: 0.9, kCIInputRadiusKey: 1.4])
        case .mono:
            image = image.applyingFilter("CIPhotoEffectMono")
        case .noir:
            image = image.applyingFilter("CIPhotoEffectNoir")
        case .chrome:
            image = image.applyingFilter("CIPhotoEffectChrome")
        case .dream:
            // Radius relative to width so preview (screen size) and export (full res) match.
            let glow = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: extent.width * 0.006]).cropped(to: extent)
            image = glow.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: image])
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 0.9, kCIInputSaturationKey: 0.95])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.78, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0.78, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0.82, w: 0)
                ])
        }
        return image.cropped(to: extent)
    }
}
