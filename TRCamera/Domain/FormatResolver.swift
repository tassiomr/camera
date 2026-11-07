import Foundation

/// Resolves a requested CaptureConfiguration against the formats a camera really
/// exposes. Every UI picker is fed from here, so impossible combinations are never
/// offered, and changing one setting automatically repairs the dependent ones.
struct FormatResolver {
    let camera: CameraDescriptor

    struct Resolution: Equatable {
        var configuration: CaptureConfiguration
        var format: FormatDescriptor
        /// Human-readable list of what had to change and why.
        var adjustments: [String]
    }

    // MARK: Options

    func resolutions() -> [VideoResolution] { camera.resolutions }

    func frameRates(for resolution: VideoResolution) -> [Double] {
        let candidates: [Double] = [23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60, 100, 120, 240]
        let formats = camera.formats.filter { $0.resolution == resolution }
        return candidates.filter { fps in formats.contains { $0.supports(fps: fps) } }
    }

    func colorProfiles(for resolution: VideoResolution, fps: Double) -> [ColorProfile] {
        let formats = matching(resolution: resolution, fps: fps)
        let set = Set(formats.flatMap(\.colorProfiles))
        return ColorProfile.allCases.filter { set.contains($0) }
    }

    func stabilizationModes(for resolution: VideoResolution, fps: Double, profile: ColorProfile) -> [StabilizationMode] {
        let formats = matching(resolution: resolution, fps: fps).filter { $0.colorProfiles.contains(profile) }
        let set = Set(formats.flatMap(\.stabilizationModes))
        return StabilizationMode.allCases.filter { set.contains($0) && $0 != .auto }
    }

    // MARK: Resolve

    /// - Parameter availableCodecs: codecs the movie output reported for the active
    ///   format. nil means "not probed yet" (codec is then kept and probed after apply).
    func resolve(_ requested: CaptureConfiguration, availableCodecs: [VideoCodec]? = nil) -> Resolution? {
        guard !camera.formats.isEmpty else { return nil }
        var config = requested
        var notes: [String] = []
        config.cameraID = camera.id

        // 1. Resolution: exact match, else the closest by pixel count.
        let resolutions = camera.resolutions
        if !resolutions.contains(config.resolution) {
            let closest = resolutions.min { abs($0.pixels - config.resolution.pixels) < abs($1.pixels - config.resolution.pixels) }!
            notes.append("\(config.resolution.label) indisponível nesta lente → \(closest.label)")
            config.resolution = closest
        }

        // 2. Frame rate.
        let rates = frameRates(for: config.resolution)
        if !rates.contains(where: { abs($0 - config.frameRate) < 0.01 }) {
            let closest = rates.min { abs($0 - config.frameRate) < abs($1 - config.frameRate) } ?? 30
            notes.append("\(FrameRateFormatter.string(config.frameRate)) fps indisponível em \(config.resolution.label) → \(FrameRateFormatter.string(closest)) fps")
            config.frameRate = closest
        }

        // 3. Color profile.
        let profiles = colorProfiles(for: config.resolution, fps: config.frameRate)
        if !profiles.contains(config.colorProfile) {
            let fallback = Self.fallbackProfile(for: config.colorProfile, among: profiles)
            notes.append("\(config.colorProfile.label) indisponível nesta combinação → \(fallback.label)")
            config.colorProfile = fallback
        }

        // 4. Pick the concrete format.
        let candidates = matching(resolution: config.resolution, fps: config.frameRate)
            .filter { $0.colorProfiles.contains(config.colorProfile) }
        guard let format = Self.best(candidates, stabilization: config.stabilization) else { return nil }

        // 5. Stabilization.
        if config.stabilization != .off, config.stabilization != .auto,
           !format.stabilizationModes.contains(config.stabilization) {
            let fallback = format.stabilizationModes
                .filter { $0.strength <= config.stabilization.strength }
                .max { $0.strength < $1.strength } ?? .off
            notes.append("Estabilização \(config.stabilization.label) indisponível → \(fallback.label)")
            config.stabilization = fallback
        }

        // 6. Codec (only when the runtime list is known).
        if let codecs = availableCodecs, !codecs.isEmpty, !codecs.contains(config.codec) {
            let fallback = Self.fallbackCodec(for: config.codec, profile: config.colorProfile, among: codecs)
            notes.append("\(config.codec.label) indisponível neste formato → \(fallback.label)")
            config.codec = fallback
        }

        return Resolution(configuration: config, format: format, adjustments: notes)
    }

    // MARK: Helpers

    private func matching(resolution: VideoResolution, fps: Double) -> [FormatDescriptor] {
        camera.formats.filter { $0.resolution == resolution && $0.supports(fps: fps) }
    }

    /// Prefers: non-binned → supports requested stabilization → widest FOV → lowest max fps
    /// (high-speed formats often trade quality) → highest bit depth.
    static func best(_ formats: [FormatDescriptor], stabilization: StabilizationMode) -> FormatDescriptor? {
        formats.max { a, b in
            func score(_ f: FormatDescriptor) -> (Int, Int, Float, Double, Int) {
                (f.isBinned ? 0 : 1,
                 f.stabilizationModes.contains(stabilization) || stabilization == .off ? 1 : 0,
                 f.fieldOfView,
                 -f.maxFrameRate,
                 f.bitDepth)
            }
            return score(a) < score(b)
        }
    }

    static func fallbackProfile(for wanted: ColorProfile, among available: [ColorProfile]) -> ColorProfile {
        let order: [ColorProfile]
        switch wanted {
        case .appleLog2: order = [.appleLog, .hlg, .rec709, .p3]
        case .appleLog: order = [.appleLog2, .hlg, .rec709, .p3]
        case .hlg: order = [.rec709, .p3]
        case .p3: order = [.rec709]
        case .rec709: order = [.p3]
        }
        return order.first(where: available.contains) ?? available.first ?? .rec709
    }

    static func fallbackCodec(for wanted: VideoCodec, profile: ColorProfile, among available: [VideoCodec]) -> VideoCodec {
        if wanted.isProRes, let pro = [VideoCodec.proRes422HQ, .proRes422, .proRes422LT, .proRes422Proxy].first(where: available.contains) {
            return pro
        }
        // HLG/Log need 10-bit: prefer HEVC over H.264.
        let order: [VideoCodec] = profile == .rec709 || profile == .p3 ? [.hevc, .h264] : [.hevc, .proRes422, .h264]
        return order.first(where: available.contains) ?? available.first!
    }
}
