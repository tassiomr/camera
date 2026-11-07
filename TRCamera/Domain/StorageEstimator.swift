import Foundation

/// Storage estimates for a configuration. Always labelled as estimates in the UI.
enum StorageEstimator {
    /// Video + ~256 kbps AAC stereo audio, in bytes per second.
    static func bytesPerSecond(resolution: VideoResolution, fps: Double, codec: VideoCodec) -> Double {
        let videoBits = Double(resolution.pixels) * fps * codec.bitsPerPixel
        let audioBits = 256_000.0
        return (videoBits + audioBits) / 8.0
    }

    static func bytesPerMinute(_ config: CaptureConfiguration) -> Double {
        bytesPerSecond(resolution: config.resolution, fps: config.frameRate, codec: config.codec) * 60
    }

    static func minutesRemaining(freeBytes: Int64, config: CaptureConfiguration, reserveBytes: Int64 = 500_000_000) -> Double {
        let usable = max(0, Double(freeBytes - reserveBytes))
        let perMinute = bytesPerMinute(config)
        guard perMinute > 0 else { return 0 }
        return usable / perMinute
    }

    static func format(bytes: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func format(minutes: Double) -> String {
        if minutes.isInfinite || minutes.isNaN { return "—" }
        if minutes >= 120 { return String(format: "%.1f h", minutes / 60) }
        return "\(Int(minutes)) min"
    }

    static func freeBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        if let plain = values?.volumeAvailableCapacity { return Int64(plain) }
        return nil
    }
}
