import Foundation

// Pure value types describing what a camera can do and what the user asked for.
// Nothing here imports AVFoundation, so the compatibility logic is unit-testable
// without a physical device.

enum CameraPosition: String, Codable, Sendable {
    case back, front, external
}

enum LensKind: String, Codable, Sendable, CaseIterable {
    case ultraWide, wide, telephoto, frontWide, frontUltraWide, virtualMulti, external, other

    var label: String {
        switch self {
        case .ultraWide: "Ultra Wide"
        case .wide: "Wide"
        case .telephoto: "Tele"
        case .frontWide: "Front"
        case .frontUltraWide: "Front UW"
        case .virtualMulti: "Auto Lens"
        case .external: "External"
        case .other: "Camera"
        }
    }
}

/// How a color profile is encoded. Codec, gamut, transfer curve and bit depth are
/// deliberately separate concepts (see docs/PESQUISA_E_MATRIZ.md).
enum ColorProfile: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Rec.709 primaries, Rec.709 transfer, 8-bit typically. AVCaptureColorSpace.sRGB.
    case rec709
    /// Display P3 primaries. AVCaptureColorSpace.P3_D65.
    case p3
    /// BT.2020 primaries, HLG transfer, 10-bit. AVCaptureColorSpace.HLG_BT2020.
    case hlg
    /// Apple Log, BT.2020 primaries, 10-bit. iOS 17+.
    case appleLog
    /// Apple Log 2 (wider "Apple Wide Gamut"). iOS 26+.
    case appleLog2

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rec709: "SDR Rec.709"
        case .p3: "SDR P3"
        case .hlg: "HDR HLG"
        case .appleLog: "Apple Log"
        case .appleLog2: "Apple Log 2"
        }
    }

    var shortLabel: String {
        switch self {
        case .rec709: "709"
        case .p3: "P3"
        case .hlg: "HLG"
        case .appleLog: "LOG"
        case .appleLog2: "LOG2"
        }
    }

    var isLog: Bool { self == .appleLog || self == .appleLog2 }
    var isHDR: Bool { self == .hlg }
    var transferCurve: String {
        switch self {
        case .rec709, .p3: "BT.709"
        case .hlg: "HLG (ARIB STD-B67)"
        case .appleLog, .appleLog2: "Apple Log"
        }
    }
    var gamut: String {
        switch self {
        case .rec709: "BT.709"
        case .p3: "Display P3"
        case .hlg, .appleLog: "BT.2020"
        case .appleLog2: "Apple Wide Gamut"
        }
    }

    /// Mapping to AVCaptureColorSpace raw values (stable ABI values from the SDK header).
    init?(captureColorSpaceRawValue raw: Int) {
        switch raw {
        case 0: self = .rec709
        case 1: self = .p3
        case 2: self = .hlg
        case 3: self = .appleLog
        case 4: self = .appleLog2
        default: return nil
        }
    }

    var captureColorSpaceRawValue: Int {
        switch self {
        case .rec709: 0
        case .p3: 1
        case .hlg: 2
        case .appleLog: 3
        case .appleLog2: 4
        }
    }
}

enum VideoCodec: String, Codable, Sendable, CaseIterable, Identifiable {
    case h264 = "avc1"
    case hevc = "hvc1"
    case proRes422Proxy = "apco"
    case proRes422LT = "apcs"
    case proRes422 = "apcn"
    case proRes422HQ = "apch"
    case proRes4444 = "ap4h"
    case proRes4444XQ = "ap4x"
    case proResRAW = "aprn"
    case proResRAWHQ = "aprh"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .proRes422Proxy: "ProRes Proxy"
        case .proRes422LT: "ProRes LT"
        case .proRes422: "ProRes 422"
        case .proRes422HQ: "ProRes HQ"
        case .proRes4444: "ProRes 4444"
        case .proRes4444XQ: "ProRes 4444 XQ"
        case .proResRAW: "ProRes RAW"
        case .proResRAWHQ: "ProRes RAW HQ"
        }
    }

    var isProRes: Bool { self != .h264 && self != .hevc }
    var isRAW: Bool { self == .proResRAW || self == .proResRAWHQ }

    /// Approximate compressed bits per pixel per frame. Calibrated against Apple's
    /// published figures (HEVC 4K30 ≈ 170 MB/min, H.264 4K30 ≈ 350 MB/min,
    /// ProRes 422 HQ 4K30 ≈ 707 Mb/s). Estimates only — the real file is measured
    /// after recording.
    var bitsPerPixel: Double {
        switch self {
        case .hevc: 0.091
        case .h264: 0.19
        case .proRes422Proxy: 0.58
        case .proRes422LT: 1.32
        case .proRes422: 1.89
        case .proRes422HQ: 2.84
        case .proRes4444: 4.26
        case .proRes4444XQ: 6.39
        case .proResRAW: 3.2
        case .proResRAWHQ: 4.8
        }
    }

    /// Codecs ordered from most to least preferred for "quality".
    static let qualityOrder: [VideoCodec] = [.proRes422HQ, .proRes422, .proRes4444, .proRes4444XQ, .hevc, .proRes422LT, .h264, .proRes422Proxy]
}

enum StabilizationMode: Int, Codable, Sendable, CaseIterable, Identifiable {
    // Raw values mirror AVCaptureVideoStabilizationMode.
    case off = 0
    case standard = 1
    case cinematic = 2
    case cinematicExtended = 3
    case previewOptimized = 4
    case cinematicExtendedEnhanced = 5
    case lowLatency = 6
    case auto = -1

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .off: "Off"
        case .standard: "Standard"
        case .cinematic: "Cinematic"
        case .cinematicExtended: "Cinematic Extended"
        case .previewOptimized: "Preview Optimized"
        case .cinematicExtendedEnhanced: "Cinematic Ext. Enhanced"
        case .lowLatency: "Low Latency"
        case .auto: "Auto"
        }
    }

    /// Rough ordering of stabilization strength (more = smoother, more crop & latency).
    var strength: Int {
        switch self {
        case .off: 0
        case .lowLatency: 1
        case .standard: 2
        case .previewOptimized: 3
        case .cinematic: 4
        case .cinematicExtended: 5
        case .cinematicExtendedEnhanced: 6
        case .auto: 3
        }
    }
}

struct FrameRateRange: Codable, Hashable, Sendable {
    var min: Double
    var max: Double
    func contains(_ fps: Double) -> Bool { fps >= min - 0.01 && fps <= max + 0.01 }
}

/// A snapshot of one AVCaptureDevice.Format, reduced to the facts the app reasons about.
struct FormatDescriptor: Codable, Hashable, Sendable, Identifiable {
    var index: Int
    var width: Int
    var height: Int
    var frameRateRanges: [FrameRateRange]
    var pixelFormat: String
    var bitDepth: Int
    var colorProfiles: [ColorProfile]
    var isVideoHDRSupported: Bool
    var stabilizationModes: [StabilizationMode]
    var minISO: Float
    var maxISO: Float
    var minExposureSeconds: Double
    var maxExposureSeconds: Double
    var fieldOfView: Float
    var isBinned: Bool
    var maxZoom: Double
    var isMultiCamSupported: Bool
    /// Variable aperture range (iOS 27+ hardware). nil = fixed aperture.
    var lensApertureRange: ClosedRange<Float>?
    var recommendedApertureStops: [Float]

    var id: Int { index }
    var maxFrameRate: Double { frameRateRanges.map(\.max).max() ?? 0 }
    var resolution: VideoResolution { VideoResolution(width: width, height: height) }

    func supports(fps: Double) -> Bool { frameRateRanges.contains { $0.contains(fps) } }
}

struct VideoResolution: Codable, Hashable, Sendable, Comparable, Identifiable {
    var width: Int
    var height: Int

    var id: String { "\(width)x\(height)" }
    var pixels: Int { width * height }

    var label: String {
        switch (width, height) {
        case (3840, 2160): "4K UHD"
        case (4096, 2160): "4K DCI"
        case (1920, 1080): "1080p"
        case (1280, 720): "720p"
        case (1920, 1440): "1440p 4:3"
        case (4032, 3024): "4032 4:3"
        default: "\(width)×\(height)"
        }
    }

    var shortLabel: String {
        switch height {
        case 2160: "4K"
        case 1080: "HD"
        case 720: "720"
        default: "\(height)p"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.pixels < rhs.pixels }
}

struct CameraDescriptor: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var position: CameraPosition
    var lens: LensKind
    var isVirtual: Bool
    var deviceType: String
    /// Factors where a virtual device switches its physical lens (optical vs crop is meaningful).
    var switchOverZoomFactors: [Double]
    /// Multiplier the UI must apply so the widest lens reads "0.5×" like the system camera (iOS 18+).
    var displayZoomMultiplier: Double
    var minZoom: Double
    var maxZoom: Double
    var fixedAperture: Float
    /// 35mm equivalent focal length when the system reports it (iOS 26+), else estimated from FOV.
    var equivalentFocalLength: Double?
    var formats: [FormatDescriptor]
    var supportsFocusLock: Bool
    var supportsCustomExposure: Bool
    var supportsCustomWhiteBalance: Bool
    var hasTorch: Bool

    var resolutions: [VideoResolution] {
        Array(Set(formats.map(\.resolution))).sorted(by: >)
    }
}

/// Everything the app learned about the phone at launch. Built only from runtime APIs.
struct DeviceCapabilities: Codable, Sendable {
    var modelIdentifier: String
    var systemVersion: String
    var cameras: [CameraDescriptor]
    var isMultiCamSupported: Bool
    var supportsExternalStorage: Bool
    var thermalSensitive: Bool

    var backCameras: [CameraDescriptor] { cameras.filter { $0.position == .back } }
    var supportsProResLikely: Bool { cameras.contains { $0.formats.contains { $0.bitDepth >= 10 } } }
    var supportsLog: Bool { cameras.contains { $0.formats.contains { $0.colorProfiles.contains(where: \.isLog) } } }
    var supportsHLG: Bool { cameras.contains { $0.formats.contains { $0.colorProfiles.contains(.hlg) } } }
    var maxFrameRate: Double { cameras.flatMap(\.formats).map(\.maxFrameRate).max() ?? 0 }
}

/// What the user wants to record. Validated by FormatResolver before it reaches the device.
struct CaptureConfiguration: Codable, Hashable, Sendable {
    var cameraID: String
    var resolution: VideoResolution
    var frameRate: Double
    var colorProfile: ColorProfile
    var codec: VideoCodec
    var stabilization: StabilizationMode

    static func fallback(cameraID: String) -> CaptureConfiguration {
        CaptureConfiguration(cameraID: cameraID,
                             resolution: VideoResolution(width: 1920, height: 1080),
                             frameRate: 30, colorProfile: .rec709, codec: .hevc, stabilization: .standard)
    }

    var summary: String {
        "\(resolution.shortLabel) · \(FrameRateFormatter.string(frameRate)) · \(codec.label) · \(colorProfile.shortLabel)"
    }
}

enum FrameRateFormatter {
    static func string(_ fps: Double) -> String {
        if abs(fps - fps.rounded()) < 0.01 { return "\(Int(fps.rounded()))" }
        return String(format: "%.2f", fps)
    }
}
