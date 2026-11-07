import Foundation

/// Exposure arithmetic shared by the UI and the capture engine.
enum ExposureMath {
    /// exposure = (angle / 360) / fps. 180° @ 24 fps = 1/48 s.
    static func exposureDuration(shutterAngle: Double, fps: Double) -> Double {
        guard fps > 0 else { return 0 }
        return (shutterAngle / 360.0) / fps
    }

    static func shutterAngle(exposure: Double, fps: Double) -> Double {
        exposure * fps * 360.0
    }

    /// Video can never expose longer than one frame.
    static func maxVideoExposure(fps: Double, formatMax: Double) -> Double {
        guard fps > 0 else { return formatMax }
        return min(formatMax, 1.0 / fps)
    }

    static let standardAngles: [Double] = [11.25, 22.5, 45, 90, 144, 172.8, 180, 216, 270, 360]

    static let standardDenominators: [Double] = [
        24, 25, 30, 48, 50, 60, 72, 96, 100, 120, 125, 144, 180, 200, 240, 250, 360, 480, 500,
        960, 1000, 2000, 4000, 8000, 10000, 16000, 24000
    ]

    /// Shutter values (seconds) valid for the given limits, plus the exact 180° value.
    static func shutterSteps(fps: Double, minExposure: Double, maxExposure: Double) -> [Double] {
        let upper = maxVideoExposure(fps: fps, formatMax: maxExposure)
        var values = standardDenominators.map { 1.0 / $0 }.filter { $0 >= minExposure - 1e-9 && $0 <= upper + 1e-9 }
        let oneEighty = exposureDuration(shutterAngle: 180, fps: fps)
        if oneEighty >= minExposure, oneEighty <= upper, !values.contains(where: { abs($0 - oneEighty) < 1e-6 }) {
            values.append(oneEighty)
        }
        return values.sorted(by: >)
    }

    static func angleSteps(fps: Double, minExposure: Double, maxExposure: Double) -> [Double] {
        let upper = maxVideoExposure(fps: fps, formatMax: maxExposure)
        return standardAngles.filter {
            let e = exposureDuration(shutterAngle: $0, fps: fps)
            return e >= minExposure - 1e-9 && e <= upper + 1e-9
        }
    }

    static func shutterLabel(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        if seconds >= 1 { return String(format: "%.1fs", seconds) }
        let denom = 1.0 / seconds
        if abs(denom - denom.rounded()) < 0.05 { return "1/\(Int(denom.rounded()))" }
        return String(format: "1/%.1f", denom)
    }

    static func angleLabel(_ angle: Double) -> String {
        abs(angle - angle.rounded()) < 0.05 ? "\(Int(angle.rounded()))°" : String(format: "%.1f°", angle)
    }

    /// ISO values on third-stop steps clamped to the format limits.
    static func isoSteps(min: Float, max: Float) -> [Float] {
        let base: [Float] = [25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800,
                             1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800]
        var values = base.filter { $0 >= min && $0 <= max }
        if let first = values.first, first > min { values.insert(min.rounded(), at: 0) }
        if let last = values.last, last < max { values.append(max.rounded()) }
        if values.isEmpty { values = [min, max] }
        return values
    }

    /// Exposure value at ISO 100 equivalent: EV = log2(N² / t) - log2(ISO/100).
    static func ev100(aperture: Double, exposure: Double, iso: Double) -> Double {
        guard exposure > 0, iso > 0 else { return 0 }
        return log2(aperture * aperture / exposure) - log2(iso / 100)
    }

    /// Correlated color temperature presets in Kelvin.
    static let kelvinSteps: [Float] = stride(from: 2000, through: 10000, by: 100).map { Float($0) }
}
