import Foundation

/// Monitoring tool settings — saved inside presets.
struct MonitoringSettings: Codable, Hashable, Sendable {
    enum PeakingColor: String, Codable, CaseIterable, Identifiable, Sendable {
        case mint, red, yellow, blue, white
        var id: String { rawValue }
        var rgb: (Double, Double, Double) {
            switch self {
            case .mint: (0.24, 0.89, 0.76)
            case .red: (1, 0.2, 0.2)
            case .yellow: (1, 0.9, 0.1)
            case .blue: (0.25, 0.55, 1)
            case .white: (1, 1, 1)
            }
        }
    }

    enum AspectGuide: String, Codable, CaseIterable, Identifiable, Sendable {
        case none, r16x9, r9x16, r1x1, r4x3, r4x5, r239
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: "Off"
            case .r16x9: "16:9"
            case .r9x16: "9:16"
            case .r1x1: "1:1"
            case .r4x3: "4:3"
            case .r4x5: "4:5"
            case .r239: "2.39:1"
            }
        }
        var ratio: Double? {
            switch self {
            case .none: nil
            case .r16x9: 16.0 / 9
            case .r9x16: 9.0 / 16
            case .r1x1: 1
            case .r4x3: 4.0 / 3
            case .r4x5: 4.0 / 5
            case .r239: 2.39
            }
        }
    }

    var zebraEnabled = false
    var zebraLevel: Double = 0.95
    var peakingEnabled = false
    var peakingColor: PeakingColor = .mint
    var peakingSensitivity: Double = 0.5
    var falseColorEnabled = false
    var histogramEnabled = true
    var waveformEnabled = false
    var lutID: String? = nil
    var anamorphicSqueeze: Double = 1.0
    var thirdsGrid = true
    var centerMark = false
    var safeAreas = false
    var levelIndicator = true
    var aspectGuide: AspectGuide = .none

    /// True when the frame has to go through the monitoring renderer (higher latency).
    var needsProcessedPreview: Bool {
        zebraEnabled || peakingEnabled || falseColorEnabled || lutID != nil || anamorphicSqueeze != 1
    }
    var needsAnalysis: Bool { histogramEnabled || waveformEnabled }
}

/// Manual exposure intent saved in presets (nil = automatic).
struct ExposureIntent: Codable, Hashable, Sendable {
    var iso: Float? = nil
    var shutterAngle: Double? = nil
    var whiteBalanceKelvin: Float? = nil
    var manualFocus: Float? = nil
}

struct CapturePreset: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var isBuiltIn: Bool
    var goal: RecordingConfigurationAdvisor.Goal?
    var configuration: CaptureConfiguration?
    var exposure = ExposureIntent()
    var monitoring = MonitoringSettings()
    var audioGain: Float? = nil
}

struct PresetValidation {
    var configuration: CaptureConfiguration
    var substitutions: [String]
    var isExact: Bool { substitutions.isEmpty }
}

enum PresetValidator {
    /// Validates a preset against the current camera. Never applies something the
    /// hardware cannot do; instead it lists the compatible alternatives chosen.
    static func validate(_ preset: CapturePreset, camera: CameraDescriptor, knownCodecs: [VideoCodec]?) -> PresetValidation? {
        let base = preset.configuration ?? CaptureConfiguration.fallback(cameraID: camera.id)
        var subs: [String] = []
        if base.cameraID != camera.id, preset.configuration != nil {
            subs.append("Preset criado para outra lente; aplicado em \(camera.name)")
        }
        guard let resolved = FormatResolver(camera: camera).resolve(base, availableCodecs: knownCodecs) else { return nil }
        subs.append(contentsOf: resolved.adjustments)
        if let iso = preset.exposure.iso, !(resolved.format.minISO...resolved.format.maxISO).contains(iso) {
            subs.append("ISO \(Int(iso)) fora da faixa \(Int(resolved.format.minISO))–\(Int(resolved.format.maxISO)); será limitado")
        }
        return PresetValidation(configuration: resolved.configuration, substitutions: subs)
    }
}

/// Built-in presets are generated from advisor goals so they always match the device.
enum BuiltInPresets {
    static let goals: [RecordingConfigurationAdvisor.Goal] = [.automatic, .cinematic, .creatorVertical, .lowLight, .highMotion, .maximumQuality, .editingLog]

    static func make(for goal: RecordingConfigurationAdvisor.Goal) -> CapturePreset {
        var preset = CapturePreset(name: goal.title, isBuiltIn: true, goal: goal)
        switch goal {
        case .cinematic:
            preset.exposure.shutterAngle = 180
            preset.monitoring.aspectGuide = .r239
            preset.monitoring.zebraEnabled = true
        case .creatorVertical:
            preset.monitoring.aspectGuide = .r9x16
        case .lowLight:
            preset.exposure.shutterAngle = 360
            preset.monitoring.falseColorEnabled = false
        case .highMotion:
            preset.exposure.shutterAngle = 180
        case .editingLog:
            preset.exposure.shutterAngle = 180
            preset.monitoring.lutID = BuiltInLUT.appleLogTo709.id
            preset.monitoring.zebraEnabled = true
            preset.monitoring.waveformEnabled = true
        case .maximumQuality, .automatic, .concert:
            break
        }
        return preset
    }
}

/// Persists user presets as JSON in Application Support.
final class PresetStore {
    private let url: URL

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("presets.json")
    }

    func load() -> [CapturePreset] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([CapturePreset].self, from: data)) ?? []
    }

    func save(_ presets: [CapturePreset]) throws {
        let data = try JSONEncoder().encode(presets.filter { !$0.isBuiltIn })
        try data.write(to: url, options: .atomic)
    }
}
