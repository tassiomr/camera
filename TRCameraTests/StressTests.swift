import AVFoundation
import CoreImage
import XCTest
@testable import TRCamera

/// Heavier tests: real video files, end-to-end filtered export, preview/export
/// colour parity, randomized compatibility fuzzing and the monitoring pipeline.
final class FilterExportTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("trcam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// Writes a short H.264 clip filled with one colour (BGRA), like a real recording.
    static func makeClip(at url: URL, color: (UInt8, UInt8, UInt8), size: CGSize = CGSize(width: 320, height: 180), frames: Int = 20) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height)
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pb = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pb, [])
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(pb)
            for y in 0..<Int(size.height) {
                for x in 0..<Int(size.width) {
                    let p = base + y * row + x * 4
                    p[0] = color.2; p[1] = color.1; p[2] = color.0; p[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        let done = XCTestExpectation(description: "write")
        writer.finishWriting { done.fulfill() }
        XCTWaiter().wait(for: [done], timeout: 20)
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }

    static func middlePixel(of url: URL) async throws -> (Int, Int, Int) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(value: 10, timescale: 30)).image
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2, width: CGFloat(image.width), height: CGFloat(image.height)))
        return (Int(px[0]), Int(px[1]), Int(px[2]))
    }

    func testExportEveryLookProducesPlayableFile() async throws {
        let library = RecordingLibrary(directory: dir)
        let source = dir.appendingPathComponent("TR_source.mov")
        try Self.makeClip(at: source, color: (200, 90, 50))
        let item = try XCTUnwrap(library.items().first)
        for look in VideoLook.allCases where look != .none {
            let out = try await library.exportCopy(of: item, look: look)
            let inspected = await RecordingLibrary.inspect(out)
            let inspection = try XCTUnwrap(inspected, "\(look)")
            XCTAssertTrue(inspection.isPlayable, "\(look) export not playable")
            XCTAssertEqual(inspection.dimensions, CGSize(width: 320, height: 180), "\(look) changed size")
            XCTAssertGreaterThan(inspection.duration, 0.5, "\(look) lost frames")
        }
        // Original untouched; one copy per look listed in the library.
        XCTAssertEqual(library.items().count, VideoLook.allCases.count)
        let originalSize = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int
        XCTAssertNotNil(originalSize)
    }

    func testExportedMonoIsGreyAndOriginalKeepsColor() async throws {
        let library = RecordingLibrary(directory: dir)
        let source = dir.appendingPathComponent("TR_color.mov")
        try Self.makeClip(at: source, color: (210, 60, 40))
        let item = try XCTUnwrap(library.items().first)
        let out = try await library.exportCopy(of: item, look: .mono)
        let (r, g, b) = try await Self.middlePixel(of: out)
        XCTAssertLessThan(max(abs(r - g), abs(g - b)), 8, "mono export still has color: \(r),\(g),\(b)")
        let (or, _, ob) = try await Self.middlePixel(of: source)
        XCTAssertGreaterThan(or - ob, 100, "original lost its color")
    }

    func testExportWritesSidecarWithLook() async throws {
        let library = RecordingLibrary(directory: dir)
        let source = dir.appendingPathComponent("TR_meta.mov")
        try Self.makeClip(at: source, color: (90, 120, 200))
        let meta = RecordingMetadata(createdAt: Date(), deviceModel: "Test", systemVersion: "27", camera: "W", resolution: "320x180",
                                     frameRate: 30, codec: "H.264", colorProfile: "SDR", stabilization: "Off")
        library.writeSidecar(meta, for: source)
        let item = try XCTUnwrap(library.items().first)
        let out = try await library.exportCopy(of: item, look: .tealOrange)
        let copy = try XCTUnwrap(library.items().first { $0.url.lastPathComponent == out.lastPathComponent })
        XCTAssertEqual(copy.metadata?.look, "Teal & Orange")
    }

    /// The live preview and the exported file must show the same colors.
    func testPreviewAndExportMatch() async throws {
        let library = RecordingLibrary(directory: dir)
        let source = dir.appendingPathComponent("TR_parity.mov")
        try Self.makeClip(at: source, color: (180, 120, 90))
        let item = try XCTUnwrap(library.items().first)
        let srcPixel = try await Self.middlePixel(of: source)
        let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        for look in [VideoLook.tealOrange, .warmFilm, .coolBlue, .vivid, .mono] {
            let input = CIImage(color: CIColor(red: CGFloat(srcPixel.0) / 255, green: CGFloat(srcPixel.1) / 255, blue: CGFloat(srcPixel.2) / 255))
                .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
            var px = [UInt8](repeating: 0, count: 4)
            ctx.render(look.apply(to: input), toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 16, y: 16, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            let out = try await library.exportCopy(of: item, look: look)
            let exported = try await Self.middlePixel(of: out)
            let diff = max(abs(Int(px[0]) - exported.0), abs(Int(px[1]) - exported.1), abs(Int(px[2]) - exported.2))
            XCTAssertLessThan(diff, 14, "\(look): preview \(px[0]),\(px[1]),\(px[2]) vs export \(exported)")
        }
    }
}

final class LookStrengthTests: XCTestCase {
    /// A look that barely changes the image looks broken to users.
    func testEveryLookVisiblyChangesImage() {
        let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let samples: [CIColor] = [CIColor(red: 0.8, green: 0.55, blue: 0.45), CIColor(red: 0.2, green: 0.25, blue: 0.3), CIColor(red: 0.5, green: 0.5, blue: 0.5)]
        for look in VideoLook.allCases where look != .none {
            var maxDelta = 0
            for c in samples {
                let img = CIImage(color: c).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
                var px = [UInt8](repeating: 0, count: 4)
                ctx.render(look.apply(to: img), toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 32, y: 32, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
                let d = max(abs(Int(px[0]) - Int(c.red * 255)), abs(Int(px[1]) - Int(c.green * 255)), abs(Int(px[2]) - Int(c.blue * 255)))
                maxDelta = max(maxDelta, d)
            }
            XCTAssertGreaterThan(maxDelta, 12, "\(look) is too subtle (max Δ \(maxDelta))")
        }
    }

    func testTealOrangeSplitsShadowsAndHighlights() {
        let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        func render(_ v: CGFloat) -> [UInt8] {
            var px = [UInt8](repeating: 0, count: 4)
            let img = CIImage(color: CIColor(red: v, green: v, blue: v)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
            ctx.render(VideoLook.tealOrange.apply(to: img), toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 4, y: 4, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            return px
        }
        let shadow = render(0.15), highlight = render(0.85)
        XCTAssertGreaterThan(Int(shadow[2]), Int(shadow[0]), "shadows should lean teal/blue")
        XCTAssertGreaterThan(Int(highlight[0]), Int(highlight[2]), "highlights should lean orange")
    }
}

final class MonitoringPipelineTests: XCTestCase {
    let processor = MonitoringProcessor()
    let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    /// Every combination of tools must render a finite image of the requested size.
    func testAllToolCombinationsRender() throws {
        let frame = DemoCamera.pattern(size: CGSize(width: 1920, height: 1080), time: 0)
        let lut = BuiltInLUT.appleLogTo709.make(dimension: 17)
        let target = CGSize(width: 390, height: 694)
        var count = 0
        for mask in 0..<32 {
            for look in [VideoLook.none, .tealOrange, .dream] {
                var s = MonitoringSettings()
                s.zebraEnabled = mask & 1 != 0
                s.peakingEnabled = mask & 2 != 0
                s.falseColorEnabled = mask & 4 != 0
                s.lutID = mask & 8 != 0 ? "x" : nil
                s.anamorphicSqueeze = mask & 16 != 0 ? 1.8 : 1
                s.look = look
                let out = processor.process(frame, settings: s, lut: s.lutID == nil ? nil : lut, fitting: target)
                XCTAssertFalse(out.extent.isInfinite, "mask \(mask) \(look) infinite extent")
                XCTAssertLessThanOrEqual(out.extent.width, target.width + 1)
                XCTAssertLessThanOrEqual(out.extent.height, target.height + 1)
                XCTAssertNotNil(ctx.createCGImage(out, from: out.extent), "mask \(mask) \(look) failed to render")
                count += 1
            }
        }
        XCTAssertEqual(count, 96)
    }

    func testZebraMarksOnlyBrightAreas() {
        let dark = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let bright = CIImage(color: .white).cropped(to: CGRect(x: 100, y: 0, width: 100, height: 100))
        let frame = bright.composited(over: dark)
        var s = MonitoringSettings(); s.zebraEnabled = true; s.zebraLevel = 0.9; s.histogramEnabled = false
        let out = processor.process(frame, settings: s, lut: nil, fitting: CGSize(width: 200, height: 100))
        func stripesVisible(in rect: CGRect) -> Bool {
            var px = [UInt8](repeating: 0, count: Int(rect.width * rect.height) * 4)
            ctx.render(out, toBitmap: &px, rowBytes: Int(rect.width) * 4, bounds: rect, format: .RGBA8, colorSpace: nil)
            let lumas = stride(from: 0, to: px.count, by: 4).map { Int(px[$0]) }
            return (lumas.max() ?? 0) - (lumas.min() ?? 0) > 60
        }
        XCTAssertFalse(stripesVisible(in: CGRect(x: 20, y: 20, width: 40, height: 40)), "zebra on dark area")
        XCTAssertTrue(stripesVisible(in: CGRect(x: 130, y: 20, width: 40, height: 40)), "no zebra on clipped area")
    }

    func testFalseColorMapsClippedToRed() {
        let frame = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 50, height: 50))
        var s = MonitoringSettings(); s.falseColorEnabled = true
        let out = processor.process(frame, settings: s, lut: nil, fitting: CGSize(width: 50, height: 50))
        var px = [UInt8](repeating: 0, count: 4)
        ctx.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 25, y: 25, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        XCTAssertGreaterThan(Int(px[0]), 200); XCTAssertLessThan(Int(px[1]), 80)
    }

    func testProcessFrameDrivesScopesAndFrameClock() {
        var s = MonitoringSettings(); s.histogramEnabled = true
        processor.update(settings: s, lut: nil)
        XCTAssertGreaterThan(processor.secondsSinceLastFrame, 1000, "no frame yet must read as stale")
        let got = expectation(description: "scopes")
        processor.onScopes = { _ in got.fulfill() }
        processor.queue.async { self.processor.processFrame(DemoCamera.pattern(size: CGSize(width: 640, height: 360), time: 0)) }
        wait(for: [got], timeout: 5)
        // Includes first-time Core Image setup on the Simulator; on device this is milliseconds.
        XCTAssertLessThan(processor.secondsSinceLastFrame, 30)
    }
}

final class CompatibilityFuzzTests: XCTestCase {
    /// Random requests against every demo/fixture camera must always resolve to a
    /// configuration the chosen format really supports.
    func testRandomRequestsAlwaysResolveToSupportedFormats() throws {
        var rng = SystemRandomNumberGenerator()
        let cameras = DemoCamera.capabilities.cameras + [Fixtures.proCamera, Fixtures.basicCamera]
        let resolutions = [VideoResolution(width: 1280, height: 720), .init(width: 1920, height: 1080), .init(width: 3840, height: 2160),
                           .init(width: 4096, height: 2160), .init(width: 640, height: 480)]
        let fpsList: [Double] = [23.976, 24, 25, 29.97, 30, 48, 50, 60, 100, 120, 240, 1000]
        for _ in 0..<3000 {
            let cam = cameras.randomElement(using: &rng)!
            let req = CaptureConfiguration(cameraID: "x", resolution: resolutions.randomElement(using: &rng)!, frameRate: fpsList.randomElement(using: &rng)!,
                                           colorProfile: ColorProfile.allCases.randomElement(using: &rng)!, codec: VideoCodec.allCases.randomElement(using: &rng)!,
                                           stabilization: StabilizationMode.allCases.filter { $0 != .auto }.randomElement(using: &rng)!)
            let codecs = Bool.random(using: &rng) ? nil : Array(VideoCodec.allCases.shuffled(using: &rng).prefix(Int.random(in: 1...4, using: &rng)))
            let r = try XCTUnwrap(FormatResolver(camera: cam).resolve(req, availableCodecs: codecs), "\(req)")
            let c = r.configuration
            XCTAssertEqual(c.cameraID, cam.id)
            XCTAssertEqual(r.format.resolution, c.resolution)
            XCTAssertTrue(r.format.supports(fps: c.frameRate), "\(c.frameRate) not in \(r.format.frameRateRanges)")
            XCTAssertTrue(r.format.colorProfiles.contains(c.colorProfile), "\(c.colorProfile) not in format")
            XCTAssertTrue(c.stabilization == .off || r.format.stabilizationModes.contains(c.stabilization))
            if let codecs { XCTAssertTrue(codecs.contains(c.codec), "\(c.codec) not in \(codecs)") }
            if c != req.with(cameraID: cam.id) { XCTAssertFalse(r.adjustments.isEmpty, "silent change \(req) → \(c)") }
        }
    }

    func testEveryAdvisorGoalOnEveryCamera() {
        for cam in DemoCamera.capabilities.cameras + [Fixtures.proCamera, Fixtures.basicCamera] {
            for goal in RecordingConfigurationAdvisor.Goal.allCases {
                let rec = RecordingConfigurationAdvisor().recommend(goal, context: .init(camera: cam, freeBytes: 50_000_000_000, thermalElevated: true, knownCodecs: nil))
                if rec.available {
                    XCTAssertNotNil(FormatResolver(camera: cam).resolve(rec.configuration), "\(goal) on \(cam.id)")
                } else {
                    XCTAssertFalse(rec.limitations.isEmpty, "\(goal) unavailable without explanation")
                }
            }
        }
    }

    func testOptionListsAreConsistentWithResolver() {
        for cam in DemoCamera.capabilities.cameras {
            let r = FormatResolver(camera: cam)
            for res in r.resolutions() {
                for fps in r.frameRates(for: res) {
                    for profile in r.colorProfiles(for: res, fps: fps) {
                        let req = CaptureConfiguration(cameraID: cam.id, resolution: res, frameRate: fps, colorProfile: profile, codec: .hevc, stabilization: .off)
                        let resolved = r.resolve(req)
                        XCTAssertEqual(resolved?.configuration, req, "an offered option was changed: \(req)")
                    }
                }
            }
        }
    }

    func testShutterStepsForEveryOfferedRate() {
        for fps in FormatResolver(camera: Fixtures.proCamera).frameRates(for: .init(width: 1920, height: 1080)) {
            let steps = ExposureMath.shutterSteps(fps: fps, minExposure: 1.0 / 24000, maxExposure: 1.0 / 3)
            XCTAssertFalse(steps.isEmpty, "no shutter steps at \(fps)")
            XCTAssertTrue(steps.allSatisfy { $0 <= 1 / fps + 1e-9 })
            XCTAssertFalse(ExposureMath.angleSteps(fps: fps, minExposure: 1.0 / 24000, maxExposure: 1.0 / 3).isEmpty)
        }
    }
}

final class StorageStressTests: XCTestCase {
    func testLibraryHandlesRenameDeleteAndJunkFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = RecordingLibrary(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = dir.appendingPathComponent("TR_a.mov")
        try FilterExportTests.makeClip(at: clip, color: (10, 20, 30), frames: 5)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("TR_a.json"))
        try Data().write(to: dir.appendingPathComponent("notes.txt"))
        var items = library.items()
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items[0].metadata, "corrupt sidecar must not crash")
        let renamed = try library.rename(items[0], to: "Cena 1 / take:2")
        XCTAssertEqual(renamed.lastPathComponent, "Cena 1 take2.mov")
        items = library.items()
        try library.delete(items[0])
        XCTAssertTrue(library.items().isEmpty)
    }

    func testRefusesToRecordWithoutSpace() {
        let library = RecordingLibrary(directory: FileManager.default.temporaryDirectory)
        XCTAssertThrowsError(try library.nextURL(destination: .appStorage, minimumBytes: Int64.max / 2))
    }

    func testMetadataItemsCarryTechnicalJSON() throws {
        let meta = RecordingMetadata(createdAt: Date(), deviceModel: "iPhone17,1", systemVersion: "27.2", camera: "W", resolution: "3840x2160",
                                     frameRate: 24, codec: "HEVC", colorProfile: "Apple Log", stabilization: "Standard", iso: 400, shutter: "1/48")
        let items = RecordingLibrary.metadataItems(for: meta)
        let description = try XCTUnwrap(items.first { $0.identifier == .quickTimeMetadataDescription }?.stringValue)
        XCTAssertTrue(description.contains("\"shutter\":\"1\\/48\""))
        XCTAssertFalse(description.lowercased().contains("location"))
    }
}

private extension CaptureConfiguration {
    func with(cameraID: String) -> CaptureConfiguration { var c = self; c.cameraID = cameraID; return c }
}
