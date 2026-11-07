import AVFoundation
import Photos
import UIKit

/// Technical facts written next to each clip as JSON (no location, no personal data).
struct RecordingMetadata: Codable, Hashable {
    var createdAt: Date
    var deviceModel: String
    var systemVersion: String
    var camera: String
    var resolution: String
    var frameRate: Double
    var codec: String
    var colorProfile: String
    var stabilization: String
    var iso: Float?
    var shutter: String?
    var whiteBalanceKelvin: Float?
    var equivalentFocalLength: Double?
    var zoom: Double?
    var lut: String?
    var look: String? = nil
}

struct RecordingItem: Identifiable, Hashable {
    var url: URL
    var metadata: RecordingMetadata?
    var fileSize: Int64
    var createdAt: Date
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// Measured from the file itself after recording: proves what was actually written.
struct FileInspection {
    var codec: String
    var dimensions: CGSize
    var nominalFrameRate: Float
    var duration: Double
    var audioTracks: Int
    var audioChannels: Int
    var transferFunction: String?
    var colorPrimaries: String?
    var isPlayable: Bool
}

enum RecordingDestination: Equatable {
    case appStorage
    case external(name: String)
}

final class RecordingLibrary {
    enum StorageError: LocalizedError {
        case insufficientSpace(available: Int64, needed: Int64)
        case externalUnavailable
        var errorDescription: String? {
            switch self {
            case .insufficientSpace(let a, let n):
                "Espaço insuficiente: \(StorageEstimator.format(bytes: Double(a))) livres, mínimo recomendado \(StorageEstimator.format(bytes: Double(n)))."
            case .externalUnavailable: "Armazenamento externo indisponível."
            }
        }
    }

    let directory: URL

    init() {
        directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var freeBytes: Int64? { StorageEstimator.freeBytes(at: directory) }

    // MARK: Destinations

    /// Direct-to-drive recording through the official AVExternalStorageDevice API (iOS 17+).
    static func externalDevice() -> AVExternalStorageDevice? {
        guard AVExternalStorageDeviceDiscoverySession.isSupported else { return nil }
        return AVExternalStorageDeviceDiscoverySession.shared?.externalStorageDevices.first { $0.isConnected }
    }

    static func requestExternalAccess() async -> Bool {
        if AVExternalStorageDevice.authorizationStatus == .authorized { return true }
        return await withCheckedContinuation { cont in
            AVExternalStorageDevice.requestAccess { cont.resume(returning: $0) }
        }
    }

    /// Returns the URL the next clip will be written to, after checking free space.
    func nextURL(destination: RecordingDestination, minimumBytes: Int64) throws -> URL {
        switch destination {
        case .appStorage:
            let free = freeBytes ?? 0
            guard free > minimumBytes else { throw StorageError.insufficientSpace(available: free, needed: minimumBytes) }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            return directory.appendingPathComponent("TR_\(formatter.string(from: Date())).mov")
        case .external:
            guard let device = Self.externalDevice() else { throw StorageError.externalUnavailable }
            guard Int64(device.freeSize) > minimumBytes else { throw StorageError.insufficientSpace(available: Int64(device.freeSize), needed: minimumBytes) }
            guard let url = try device.nextAvailableURLs(withPathExtensions: ["mov"]).first else { throw StorageError.externalUnavailable }
            return url
        }
    }

    // MARK: Metadata

    static func metadataItems(for meta: RecordingMetadata) -> [AVMetadataItem] {
        func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value as NSString
            m.dataType = kCMMetadataBaseDataType_UTF8 as String
            return m
        }
        let summary = (try? String(data: JSONEncoder().encode(meta), encoding: .utf8)) ?? ""
        return [
            item(.quickTimeMetadataMake, "Apple"),
            item(.quickTimeMetadataModel, meta.deviceModel),
            item(.quickTimeMetadataSoftware, "TR Camera"),
            item(.quickTimeMetadataCreationDate, ISO8601DateFormatter().string(from: meta.createdAt)),
            item(.quickTimeMetadataDescription, summary)
        ]
    }

    func writeSidecar(_ meta: RecordingMetadata, for url: URL) {
        let sidecar = url.deletingPathExtension().appendingPathExtension("json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(meta).write(to: sidecar, options: .atomic)
        } catch {
            Log.storage.error("Sidecar write failed: \(error.localizedDescription)")
        }
    }

    // MARK: Listing & management

    func items() -> [RecordingItem] {
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.filter { ["mov", "mp4"].contains($0.pathExtension.lowercased()) }.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let sidecar = url.deletingPathExtension().appendingPathExtension("json")
            let meta = (try? Data(contentsOf: sidecar)).flatMap { try? decoder.decode(RecordingMetadata.self, from: $0) }
            return RecordingItem(url: url, metadata: meta, fileSize: Int64(values?.fileSize ?? 0), createdAt: values?.creationDate ?? .distantPast)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func rename(_ item: RecordingItem, to newName: String) throws -> URL {
        let clean = newName.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined().trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return item.url }
        let dest = directory.appendingPathComponent(clean).appendingPathExtension(item.url.pathExtension)
        try FileManager.default.moveItem(at: item.url, to: dest)
        let oldSidecar = item.url.deletingPathExtension().appendingPathExtension("json")
        if FileManager.default.fileExists(atPath: oldSidecar.path) {
            try? FileManager.default.moveItem(at: oldSidecar, to: dest.deletingPathExtension().appendingPathExtension("json"))
        }
        return dest
    }

    func delete(_ item: RecordingItem) throws {
        try FileManager.default.removeItem(at: item.url)
        try? FileManager.default.removeItem(at: item.url.deletingPathExtension().appendingPathExtension("json"))
    }

    static func saveToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "TRCamera", code: 1, userInfo: [NSLocalizedDescriptionKey: "Sem permissão para salvar em Fotos."])
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
        }
    }

    /// Renders a new file with the look baked in. The original clip is never modified.
    func exportCopy(of item: RecordingItem, look: VideoLook) async throws -> URL {
        let asset = AVURLAsset(url: item.url)
        let composition = try await AVVideoComposition.videoComposition(with: asset) { request in
            let source = request.sourceImage
            request.finish(with: look.apply(to: source.clampedToExtent()).cropped(to: source.extent), context: nil)
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVCHighestQuality) else {
            throw NSError(domain: "TRCamera", code: 2, userInfo: [NSLocalizedDescriptionKey: "Exportação indisponível para este arquivo."])
        }
        session.videoComposition = composition
        let output = directory.appendingPathComponent("\(item.name)_\(look.rawValue).mov")
        try? FileManager.default.removeItem(at: output)
        if #available(iOS 18.0, *) {
            try await session.export(to: output, as: .mov)
        } else {
            session.outputURL = output
            session.outputFileType = .mov
            await session.export()
            if let error = session.error { throw error }
        }
        if var meta = item.metadata {
            meta.createdAt = Date()
            meta.look = look.title
            writeSidecar(meta, for: output)
        }
        return output
    }

    static func thumbnail(for url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)
        guard let result = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)) else { return nil }
        return UIImage(cgImage: result.image)
    }

    static func inspect(_ url: URL) async -> FileInspection? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.load(.tracks), let duration = try? await asset.load(.duration) else { return nil }
        let video = tracks.first { $0.mediaType == .video }
        let audio = tracks.filter { $0.mediaType == .audio }
        var codec = "—", size = CGSize.zero, fps: Float = 0, transfer: String?, primaries: String?
        if let video {
            if let descs = try? await video.load(.formatDescriptions), let desc = descs.first {
                codec = CameraCapabilityEngine.fourCCString(CMFormatDescriptionGetMediaSubType(desc))
                let ext = CMFormatDescriptionGetExtensions(desc) as? [String: Any]
                transfer = ext?[kCVImageBufferTransferFunctionKey as String] as? String
                primaries = ext?[kCVImageBufferColorPrimariesKey as String] as? String
            }
            size = (try? await video.load(.naturalSize)) ?? .zero
            fps = (try? await video.load(.nominalFrameRate)) ?? 0
        }
        var channels = 0
        for track in audio {
            if let descs = try? await track.load(.formatDescriptions), let d = descs.first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d) {
                channels += Int(asbd.pointee.mChannelsPerFrame)
            }
        }
        let playable = (try? await asset.load(.isPlayable)) ?? false
        return FileInspection(codec: codec, dimensions: size, nominalFrameRate: fps, duration: duration.seconds,
                              audioTracks: audio.count, audioChannels: channels, transferFunction: transfer,
                              colorPrimaries: primaries, isPlayable: playable)
    }
}
