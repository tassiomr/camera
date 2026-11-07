import Accelerate
import Foundation

/// Beat positions of a clip. Written to the sidecar; drives beat-synced export.
struct BeatMap: Codable, Hashable, Sendable {
    enum Source: String, Codable, Sendable { case live, file }
    var bpm: Double?
    /// Seconds from the start of the clip.
    var beats: [Double]
    /// 0…1, how periodic the onset envelope is (low = speech/noise, not music).
    var confidence: Double
    var source: Source

    static let empty = BeatMap(bpm: nil, beats: [], confidence: 0, source: .file)

    /// Pulse envelope at time `t`: 1 on a beat, decaying exponentially.
    func pulse(at t: Double, decay: Double = 0.14) -> Double {
        // Binary search for the last beat <= t.
        var lo = 0, hi = beats.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if beats[mid] <= t { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return 0 }
        return exp(-(t - beats[lo - 1]) / decay)
    }

    /// Drops beats closer than `minInterval` to the previous kept one. Used to keep
    /// flash effects below 3 per second (photosensitivity guideline).
    func thinned(minInterval: Double) -> BeatMap {
        var copy = self
        var kept: [Double] = []
        for b in beats where kept.last.map({ b - $0 >= minInterval }) ?? true { kept.append(b) }
        copy.beats = kept
        return copy
    }
}

/// Onset strength envelope: half-wave rectified spectral flux of log magnitudes,
/// weighted toward the kick/bass band (30–250 Hz) where beats live in most music,
/// plus a smaller broadband term for snares and hats. One value per hop.
final class OnsetEnvelope {
    static let log2n: vDSP_Length = 11
    static let frameSize = 1 << 11 // 2048
    static let hop = 512

    let sampleRate: Double
    var hopSeconds: Double { Double(Self.hop) / sampleRate }

    private let setup: FFTSetup
    private let window: [Float]
    private let lowBins: Range<Int>
    private let highBins: Range<Int>
    private var previous: [Float]
    private var buffer: [Float] = []
    private var real: [Float]
    private var imag: [Float]

    /// Weight of the broadband (snare/hat) term relative to the bass band.
    let highWeight: Float

    init(sampleRate: Double, highWeight: Float = 0.5) {
        self.sampleRate = sampleRate
        self.highWeight = highWeight
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.frameSize, isHalfWindow: false)
        let binHz = sampleRate / Double(Self.frameSize)
        let half = Self.frameSize / 2
        lowBins = max(1, Int(30 / binHz))..<min(half, Int(250 / binHz) + 1)
        highBins = lowBins.upperBound..<min(half, Int(8000 / binHz))
        previous = [Float](repeating: 0, count: half)
        real = [Float](repeating: 0, count: half)
        imag = [Float](repeating: 0, count: half)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Feeds mono samples; returns the envelope values completed by them.
    func append(_ samples: [Float]) -> [Float] {
        buffer.append(contentsOf: samples)
        var out: [Float] = []
        var start = 0
        while buffer.count - start >= Self.frameSize {
            out.append(flux(frameAt: start))
            start += Self.hop
        }
        if start > 0 { buffer.removeFirst(start) }
        return out
    }

    private func flux(frameAt start: Int) -> Float {
        let n = Self.frameSize, half = n / 2
        var windowed = [Float](repeating: 0, count: n)
        buffer.withUnsafeBufferPointer { src in
            vDSP_vmul(src.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(n))
        }
        var mags = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        // Log compression makes the flux independent of overall level (AGC, distance).
        var low: Float = 0, high: Float = 0
        for k in 1..<half {
            let v = log1pf(mags[k] * 10)
            let d = v - previous[k]
            previous[k] = v
            guard d > 0 else { continue }
            if lowBins.contains(k) { low += d } else if highBins.contains(k) { high += d }
        }
        return low / Float(max(1, lowBins.count)) + highWeight * high / Float(max(1, highBins.count))
    }
}

/// Tempo from the autocorrelation of the onset envelope (70–180 BPM), with a
/// log-Gaussian preference around 120 BPM to reduce half/double-tempo errors.
enum TempoEstimator {
    static func estimate(envelope: [Float], hopSeconds: Double, minBPM: Double = 70, maxBPM: Double = 180) -> (bpm: Double, confidence: Double)? {
        let minLag = Int((60 / maxBPM / hopSeconds).rounded(.down))
        let maxLag = Int((60 / minBPM / hopSeconds).rounded(.up))
        guard envelope.count > maxLag * 3 else { return nil }
        // Light smoothing so a period that falls between two hops is not split
        // across neighbouring lags (which favoured the half tempo).
        var smooth = envelope
        for i in 1..<(envelope.count - 1) { smooth[i] = 0.25 * envelope[i - 1] + 0.5 * envelope[i] + 0.25 * envelope[i + 1] }
        let mean = vDSP.mean(smooth)
        let x = vDSP.add(-mean, smooth)
        let energy = vDSP.dot(x, x)
        guard energy > 1e-9 else { return nil }
        let lastLag = min(x.count - 1, 2 * maxLag + 2)
        var acfs = [Double](repeating: 0, count: lastLag + 1)
        for lag in 1...lastLag {
            let n = x.count - lag
            // Unbiased: divide by the overlap so long lags are not penalised.
            acfs[lag] = Double(x.withUnsafeBufferPointer { p in
                var r: Float = 0
                vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &r, vDSP_Length(n))
                return r
            }) / Double(energy) * Double(x.count) / Double(n)
        }
        var best = (lag: 0, score: -Double.infinity, acf: 0.0)
        for lag in minLag...maxLag where lag + 1 <= lastLag {
            let bpm = 60 / (Double(lag) * hopSeconds)
            let prior = exp(-0.5 * pow(log2(bpm / 120) / 0.9, 2))
            // Harmonic sum: the true tempo also correlates at twice its period.
            let double = 2 * lag <= lastLag ? acfs[2 * lag] : 0
            let score = (acfs[lag] + 0.5 * double) * prior
            if score > best.score { best = (lag, score, acfs[lag]) }
        }
        guard best.lag > 0, best.acf > 0 else { return nil }
        // Parabolic interpolation for sub-hop precision.
        let a = acfs[best.lag - 1], b = acfs[best.lag], c = acfs[best.lag + 1]
        let denom = a - 2 * b + c
        let offset = denom != 0 ? 0.5 * (a - c) / denom : 0
        let lag = Double(best.lag) + max(-0.5, min(0.5, offset))
        return (60 / (lag * hopSeconds), min(1, max(0, best.acf)))
    }
}

/// Offline beat tracking for a whole clip: tempo from the global autocorrelation,
/// then dynamic programming (Ellis 2007) to place beats on strong onsets while
/// keeping the spacing close to the tempo.
enum BeatAnalysis {
    /// Below this confidence the audio is treated as non-musical (no beats).
    static let minimumConfidence = 0.12

    static func analyze(samples: [Float], sampleRate: Double) -> BeatMap {
        let onset = OnsetEnvelope(sampleRate: sampleRate)
        let env = onset.append(samples)
        return analyze(envelope: env, hopSeconds: onset.hopSeconds)
    }

    static func analyze(envelope env: [Float], hopSeconds: Double) -> BeatMap {
        guard let tempo = TempoEstimator.estimate(envelope: env, hopSeconds: hopSeconds),
              tempo.confidence >= minimumConfidence else {
            return BeatMap(bpm: nil, beats: [], confidence: 0, source: .file)
        }
        let period = 60 / tempo.bpm / hopSeconds // in hops
        var envMean: Float = 0, envStd: Float = 0
        vDSP_normalize(env, 1, nil, 1, &envMean, &envStd, vDSP_Length(env.count))
        let std = Double(envStd)
        guard std > 1e-9 else { return .empty }
        let norm = env.map { Double($0) / std }
        let tightness = 100.0
        var score = norm
        var back = [Int](repeating: -1, count: norm.count)
        let lo = Int((period / 2).rounded()), hi = Int((period * 2).rounded())
        for t in 0..<norm.count {
            var bestPrev = -1, bestScore = -Double.infinity
            var p = t - hi
            while p <= t - lo {
                if p >= 0 {
                    let penalty = tightness * pow(log(Double(t - p) / period), 2)
                    let s = score[p] - penalty
                    if s > bestScore { bestScore = s; bestPrev = p }
                }
                p += 1
            }
            if bestPrev >= 0, bestScore > 0 { score[t] = norm[t] + bestScore; back[t] = bestPrev }
        }
        // Start the backtrace from the best score within the last period.
        let tail = max(0, norm.count - Int(period.rounded()))
        guard var t = (tail..<norm.count).max(by: { score[$0] < score[$1] }) else { return .empty }
        var idx: [Int] = []
        while t >= 0 { idx.append(t); t = back[t] }
        // Envelope frame k is centred at k*hop + frameSize/2 samples.
        let centre = Double(OnsetEnvelope.frameSize / 2) / Double(OnsetEnvelope.hop)
        let beats = idx.reversed().map { (Double($0) + centre) * hopSeconds }
        return BeatMap(bpm: tempo.bpm, beats: beats, confidence: tempo.confidence, source: .file)
    }
}

/// Streaming detector for live use: onset peak picking with an adaptive threshold,
/// plus a tempo estimate refreshed about once per second.
final class LiveBeatDetector {
    let sampleRate: Double
    private let onset: OnsetEnvelope
    private var history: [Float] = []        // last ~8 s of envelope
    private var envelopeIndex = 0             // index of the next envelope value
    private var lastOnsetIndex = -1_000_000
    private var peakLevel: Float = 0          // decaying level of recent onsets
    private var hopsSinceTempo = 0
    private(set) var bpm: Double?
    private(set) var confidence: Double = 0

    private let historyLength: Int
    private let thresholdWindow: Int
    private let minGap: Int

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        // Live effects should follow the kick, not hats on the off-beats.
        onset = OnsetEnvelope(sampleRate: sampleRate, highWeight: 0.1)
        let hop = onset.hopSeconds
        historyLength = Int(8 / hop)
        thresholdWindow = Int(0.6 / hop)
        minGap = Int(0.2 / hop) // fastest accepted: 300 onsets/min
    }

    /// Feeds samples; returns onset times in seconds since the first sample.
    func process(_ samples: [Float]) -> [Double] {
        var onsets: [Double] = []
        for value in onset.append(samples) {
            history.append(value)
            if history.count > historyLength { history.removeFirst(history.count - historyLength) }
            envelopeIndex += 1
            // Decide on the previous value once its right neighbour is known.
            let n = history.count
            peakLevel *= 0.995
            if n >= thresholdWindow + 2 {
                let candidate = history[n - 2]
                let window = history[(n - 2 - thresholdWindow)..<(n - 2)]
                let mean = window.reduce(0, +) / Float(window.count)
                let variance = window.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(window.count)
                let threshold = mean + 1.5 * variance.squareRoot() + 0.02
                let index = envelopeIndex - 2
                if candidate > threshold, candidate >= 0.45 * peakLevel,
                   candidate >= history[n - 1], candidate >= history[n - 3],
                   index - lastOnsetIndex >= minGap {
                    lastOnsetIndex = index
                    peakLevel = max(peakLevel, candidate)
                    let centre = Double(OnsetEnvelope.frameSize / 2) / Double(OnsetEnvelope.hop)
                    onsets.append((Double(index) + centre) * onset.hopSeconds)
                }
            }
            hopsSinceTempo += 1
            if hopsSinceTempo * OnsetEnvelope.hop >= Int(sampleRate) {
                hopsSinceTempo = 0
                let tempo = TempoEstimator.estimate(envelope: history, hopSeconds: onset.hopSeconds)
                if let tempo, tempo.confidence >= BeatAnalysis.minimumConfidence {
                    bpm = tempo.bpm; confidence = tempo.confidence
                } else {
                    bpm = nil; confidence = tempo?.confidence ?? 0
                }
            }
        }
        return onsets
    }
}
