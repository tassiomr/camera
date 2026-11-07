import AVFoundation
import UIKit

/// Discovers what this specific iPhone can capture, using only runtime APIs.
/// No model table is used to decide features: if AVFoundation does not report a
/// capability, the app does not offer it.
enum CameraCapabilityEngine {
    static let videoDeviceTypes: [AVCaptureDevice.DeviceType] = {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera,
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera,
            .builtInTrueDepthCamera, .external
        ]
        return types
    }()

    static func discover() -> DeviceCapabilities {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: videoDeviceTypes, mediaType: .video, position: .unspecified)
        var cameras = session.devices.map(describe)
        // Order: back physical lenses by zoom, then virtual, then front, then external.
        cameras.sort { a, b in
            func rank(_ c: CameraDescriptor) -> Int {
                switch c.lens {
                case .ultraWide: 0
                case .wide: 1
                case .telephoto: 2
                case .virtualMulti: 3
                case .frontWide: 4
                case .frontUltraWide: 5
                case .external: 6
                case .other: 7
                }
            }
            return rank(a) == rank(b) ? (a.equivalentFocalLength ?? 0) < (b.equivalentFocalLength ?? 0) : rank(a) < rank(b)
        }
        return DeviceCapabilities(
            modelIdentifier: modelIdentifier(),
            systemVersion: UIDevice.current.systemVersion,
            cameras: cameras,
            isMultiCamSupported: AVCaptureMultiCamSession.isMultiCamSupported,
            supportsExternalStorage: AVExternalStorageDeviceDiscoverySession.isSupported,
            thermalSensitive: ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        )
    }

    static func describe(_ device: AVCaptureDevice) -> CameraDescriptor {
        let lens: LensKind
        switch (device.position, device.deviceType) {
        case (_, .external): lens = .external
        case (.front, .builtInUltraWideCamera): lens = .frontUltraWide
        case (.front, _): lens = .frontWide
        case (_, .builtInUltraWideCamera): lens = .ultraWide
        case (_, .builtInWideAngleCamera): lens = .wide
        case (_, .builtInTelephotoCamera): lens = .telephoto
        case (_, .builtInTripleCamera), (_, .builtInDualWideCamera), (_, .builtInDualCamera): lens = .virtualMulti
        default: lens = .other
        }
        let position: CameraPosition = device.deviceType == .external ? .external : (device.position == .front ? .front : .back)
        let formats = device.formats.enumerated().compactMap { describe(format: $0.element, index: $0.offset) }

        var multiplier = 1.0
        if #available(iOS 18.0, *) { multiplier = Double(device.displayVideoZoomFactorMultiplier) }

        var focal: Double? = nil
        if #available(iOS 26.0, *) {
            let value = Double(device.nominalFocalLengthIn35mmFilm)
            if value > 0 { focal = value }
        }
        if focal == nil, let fov = device.activeFormat.videoFieldOfView as Float?, fov > 0 {
            // Horizontal FOV → 35mm equivalent (36 mm wide frame). Labelled "≈" in the UI.
            focal = 18.0 / tan(Double(fov) * .pi / 360.0)
        }

        return CameraDescriptor(
            id: device.uniqueID,
            name: device.localizedName,
            position: position,
            lens: lens,
            isVirtual: device.isVirtualDevice,
            deviceType: device.deviceType.rawValue,
            switchOverZoomFactors: device.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue),
            displayZoomMultiplier: multiplier,
            minZoom: Double(device.minAvailableVideoZoomFactor),
            maxZoom: Double(device.maxAvailableVideoZoomFactor),
            fixedAperture: device.lensAperture,
            equivalentFocalLength: focal,
            formats: formats,
            supportsFocusLock: device.isLockingFocusWithCustomLensPositionSupported,
            supportsCustomExposure: device.isExposureModeSupported(.custom),
            supportsCustomWhiteBalance: device.isLockingWhiteBalanceWithCustomDeviceGainsSupported,
            hasTorch: device.hasTorch
        )
    }

    static func describe(format: AVCaptureDevice.Format, index: Int) -> FormatDescriptor? {
        let desc = format.formatDescription
        guard CMFormatDescriptionGetMediaType(desc) == kCMMediaType_Video else { return nil }
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        let subtype = CMFormatDescriptionGetMediaSubType(desc)
        let fourCC = fourCCString(subtype)
        let profiles = format.supportedColorSpaces.compactMap { ColorProfile(captureColorSpaceRawValue: $0.rawValue) }
        let stabilization = StabilizationMode.allCases.filter { mode in
            guard mode != .auto, let av = AVCaptureVideoStabilizationMode(rawValue: mode.rawValue) else { return false }
            return format.isVideoStabilizationModeSupported(av)
        }

        var apertureRange: ClosedRange<Float>? = nil
        var stops: [Float] = []
        if #available(iOS 27.0, *) {
            if format.maxLensAperture > format.minLensAperture {
                apertureRange = format.minLensAperture...format.maxLensAperture
                stops = format.recommendedLensApertureStops.map { Float($0) }
            }
        }

        return FormatDescriptor(
            index: index,
            width: Int(dims.width),
            height: Int(dims.height),
            frameRateRanges: format.videoSupportedFrameRateRanges.map { FrameRateRange(min: $0.minFrameRate, max: $0.maxFrameRate) },
            pixelFormat: fourCC,
            bitDepth: bitDepth(for: fourCC),
            colorProfiles: profiles,
            isVideoHDRSupported: format.isVideoHDRSupported,
            stabilizationModes: stabilization,
            minISO: format.minISO,
            maxISO: format.maxISO,
            minExposureSeconds: format.minExposureDuration.seconds,
            maxExposureSeconds: format.maxExposureDuration.seconds,
            fieldOfView: format.videoFieldOfView,
            isBinned: format.isVideoBinned,
            maxZoom: Double(format.videoMaxZoomFactor),
            isMultiCamSupported: format.isMultiCamSupported,
            lensApertureRange: apertureRange,
            recommendedApertureStops: stops
        )
    }

    /// 'x420', 'x422', 'xf20'… are 10-bit; '420v'/'420f' are 8-bit.
    static func bitDepth(for fourCC: String) -> Int {
        if fourCC.hasPrefix("x") || fourCC.hasPrefix("&") || fourCC.hasPrefix("p") { return 10 }
        return 8
    }

    static func fourCCString(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff), UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "\(code)"
    }

    /// e.g. "iPhone17,1". Informational only — never used to gate features.
    static func modelIdentifier() -> String {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "Simulator"
        #else
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        #endif
    }
}
