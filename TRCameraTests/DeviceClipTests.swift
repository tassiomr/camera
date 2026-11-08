import AVFoundation
import CoreImage
import XCTest
@testable import TRCamera

/// Export tests on clips shaped like real iPhone recordings: HEVC (8 or 10-bit,
/// optionally HLG), recorded in portrait (rotation stored as a track transform,
/// not in the pixels) and with an audio track.
final class DeviceClipTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("trdev-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// Landscape sensor pixels: left half red, right half blue; `portrait` stores a
    /// 90° transform exactly like AVCaptureMovieFileOutput does.
    static func makeDeviceClip(at url: URL, portrait: Bool, hdr: Bool, size: CGSize = CGSize(width: 640, height: 360), frames: Int = 30) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)]
        if hdr {
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ]
            settings[AVVideoCompressionPropertiesKey] = [AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        if portrait { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        let format = hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        let half = CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        let image = CIImage(color: CIColor(red: 0.8, green: 0.15, blue: 0.1)).cropped(to: half)
            .composited(over: CIImage(color: CIColor(red: 0.1, green: 0.2, blue: 0.85)).cropped(to: CGRect(origin: .zero, size: size)))
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pb = try XCTUnwrap(buffer)
            if hdr {
                CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
                CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
                CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
            }
            context.render(image, to: pb)
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        let done = XCTestExpectation(description: "write")
        writer.finishWriting { done.fulfill() }
        XCTWaiter().wait(for: [done], timeout: 30)
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }

    /// Frame as the user sees it (track transform applied), sampled at two points.
    static func displayed(_ url: URL) async throws -> (size: CGSize, top: (Int, Int, Int), bottom: (Int, Int, Int)) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(value: 10, timescale: 30)).image
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        func at(_ x: Int, _ y: Int) -> (Int, Int, Int) { let i = (y * w + x) * 4; return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2])) }
        // CGContext rows start at the top of the image.
        return (CGSize(width: w, height: h), at(w / 2, h / 6), at(w / 2, h * 5 / 6))
    }

    private func check(portrait: Bool, hdr: Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let url = dir.appendingPathComponent("TR_\(portrait ? "p" : "l")\(hdr ? "hdr" : "sdr").mov")
        try Self.makeDeviceClip(at: url, portrait: portrait, hdr: hdr)
        let library = RecordingLibrary(directory: dir)
        let item = try XCTUnwrap(library.items().first { $0.url == url || $0.url.lastPathComponent == url.lastPathComponent })
        let before = try await Self.displayed(url)

        let out = try await library.exportCopy(of: item, look: .mono)
        let after = try await Self.displayed(out)

        XCTAssertEqual(after.size, before.size, "orientation/size changed (portrait \(portrait), hdr \(hdr))", file: file, line: line)
        // Mono: channels equal. Original is clearly coloured.
        for p in [after.top, after.bottom] {
            XCTAssertLessThan(max(abs(p.0 - p.1), abs(p.1 - p.2)), 12, "filter not applied: \(p) (portrait \(portrait), hdr \(hdr))", file: file, line: line)
        }
        // Same layout: the brighter (red→grey) half must stay where red was.
        let lumaBefore = { (p: (Int, Int, Int)) in p.0 * 3 + p.1 * 6 + p.2 }
        XCTAssertEqual(lumaBefore(before.top) > lumaBefore(before.bottom), after.top.0 > after.bottom.0,
                       "image rotated or flipped by export (portrait \(portrait), hdr \(hdr))", file: file, line: line)
    }

    /// Copies must be recognisable in the library even when the source had no sidecar.
    func testCopyOfClipWithoutSidecarIsLabelled() async throws {
        let url = dir.appendingPathComponent("TR_plain.mov")
        try Self.makeDeviceClip(at: url, portrait: true, hdr: false, frames: 10)
        let library = RecordingLibrary(directory: dir)
        let item = try XCTUnwrap(library.items().first)
        XCTAssertNil(item.metadata)
        let out = try await library.exportCopy(of: item, look: .noir)
        let copy = try XCTUnwrap(library.items().first { $0.url.lastPathComponent == out.lastPathComponent })
        XCTAssertEqual(copy.metadata?.editLabel, "Noir")
        XCTAssertNil(item.metadata?.editLabel, "original stays unlabelled")
        // A preview-only look on an original is not an edit.
        var meta = RecordingMetadata.exportedCopy()
        meta.look = "Mono (somente preview)"
        XCTAssertNil(meta.editLabel)
    }

    func testLandscapeSDR() async throws { try await check(portrait: false, hdr: false) }
    func testPortraitSDR() async throws { try await check(portrait: true, hdr: false) }
    func testLandscapeHDR() async throws { try await check(portrait: false, hdr: true) }
    func testPortraitHDR() async throws { try await check(portrait: true, hdr: true) }
}
