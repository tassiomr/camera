@preconcurrency import AVFoundation

/// Receives microphone buffers from AVCaptureAudioDataOutput, detects onsets and
/// tempo, pulses the preview and collects beat times while recording. It only reads
/// audio: the movie file output records the untouched microphone stream.
final class BeatTracker: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.trmedia.camera.beats", qos: .userInitiated)

    /// Called on `queue` for every detected onset.
    var onBeat: (() -> Void)?
    /// Called on `queue` roughly once per second.
    var onTempo: ((Double?) -> Void)?

    private var detector: LiveBeatDetector?
    private var origin: Double = 0           // PTS (s) of the first sample fed to `detector`
    private var lastTempoReport: Double = 0
    private let lock = NSLock()
    private var recordingStart: Double?
    private var recorded: [Double] = []

    func reset() { queue.async { self.detector = nil } }

    /// `time` is the session clock time at which the file started.
    func beginRecording(at time: CMTime) {
        lock.withLock { recordingStart = time.seconds; recorded = [] }
    }

    /// Returns the beat times collected since `beginRecording`, relative to the file start.
    func endRecording() -> BeatMap? {
        lock.withLock {
            defer { recordingStart = nil; recorded = [] }
            guard recordingStart != nil, !recorded.isEmpty else { return nil }
            return BeatMap(bpm: detector?.bpm, beats: recorded, confidence: detector?.confidence ?? 0, source: .live)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let (samples, rate) = AudioSamples.mono(from: sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        if detector == nil || detector?.sampleRate != rate {
            detector = LiveBeatDetector(sampleRate: rate)
            origin = pts
        }
        guard let detector else { return }
        let onsets = detector.process(samples)
        for t in onsets {
            onBeat?()
            let absolute = origin + t
            lock.withLock {
                if let start = recordingStart, absolute >= start { recorded.append(absolute - start) }
            }
        }
        if pts - lastTempoReport >= 1 {
            lastTempoReport = pts
            onTempo?(detector.bpm)
        }
    }
}

enum AudioSamples {
    /// Mono Float32 samples from an LPCM sample buffer (Int16 or Float32, any layout).
    static func mono(from sampleBuffer: CMSampleBuffer) -> ([Float], Double)? {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              asbd.pointee.mFormatID == kAudioFormatLinearPCM,
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                           into: buffer.mutableAudioBufferList) == noErr else { return nil }
        return (mono(from: buffer), format.sampleRate)
    }

    static func mono(from buffer: AVAudioPCMBuffer) -> [Float] {
        let n = Int(buffer.frameLength), channels = Int(buffer.format.channelCount), stride = buffer.stride
        var out = [Float](repeating: 0, count: n)
        let gain = 1 / Float(max(1, channels))
        if let data = buffer.floatChannelData {
            for c in 0..<channels {
                let p = data[buffer.format.isInterleaved ? 0 : c]
                let offset = buffer.format.isInterleaved ? c : 0
                for i in 0..<n { out[i] += p[i * stride + offset] * gain }
            }
        } else if let data = buffer.int16ChannelData {
            let scale = gain / 32768
            for c in 0..<channels {
                let p = data[buffer.format.isInterleaved ? 0 : c]
                let offset = buffer.format.isInterleaved ? c : 0
                for i in 0..<n { out[i] += Float(p[i * stride + offset]) * scale }
            }
        }
        return out
    }

    /// Whole audio of a file, mixed to mono at 44.1 kHz.
    static func read(_ url: URL) async throws -> (samples: [Float], sampleRate: Double)? {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return nil }
        let reader = try AVAssetReader(asset: asset)
        let rate = 44_100.0
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            samples.append(contentsOf: chunk)
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        return (samples, rate)
    }
}
