import AVFoundation
import CoreImage
import XCTest
@testable import TRCamera

/// Synthetic music with known beat positions.
enum SyntheticMusic {
    struct LCG {
        var state: UInt64
        mutating func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 2_000_001 - 1_000_000) / 1_000_000
        }
    }

    /// Kick on every beat (pitch-swept sine, like an electronic bass drum), optional
    /// hats on the off-beats and background noise.
    static func track(bpm: Double, seconds: Double, sampleRate: Double = 44_100, offset: Double = 0.3,
                      hats: Bool = false, noise: Float = 0, seed: UInt64 = 7) -> (samples: [Float], beats: [Double]) {
        let count = Int(seconds * sampleRate)
        var out = [Float](repeating: 0, count: count)
        let period = 60 / bpm
        var beats: [Double] = []
        var rng = LCG(state: seed)
        var t = offset
        while t < seconds - 0.2 {
            beats.append(t)
            let start = Int(t * sampleRate)
            var phase = 0.0
            for i in 0..<Int(0.18 * sampleRate) where start + i < count {
                let dt = Double(i) / sampleRate
                let freq = 50 + 70 * exp(-dt / 0.03)
                phase += 2 * .pi * freq / sampleRate
                out[start + i] += Float(sin(phase) * exp(-dt / 0.07) * 0.8)
            }
            if hats {
                // High-passed noise burst (second difference), like a real hi-hat.
                let h = Int((t + period / 2) * sampleRate)
                var x1: Float = 0, x2: Float = 0
                for i in 0..<Int(0.04 * sampleRate) where h + i < count {
                    let x = rng.next()
                    out[h + i] += (x - 2 * x1 + x2) * 0.15 * Float(exp(-Double(i) / sampleRate / 0.01))
                    x2 = x1; x1 = x
                }
            }
            t += period
        }
        if noise > 0 { for i in out.indices { out[i] += rng.next() * noise } }
        return (out, beats)
    }

    static func noise(seconds: Double, sampleRate: Double = 44_100, amplitude: Float = 0.3) -> [Float] {
        var rng = LCG(state: 99)
        return (0..<Int(seconds * sampleRate)).map { _ in rng.next() * amplitude }
    }

    /// Fraction of `truth` matched by a detection within `tolerance`, and the
    /// fraction of detections that match nothing.
    static func score(_ detected: [Double], truth: [Double], tolerance: Double = 0.05) -> (recall: Double, falsePositive: Double) {
        let hits = truth.filter { b in detected.contains { abs($0 - b) <= tolerance } }.count
        let fps = detected.filter { d in !truth.contains { abs($0 - d) <= tolerance } }.count
        return (Double(hits) / Double(max(1, truth.count)), Double(fps) / Double(max(1, detected.count)))
    }
}

final class BeatAnalysisTests: XCTestCase {
    func testTempoAndBeatsAcrossCommonTempos() {
        for bpm in [90.0, 100, 120, 128, 140, 150, 174] {
            let music = SyntheticMusic.track(bpm: bpm, seconds: 20)
            let map = BeatAnalysis.analyze(samples: music.samples, sampleRate: 44_100)
            let estimated = try? XCTUnwrap(map.bpm, "no tempo at \(bpm)")
            XCTAssertEqual(estimated ?? 0, bpm, accuracy: 1.5, "tempo at \(bpm)")
            let s = SyntheticMusic.score(map.beats, truth: music.beats)
            XCTAssertGreaterThan(s.recall, 0.95, "recall at \(bpm)")
            XCTAssertLessThan(s.falsePositive, 0.05, "false positives at \(bpm)")
        }
    }

    func testOffbeatHatsDoNotDoubleTheTempo() {
        let music = SyntheticMusic.track(bpm: 120, seconds: 20, hats: true)
        let map = BeatAnalysis.analyze(samples: music.samples, sampleRate: 44_100)
        XCTAssertEqual(map.bpm ?? 0, 120, accuracy: 1.5)
        XCTAssertGreaterThan(SyntheticMusic.score(map.beats, truth: music.beats).recall, 0.95)
    }

    func testNoisyRoomStillFindsTheKick() {
        let music = SyntheticMusic.track(bpm: 124, seconds: 20, hats: true, noise: 0.25)
        let map = BeatAnalysis.analyze(samples: music.samples, sampleRate: 44_100)
        XCTAssertEqual(map.bpm ?? 0, 124, accuracy: 2)
        XCTAssertGreaterThan(SyntheticMusic.score(map.beats, truth: music.beats, tolerance: 0.06).recall, 0.9)
    }

    func testWorksAt48kHz() {
        let music = SyntheticMusic.track(bpm: 110, seconds: 15, sampleRate: 48_000)
        let map = BeatAnalysis.analyze(samples: music.samples, sampleRate: 48_000)
        XCTAssertEqual(map.bpm ?? 0, 110, accuracy: 1.5)
        XCTAssertGreaterThan(SyntheticMusic.score(map.beats, truth: music.beats).recall, 0.95)
    }

    func testSilenceAndNoiseHaveNoBeats() {
        XCTAssertTrue(BeatAnalysis.analyze(samples: [Float](repeating: 0, count: 44_100 * 10), sampleRate: 44_100).beats.isEmpty)
        let noise = BeatAnalysis.analyze(samples: SyntheticMusic.noise(seconds: 10), sampleRate: 44_100)
        XCTAssertTrue(noise.beats.isEmpty, "white noise reported \(noise.beats.count) beats, confidence \(noise.confidence)")
        XCTAssertTrue(BeatAnalysis.analyze(samples: [0.1, 0.2], sampleRate: 44_100).beats.isEmpty, "too short")
    }

    func testAnalysisIsFastEnoughForLongClips() {
        let music = SyntheticMusic.track(bpm: 120, seconds: 120)
        let start = CFAbsoluteTimeGetCurrent()
        _ = BeatAnalysis.analyze(samples: music.samples, sampleRate: 44_100)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThan(elapsed, 3, "2 min of audio took \(elapsed) s")
    }
}

final class LiveBeatDetectorTests: XCTestCase {
    private func run(_ samples: [Float], rate: Double = 48_000, chunk: Int = 1024) -> (LiveBeatDetector, [Double]) {
        let detector = LiveBeatDetector(sampleRate: rate)
        var onsets: [Double] = []
        var i = 0
        while i < samples.count {
            onsets += detector.process(Array(samples[i..<min(samples.count, i + chunk)]))
            i += chunk
        }
        return (detector, onsets)
    }

    func testStreamingOnsetsAndTempo() {
        let music = SyntheticMusic.track(bpm: 128, seconds: 15, sampleRate: 48_000, hats: true)
        let (detector, onsets) = run(music.samples)
        // Ignore the first second while the adaptive threshold warms up.
        let truth = music.beats.filter { $0 > 1 }
        let s = SyntheticMusic.score(onsets.filter { $0 > 1 }, truth: truth, tolerance: 0.06)
        XCTAssertGreaterThan(s.recall, 0.9)
        XCTAssertLessThan(s.falsePositive, 0.15, "off-beat hats should mostly not fire")
        XCTAssertEqual(detector.bpm ?? 0, 128, accuracy: 2)
    }

    func testOnsetTimesDoNotDependOnBufferSize() {
        let music = SyntheticMusic.track(bpm: 100, seconds: 8, sampleRate: 48_000)
        let a = run(music.samples, chunk: 480).1
        let b = run(music.samples, chunk: 4096).1
        XCTAssertEqual(a.count, b.count)
        for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: 1e-9) }
    }

    func testSilenceProducesNothing() {
        let (detector, onsets) = run([Float](repeating: 0, count: 48_000 * 5))
        XCTAssertTrue(onsets.isEmpty)
        XCTAssertNil(detector.bpm)
    }

    func testCPUBudget() {
        // 60 s of audio must be processed far faster than real time.
        let music = SyntheticMusic.track(bpm: 120, seconds: 60, sampleRate: 48_000)
        let start = CFAbsoluteTimeGetCurrent()
        _ = run(music.samples)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThan(elapsed, 3, "60 s of audio took \(elapsed) s")
    }

    func testMonoMixOfInterleavedInt16() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let p = try XCTUnwrap(buffer.int16ChannelData)[0]
        for i in 0..<4 { p[i * 2] = 16384; p[i * 2 + 1] = -16384 * Int16(i % 2) }
        let mono = AudioSamples.mono(from: buffer)
        XCTAssertEqual(mono[0], 0.25, accuracy: 1e-4)
        XCTAssertEqual(mono[1], 0, accuracy: 1e-4)
    }
}

final class BeatMapAndEffectTests: XCTestCase {
    func testPulseEnvelope() {
        let map = BeatMap(bpm: 120, beats: [1, 1.5, 2], confidence: 1, source: .file)
        XCTAssertEqual(map.pulse(at: 0.5), 0)
        XCTAssertEqual(map.pulse(at: 1), 1, accuracy: 1e-9)
        XCTAssertLessThan(map.pulse(at: 1.3), 0.25)
        XCTAssertEqual(map.pulse(at: 1.5), 1, accuracy: 1e-9)
    }

    func testFlashIsCappedBelowThreeHertz() {
        let fast = BeatMap(bpm: 240, beats: stride(from: 0.0, to: 10, by: 0.25).map { $0 }, confidence: 1, source: .file)
        let thinned = fast.thinned(minInterval: BeatEffect.flash.minimumBeatInterval)
        let gaps = zip(thinned.beats.dropFirst(), thinned.beats).map { $0 - $1 }
        XCTAssertTrue(gaps.allSatisfy { $0 >= 0.34 })
        XCTAssertEqual(BeatEffect.punch.minimumBeatInterval, 0)
    }

    func testEveryEffectChangesImageOnBeatAndNothingOffBeat() {
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        // Fine checkerboard so zoom/shake/split are visible.
        let base = CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputCenter": CIVector(x: 100, y: 50), "inputWidth": 7,
            "inputColor0": CIColor(red: 0.2, green: 0.4, blue: 0.7), "inputColor1": CIColor(red: 0.6, green: 0.45, blue: 0.2)
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
        func pixels(_ image: CIImage) -> [UInt8] {
            var p = [UInt8](repeating: 0, count: 200 * 100 * 4)
            context.render(image, toBitmap: &p, rowBytes: 800, bounds: CGRect(x: 0, y: 0, width: 200, height: 100), format: .RGBA8, colorSpace: nil)
            return p
        }
        let original = pixels(base)
        for effect in BeatEffect.allCases where effect != .off {
            let on = effect.apply(to: base, amount: 1, seed: 3)
            XCTAssertEqual(on.extent, base.extent, "\(effect) must keep the frame size")
            let diff = zip(pixels(on), original).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertGreaterThan(diff, 10, "\(effect) invisible on the beat")
            XCTAssertEqual(pixels(effect.apply(to: base, amount: 0)), original, "\(effect) must do nothing between beats")
        }
    }
}

final class BeatExportTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("trbeat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// Grey H.264 video + a 120 BPM kick track, muxed into one .mov like a recording.
    private func makeMusicClip(seconds: Double, withAudio: Bool = true) async throws -> URL {
        let video = dir.appendingPathComponent("video.mov")
        try FilterExportTests.makeClip(at: video, color: (100, 100, 100), size: CGSize(width: 320, height: 180), frames: Int(seconds * 30))
        guard withAudio else { return video }
        let wav = dir.appendingPathComponent("music.caf")
        let music = SyntheticMusic.track(bpm: 120, seconds: seconds)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: wav, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(music.samples.count))!
        buffer.frameLength = buffer.frameCapacity
        music.samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: music.samples.count) }
        try file.write(from: buffer)

        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: wav)
        let vTrack = try await videoAsset.loadTracks(withMediaType: .video)[0]
        let aTrack = try await audioAsset.loadTracks(withMediaType: .audio)[0]
        let duration = try await videoAsset.load(.duration)
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: vTrack, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: aTrack, at: .zero)
        let out = dir.appendingPathComponent("TR_music.mov")
        let export = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        try await export.export(to: out, as: .mov)
        try FileManager.default.removeItem(at: video)
        return out
    }

    private func brightness(_ url: URL, at seconds: Double) async throws -> Int {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Int(px[0]) + Int(px[1]) + Int(px[2])
    }

    func testFlashLandsOnTheBeatsAndOriginalIsUntouched() async throws {
        let url = try await makeMusicClip(seconds: 6)
        let library = RecordingLibrary(directory: dir)
        let item = try XCTUnwrap(library.items().first { $0.url.lastPathComponent == "TR_music.mov" })
        let originalData = try Data(contentsOf: url)

        let result = try await library.exportBeatEdit(of: item, effect: .flash)
        XCTAssertEqual(result.beats.bpm ?? 0, 120, accuracy: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
        XCTAssertEqual(try Data(contentsOf: url), originalData, "original must not change")

        let beat = try XCTUnwrap(result.beats.beats.first { $0 > 1 && $0 < 4 })
        let onBeat = try await brightness(result.url, at: beat + 0.02)
        let between = try await brightness(result.url, at: beat + 0.3)
        XCTAssertGreaterThan(onBeat, between + 60, "flash must be visible on the beat (\(onBeat) vs \(between))")
        let source = try await brightness(url, at: beat + 0.02)
        XCTAssertLessThan(abs(between - source), 40, "between beats the copy should look like the original")
    }

    func testClipWithoutAudioExplainsWhy() async throws {
        _ = try await makeMusicClip(seconds: 2, withAudio: false)
        let library = RecordingLibrary(directory: dir)
        let item = try XCTUnwrap(library.items().first)
        do {
            _ = try await library.exportBeatEdit(of: item, effect: .punch)
            XCTFail("must refuse")
        } catch let error as RecordingLibrary.BeatExportError {
            XCTAssertEqual(error, .noAudio)
        }
    }
}
