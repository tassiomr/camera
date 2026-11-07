import AVFoundation
import CoreImage
import Metal
import QuartzCore
import UIKit

/// Data for the histogram / waveform scopes, computed off the main thread.
struct ScopeData: Equatable {
    static let bins = 64
    static let waveColumns = 96
    static let waveRows = 48

    var luma = [Float](repeating: 0, count: bins)
    var red = [Float](repeating: 0, count: bins)
    var green = [Float](repeating: 0, count: bins)
    var blue = [Float](repeating: 0, count: bins)
    /// waveColumns × waveRows density, row 0 = black.
    var waveform = [Float](repeating: 0, count: waveColumns * waveRows)
    var clippedFraction: Float = 0
}

/// Receives frames from AVCaptureVideoDataOutput and produces:
/// - a processed monitoring image (LUT, false color, zebra, peaking, desqueeze) drawn
///   into a CAMetalLayer that covers the low-latency preview layer, and
/// - throttled scope data.
/// Core Image is used because every effect maps to a built-in GPU filter, avoiding
/// custom kernels. The processor never touches the recording path: the movie file
/// output receives the untouched sensor stream.
final class MonitoringProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.trmedia.camera.monitoring", qos: .userInitiated)
    let metalDevice = MTLCreateSystemDefaultDevice()
    private let commandQueue: MTLCommandQueue?
    private let context: CIContext

    private let lock = NSLock()
    private var settings = MonitoringSettings()
    private var lut: CubeLUT?
    private var suspended = false
    private weak var target: MonitorLayerView?
    private var lastAnalysis: CFTimeInterval = 0
    private lazy var falseColorGradient = Self.makeFalseColorGradient()

    var onScopes: ((ScopeData) -> Void)?

    override init() {
        commandQueue = metalDevice?.makeCommandQueue()
        let options: [CIContextOption: Any] = [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false]
        if let device = metalDevice {
            context = CIContext(mtlDevice: device, options: options)
        } else {
            context = CIContext(options: options)
        }
        super.init()
    }

    func update(settings: MonitoringSettings, lut: CubeLUT?) {
        lock.withLock { self.settings = settings; self.lut = lut }
    }

    func setTarget(_ view: MonitorLayerView?) { lock.withLock { target = view } }

    /// Thermal protection: stop all auxiliary processing, recording continues.
    func setSuspended(_ value: Bool) { lock.withLock { suspended = value } }

    var isActive: Bool { lock.withLock { !suspended && (settings.needsProcessedPreview || settings.needsAnalysis || beatEffect != .off) } }

    // MARK: Beat pulse (preview only)

    private var beatEffect: BeatEffect = .off
    private var lastBeat: CFTimeInterval = -10
    private var beatCount = 0

    func setBeatEffect(_ effect: BeatEffect) { lock.withLock { beatEffect = effect } }

    /// Called from the audio queue when an onset is detected.
    func triggerBeat() {
        lock.withLock {
            let now = CACurrentMediaTime()
            guard now - lastBeat >= beatEffect.minimumBeatInterval else { return }
            lastBeat = now
            beatCount += 1
        }
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Raw signal values (no color management) so zebra/false color read code values.
        processFrame(CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace: NSNull()]))
    }

    /// When true every frame is drawn even without image tools (demo mode has no preview layer).
    var alwaysRender = false

    private var lastFrameTime: CFTimeInterval = 0
    /// Seconds since the last frame reached the processor (diagnostics).
    var secondsSinceLastFrame: Double { lock.withLock { CACurrentMediaTime() - lastFrameTime } }

    /// Single entry point for camera frames and synthetic demo frames. Call on `queue`.
    func processFrame(_ image: CIImage) {
        lock.withLock { lastFrameTime = CACurrentMediaTime() }
        let (settings, lut, suspended, target, effect, lastBeat, seed) = lock.withLock {
            (self.settings, self.lut, self.suspended, self.target, self.beatEffect, self.lastBeat, self.beatCount)
        }
        guard !suspended else { return }
        if settings.needsProcessedPreview || alwaysRender || effect != .off, let target {
            let pulse = effect == .off ? 0 : exp(-(CACurrentMediaTime() - lastBeat) / 0.14)
            render(image, settings: settings, lut: lut, beat: (effect, pulse, seed), into: target)
        }
        let now = CACurrentMediaTime()
        if settings.needsAnalysis, now - lastAnalysis > 0.1 {
            lastAnalysis = now
            if let scopes = analyze(image, lut: lut) { onScopes?(scopes) }
        }
    }

    // MARK: Rendering

    private func render(_ source: CIImage, settings: MonitoringSettings, lut: CubeLUT?, beat: (BeatEffect, Double, Int), into view: MonitorLayerView) {
        guard let layer = view.metalLayer, let commandQueue, let drawable = layer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let size = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        var processed = process(source, settings: settings, lut: lut, fitting: size)
        processed = beat.0.apply(to: processed, amount: beat.1, seed: beat.2)

        let destination = CIRenderDestination(width: Int(size.width), height: Int(size.height),
                                              pixelFormat: layer.pixelFormat, commandBuffer: commandBuffer) { drawable.texture }
        destination.colorSpace = nil
        let background = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
        _ = try? context.startTask(toRender: processed.composited(over: background), to: destination)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func process(_ source: CIImage, settings: MonitoringSettings, lut: CubeLUT?, fitting size: CGSize) -> CIImage {
        var image = source
        if settings.anamorphicSqueeze != 1 {
            image = image.transformed(by: CGAffineTransform(scaleX: settings.anamorphicSqueeze, y: 1))
        }
        // Scale first so every filter runs at display resolution, not sensor resolution.
        let extent = image.extent
        let scale = min(size.width / extent.width, size.height / extent.height)
        image = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let fitted = image.extent
        image = image.transformed(by: CGAffineTransform(translationX: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2))
        let signal = image

        if let lut {
            image = image.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": lut.dimension, "inputCubeData": lut.data])
        }
        image = settings.look.apply(to: image)
        if settings.falseColorEnabled {
            image = Self.luma(image).applyingFilter("CIColorMap", parameters: ["inputGradientImage": falseColorGradient])
        }
        if settings.peakingEnabled {
            let s = settings.peakingSensitivity
            let edges = Self.luma(signal).applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 2 + s * 8])
            let mask = edges.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.32 - s * 0.24])
            let (r, g, b) = settings.peakingColor.rgb
            let color = CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: image.extent)
            image = color.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask])
        }
        if settings.zebraEnabled {
            let mask = Self.luma(signal).applyingFilter("CIColorThreshold", parameters: ["inputThreshold": settings.zebraLevel])
            let stripes = CIFilter(name: "CIStripesGenerator", parameters: [
                // Dark stripes: zebra marks bright/clipped areas, where white stripes would vanish.
                "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 0.75),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
                "inputWidth": 5.0, "inputSharpness": 1.0
            ])!.outputImage!
                .transformed(by: CGAffineTransform(rotationAngle: .pi / 4))
                .cropped(to: image.extent)
            let striped = stripes.composited(over: image)
            image = striped.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask])
        }
        return image
    }

    /// Rec.709 luma weights applied to code values.
    static func luma(_ image: CIImage) -> CIImage {
        let w = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        return image.applyingFilter("CIColorMatrix", parameters: ["inputRVector": w, "inputGVector": w, "inputBVector": w])
    }

    /// False color scale (signal %): see docs/MONITORAMENTO.md for the meaning of each band.
    static let falseColorBands: [(range: ClosedRange<Double>, rgb: (UInt8, UInt8, UInt8))] = [
        (0.00...0.025, (110, 40, 160)),  // crushed blacks
        (0.025...0.10, (30, 90, 230)),   // near black
        (0.38...0.44, (40, 200, 90)),    // ~18% grey (Rec.709)
        (0.52...0.58, (240, 120, 170)),  // ~skin +1 stop
        (0.90...0.97, (245, 220, 40)),   // near clip
        (0.97...1.00, (235, 40, 40))     // clipped
    ]

    private static func makeFalseColorGradient() -> CIImage {
        var bytes = [UInt8](repeating: 255, count: 256 * 4)
        for i in 0..<256 {
            let v = Double(i) / 255
            var rgb = (UInt8(i / 2), UInt8(i / 2), UInt8(i / 2)) // dimmed grey elsewhere
            if let band = falseColorBands.first(where: { $0.range.contains(v) }) { rgb = band.rgb }
            bytes[i * 4] = rgb.0; bytes[i * 4 + 1] = rgb.1; bytes[i * 4 + 2] = rgb.2
        }
        return CIImage(bitmapData: Data(bytes), bytesPerRow: 256 * 4, size: CGSize(width: 256, height: 1), format: .RGBA8, colorSpace: nil)
    }

    // MARK: Analysis

    private func analyze(_ source: CIImage, lut: CubeLUT?) -> ScopeData? {
        let width = 192, height = 108
        let extent = source.extent
        let small = source
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / extent.width, y: CGFloat(height) / extent.height))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(small, toBitmap: &pixels, rowBytes: width * 4,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: nil)
        return Self.computeScopes(rgba: pixels, width: width, height: height)
    }

    /// Pure function: unit-tested with synthetic buffers.
    static func computeScopes(rgba: [UInt8], width: Int, height: Int) -> ScopeData {
        var data = ScopeData()
        let bins = ScopeData.bins, cols = ScopeData.waveColumns, rows = ScopeData.waveRows
        var clipped = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let r = Int(rgba[i]), g = Int(rgba[i + 1]), b = Int(rgba[i + 2])
                let l = (2126 * r + 7152 * g + 722 * b) / 10000
                data.luma[l * bins / 256] += 1
                data.red[r * bins / 256] += 1
                data.green[g * bins / 256] += 1
                data.blue[b * bins / 256] += 1
                if l >= 250 { clipped += 1 }
                let col = x * cols / width
                let row = l * rows / 256
                data.waveform[row * cols + col] += 1
            }
        }
        func normalize(_ a: inout [Float]) {
            let m = a.max() ?? 0
            if m > 0 { for k in a.indices { a[k] = (a[k] / m).squareRoot() } }
        }
        normalize(&data.luma); normalize(&data.red); normalize(&data.green); normalize(&data.blue)
        normalize(&data.waveform)
        data.clippedFraction = Float(clipped) / Float(max(1, width * height))
        return data
    }
}

/// A view backed by CAMetalLayer that the processor draws into from its own queue.
final class MonitorLayerView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private let lock = NSLock()
    private var _metalLayer: CAMetalLayer?
    var metalLayer: CAMetalLayer? { lock.withLock { _metalLayer } }

    func configure(device: MTLDevice?) {
        guard let layer = layer as? CAMetalLayer else { return }
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.isOpaque = true
        lock.withLock { _metalLayer = layer }
        isUserInteractionEnabled = false
        backgroundColor = .black
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? 3
        (layer as? CAMetalLayer)?.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
}
