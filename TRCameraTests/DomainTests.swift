import XCTest
@testable import TRCamera

/// Synthetic camera resembling a Pro back wide lens; no hardware needed.
enum Fixtures {
    static func format(_ index: Int, _ w: Int, _ h: Int, fps: Double, profiles: [ColorProfile], binned: Bool = false,
                       stab: [StabilizationMode] = [.off, .standard, .cinematic, .cinematicExtended], bitDepth: Int = 10) -> FormatDescriptor {
        FormatDescriptor(index: index, width: w, height: h, frameRateRanges: [FrameRateRange(min: 1, max: fps)],
                         pixelFormat: bitDepth == 10 ? "x420" : "420v", bitDepth: bitDepth, colorProfiles: profiles,
                         isVideoHDRSupported: true, stabilizationModes: stab, minISO: 32, maxISO: 3072,
                         minExposureSeconds: 1.0 / 24000, maxExposureSeconds: 1.0 / 3, fieldOfView: 70, isBinned: binned,
                         maxZoom: 100, isMultiCamSupported: false, lensApertureRange: nil, recommendedApertureStops: [])
    }

    static var proCamera: CameraDescriptor {
        CameraDescriptor(id: "wide", name: "Back Camera", position: .back, lens: .wide, isVirtual: false, deviceType: "wide",
                         switchOverZoomFactors: [], displayZoomMultiplier: 1, minZoom: 1, maxZoom: 10, fixedAperture: 1.78,
                         equivalentFocalLength: 24,
                         formats: [
                            format(0, 1920, 1080, fps: 240, profiles: [.rec709], binned: true, stab: [.off, .standard], bitDepth: 8),
                            format(1, 1920, 1080, fps: 60, profiles: [.rec709, .p3, .hlg, .appleLog]),
                            format(2, 3840, 2160, fps: 30, profiles: [.rec709, .hlg, .appleLog, .appleLog2]),
                            format(3, 3840, 2160, fps: 60, profiles: [.rec709, .hlg], stab: [.off, .standard]),
                            format(4, 3840, 2160, fps: 120, profiles: [.rec709], binned: true, stab: [.off], bitDepth: 8)
                         ],
                         supportsFocusLock: true, supportsCustomExposure: true, supportsCustomWhiteBalance: true, hasTorch: true)
    }

    static var basicCamera: CameraDescriptor {
        var c = proCamera
        c.formats = [format(0, 1920, 1080, fps: 30, profiles: [.rec709], stab: [.off, .standard], bitDepth: 8),
                     format(1, 3840, 2160, fps: 30, profiles: [.rec709], stab: [.off, .standard], bitDepth: 8)]
        return c
    }
}

final class ExposureMathTests: XCTestCase {
    func testShutterAngle180At24IsOneOver48() {
        XCTAssertEqual(ExposureMath.exposureDuration(shutterAngle: 180, fps: 24), 1.0 / 48, accuracy: 1e-9)
    }

    func testAngleRoundTrip() {
        for fps in [24.0, 25, 30, 60, 120] {
            for angle in [45.0, 90, 180, 270, 360] {
                let e = ExposureMath.exposureDuration(shutterAngle: angle, fps: fps)
                XCTAssertEqual(ExposureMath.shutterAngle(exposure: e, fps: fps), angle, accuracy: 1e-6)
            }
        }
    }

    func testShutterStepsNeverExceedFrameDuration() {
        let steps = ExposureMath.shutterSteps(fps: 60, minExposure: 1.0 / 24000, maxExposure: 1.0 / 3)
        XCTAssertTrue(steps.allSatisfy { $0 <= 1.0 / 60 + 1e-9 })
        XCTAssertTrue(steps.contains { abs($0 - 1.0 / 120) < 1e-9 }, "180° at 60 fps must be offered")
    }

    func testAngleStepsRespectLimits() {
        let angles = ExposureMath.angleSteps(fps: 24, minExposure: 1.0 / 1000, maxExposure: 1)
        XCTAssertTrue(angles.contains(45)) // 45° @24 = 1/192 s, within limits
        XCTAssertTrue(angles.contains(180))
        XCTAssertTrue(angles.contains(360))
    }

    func testISOStepsClampToFormat() {
        let steps = ExposureMath.isoSteps(min: 32, max: 3072)
        XCTAssertEqual(steps.first, 32)
        XCTAssertEqual(steps.last, 3072)
        XCTAssertTrue(steps.allSatisfy { (32...3072).contains($0) })
    }

    func testShutterLabels() {
        XCTAssertEqual(ExposureMath.shutterLabel(1.0 / 48), "1/48")
        XCTAssertEqual(ExposureMath.angleLabel(180), "180°")
        XCTAssertEqual(ExposureMath.angleLabel(172.8), "172.8°")
    }
}

final class FormatResolverTests: XCTestCase {
    let resolver = FormatResolver(camera: Fixtures.proCamera)

    func testOffersOnlyReportedFrameRates() {
        let uhd = VideoResolution(width: 3840, height: 2160)
        let rates = resolver.frameRates(for: uhd)
        XCTAssertTrue(rates.contains(120))
        XCTAssertFalse(rates.contains(240))
        XCTAssertEqual(resolver.frameRates(for: VideoResolution(width: 1920, height: 1080)).max(), 240)
    }

    func testLogNotOfferedAt4K60() {
        let profiles = resolver.colorProfiles(for: VideoResolution(width: 3840, height: 2160), fps: 60)
        XCTAssertFalse(profiles.contains(.appleLog))
        XCTAssertTrue(profiles.contains(.hlg))
    }

    func testExactMatchPicksNonBinnedFormat() throws {
        let req = CaptureConfiguration(cameraID: "wide", resolution: .init(width: 3840, height: 2160), frameRate: 30,
                                       colorProfile: .rec709, codec: .hevc, stabilization: .cinematicExtended)
        let r = try XCTUnwrap(resolver.resolve(req))
        XCTAssertEqual(r.format.index, 2)
        XCTAssertTrue(r.adjustments.isEmpty)
    }

    func testImpossibleComboIsRepairedWithExplanation() throws {
        // 4K 60 Apple Log does not exist in the fixture → profile falls back to HLG.
        let req = CaptureConfiguration(cameraID: "wide", resolution: .init(width: 3840, height: 2160), frameRate: 60,
                                       colorProfile: .appleLog, codec: .hevc, stabilization: .cinematicExtended)
        let r = try XCTUnwrap(resolver.resolve(req))
        XCTAssertEqual(r.configuration.colorProfile, .hlg)
        XCTAssertEqual(r.configuration.stabilization, .standard)
        XCTAssertEqual(r.adjustments.count, 2)
    }

    func testUnsupportedResolutionFallsBackToClosest() throws {
        let req = CaptureConfiguration(cameraID: "wide", resolution: .init(width: 4096, height: 2160), frameRate: 24,
                                       colorProfile: .rec709, codec: .hevc, stabilization: .off)
        let r = try XCTUnwrap(resolver.resolve(req))
        XCTAssertEqual(r.configuration.resolution, VideoResolution(width: 3840, height: 2160))
    }

    func testProResFallsBackToHEVCWhenNotReported() throws {
        let req = CaptureConfiguration(cameraID: "wide", resolution: .init(width: 1920, height: 1080), frameRate: 30,
                                       colorProfile: .hlg, codec: .proRes422HQ, stabilization: .off)
        let r = try XCTUnwrap(resolver.resolve(req, availableCodecs: [.hevc, .h264]))
        XCTAssertEqual(r.configuration.codec, .hevc)
    }

    func testProResVariantSubstitution() {
        XCTAssertEqual(FormatResolver.fallbackCodec(for: .proRes4444, profile: .appleLog, among: [.hevc, .proRes422, .proRes422LT]), .proRes422)
    }

    func testFrameDurationForNTSCRates() {
        let d = ProfessionalCaptureEngine.frameDuration(29.97)
        XCTAssertEqual(d.value, 1001)
        XCTAssertEqual(d.timescale, 30000)
        XCTAssertEqual(ProfessionalCaptureEngine.frameDuration(24).timescale, 24)
    }
}

final class AdvisorAndPresetTests: XCTestCase {
    func context(_ camera: CameraDescriptor, free: Int64? = 100_000_000_000) -> RecordingConfigurationAdvisor.Context {
        .init(camera: camera, freeBytes: free, thermalElevated: false, knownCodecs: nil)
    }

    func testCinematicUses24And180() {
        let rec = RecordingConfigurationAdvisor().recommend(.cinematic, context: context(Fixtures.proCamera))
        XCTAssertEqual(rec.configuration.frameRate, 24)
        XCTAssertEqual(rec.shutterAngle, 180)
        XCTAssertTrue(rec.available)
    }

    func testLogUnavailableOnBasicCamera() {
        let rec = RecordingConfigurationAdvisor().recommend(.editingLog, context: context(Fixtures.basicCamera))
        XCTAssertFalse(rec.available)
        XCTAssertFalse(rec.limitations.isEmpty)
    }

    func testLogPrefersLog2WhenAvailable() {
        let rec = RecordingConfigurationAdvisor().recommend(.editingLog, context: context(Fixtures.proCamera))
        XCTAssertEqual(rec.configuration.colorProfile, .appleLog2)
    }

    func testHighMotionPicksHighFrameRate() {
        let rec = RecordingConfigurationAdvisor().recommend(.highMotion, context: context(Fixtures.proCamera))
        XCTAssertGreaterThanOrEqual(rec.configuration.frameRate, 60)
    }

    func testLowStorageWarns() {
        let rec = RecordingConfigurationAdvisor().recommend(.automatic, context: context(Fixtures.proCamera, free: 700_000_000))
        XCTAssertTrue(rec.limitations.contains { $0.contains("Pouco espaço") })
    }

    func testPresetValidationListsSubstitutions() throws {
        var preset = CapturePreset(name: "Test", isBuiltIn: false)
        preset.configuration = CaptureConfiguration(cameraID: "wide", resolution: .init(width: 3840, height: 2160), frameRate: 60,
                                                    colorProfile: .appleLog, codec: .hevc, stabilization: .off)
        preset.exposure.iso = 10_000
        let v = try XCTUnwrap(PresetValidator.validate(preset, camera: Fixtures.basicCamera, knownCodecs: nil))
        XCTAssertEqual(v.configuration.frameRate, 30)
        XCTAssertEqual(v.configuration.colorProfile, .rec709)
        XCTAssertTrue(v.substitutions.contains { $0.contains("ISO") })
    }

    func testPresetRoundTripsThroughStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = PresetStore(directory: dir)
        let preset = CapturePreset(name: "A", isBuiltIn: false, configuration: .fallback(cameraID: "x"))
        try store.save([preset, BuiltInPresets.make(for: .cinematic)])
        XCTAssertEqual(store.load().map(\.name), ["A"])
    }
}

final class StorageAndLUTTests: XCTestCase {
    func testHEVC4K30MatchesAppleFigure() {
        let config = CaptureConfiguration(cameraID: "", resolution: .init(width: 3840, height: 2160), frameRate: 30,
                                          colorProfile: .rec709, codec: .hevc, stabilization: .off)
        let mbPerMin = StorageEstimator.bytesPerMinute(config) / 1_000_000
        XCTAssertEqual(mbPerMin, 172, accuracy: 15) // Apple: ~170 MB/min
    }

    func testProResIsMuchLargerThanHEVC() {
        var c = CaptureConfiguration.fallback(cameraID: "")
        let hevc = StorageEstimator.bytesPerMinute(c)
        c.codec = .proRes422HQ
        XCTAssertGreaterThan(StorageEstimator.bytesPerMinute(c) / hevc, 20)
    }

    func testMinutesRemainingKeepsReserve() {
        XCTAssertEqual(StorageEstimator.minutesRemaining(freeBytes: 400_000_000, config: .fallback(cameraID: "")), 0)
    }

    func testCubeParse() throws {
        let text = """
        TITLE "Identity"
        # comment
        LUT_3D_SIZE 2
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """
        let lut = try CubeLUT.parse(text)
        XCTAssertEqual(lut.title, "Identity")
        XCTAssertEqual(lut.dimension, 2)
        XCTAssertEqual(lut.data.count, 8 * 4 * MemoryLayout<Float>.size)
    }

    func testCubeRejectsWrongCount() {
        XCTAssertThrowsError(try CubeLUT.parse("LUT_3D_SIZE 2\n0 0 0\n"))
        XCTAssertThrowsError(try CubeLUT.parse("LUT_1D_SIZE 1024\n"))
    }

    func testAppleLogCurveRoundTripAndGrey() {
        for r in [0.0, 0.005, 0.01, 0.18, 1, 4] {
            XCTAssertEqual(AppleLogCurve.decode(AppleLogCurve.encode(r)), r, accuracy: 1e-4)
        }
        let grey = AppleLogCurve.encode(0.18)
        XCTAssertTrue((0.45...0.52).contains(grey), "18% grey encodes near 48%: \(grey)")
        XCTAssertEqual(AppleLogCurve.encode(AppleLogCurve.rt), AppleLogCurve.pt, accuracy: 1e-4) // continuity
    }

    func testBuiltInLUTIsMonotonicOnNeutralAxis() {
        let lut = BuiltInLUT.appleLogTo709.make(dimension: 17)
        let values = lut.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var previous: Float = -1
        for i in 0..<17 {
            let idx = ((i * 17 + i) * 17 + i) * 4
            XCTAssertGreaterThanOrEqual(values[idx + 1], previous)
            previous = values[idx + 1]
        }
    }

    func testScopesFromSyntheticFrame() {
        // Left half black, right half white.
        let w = 10, h = 2
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<5 { let i = (y * w + x) * 4; px[i] = 0; px[i + 1] = 0; px[i + 2] = 0 } }
        let s = MonitoringProcessor.computeScopes(rgba: px, width: w, height: h)
        XCTAssertEqual(s.luma.first, 1)
        XCTAssertEqual(s.luma.last, 1)
        XCTAssertEqual(s.clippedFraction, 0.5, accuracy: 0.001)
    }
}
