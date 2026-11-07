import CoreImage
import Foundation
import UIKit

/// Synthetic camera used when the app runs without camera hardware (Simulator, UI
/// tests, or the `-demo` launch argument). It exercises the real monitoring/filter
/// pipeline and the full UI; nothing here is shown on a real iPhone.
final class DemoCamera {
    static var isEnabled: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return ProcessInfo.processInfo.arguments.contains("-demo")
        #endif
    }

    private var timer: DispatchSourceTimer?
    private var frame = 0
    private weak var processor: MonitoringProcessor?
    private let lock = NSLock()
    private var portrait = true
    private var size = CGSize(width: 1920, height: 1080)

    func start(feeding processor: MonitoringProcessor) {
        self.processor = processor
        processor.alwaysRender = true
        let timer = DispatchSource.makeTimerSource(queue: processor.queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func setPortrait(_ value: Bool) { lock.withLock { portrait = value } }
    func setResolution(_ r: VideoResolution) { lock.withLock { size = CGSize(width: r.width, height: r.height) } }

    private func tick() {
        frame += 1
        let (portrait, size) = lock.withLock { (self.portrait, self.size) }
        var image = Self.pattern(size: size, time: Double(frame) / 30)
        if portrait {
            image = image.transformed(by: CGAffineTransform(rotationAngle: -.pi / 2))
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        processor?.processFrame(image)
    }

    /// Landscape test chart: color bars (top), a moving "subject", a fine
    /// checkerboard (focus peaking target), a black→white ramp and a clipped patch.
    static func pattern(size: CGSize, time: Double) -> CIImage {
        let w = size.width, h = size.height
        var image = CIImage(color: CIColor(red: 0.18, green: 0.2, blue: 0.22)).cropped(to: CGRect(origin: .zero, size: size))
        let bars: [CIColor] = [.white, .yellow, .cyan, .green, .magenta, .red, .blue]
        let barW = w / CGFloat(bars.count)
        for (i, color) in bars.enumerated() {
            let c = CIColor(red: color.red * 0.75, green: color.green * 0.75, blue: color.blue * 0.75)
            image = CIImage(color: c).cropped(to: CGRect(x: CGFloat(i) * barW, y: h * 0.72, width: barW + 1, height: h * 0.28)).composited(over: image)
        }
        let ramp = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: w, y: 0),
            "inputColor0": CIColor.black, "inputColor1": CIColor.white
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: w, height: h * 0.12))
        image = ramp.composited(over: image)
        let checker = CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputColor0": CIColor.white, "inputColor1": CIColor.black, "inputWidth": max(2, w / 240), "inputSharpness": 1
        ])!.outputImage!.cropped(to: CGRect(x: w * 0.06, y: h * 0.2, width: w * 0.22, height: h * 0.4))
        image = checker.composited(over: image)
        image = CIImage(color: .white).cropped(to: CGRect(x: w * 0.82, y: h * 0.2, width: w * 0.12, height: h * 0.4)).composited(over: image)
        let cx = w * (0.5 + 0.12 * sin(time)), cy = h * 0.42
        let subject = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: cx, y: cy), "inputRadius0": h * 0.12, "inputRadius1": h * 0.2,
            "inputColor0": CIColor(red: 0.85, green: 0.62, blue: 0.5), "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        ])!.outputImage!.cropped(to: CGRect(origin: .zero, size: size))
        image = subject.composited(over: image)
        // "TOP" marker: a bright bar in the top-left corner to catch flipped output.
        image = CIImage(color: CIColor(red: 0.24, green: 0.89, blue: 0.76)).cropped(to: CGRect(x: 0, y: h * 0.94, width: w * 0.08, height: h * 0.06)).composited(over: image)
        return image
    }

    /// Pro-like capabilities so every control has something real to resolve against.
    static var capabilities: DeviceCapabilities {
        func fmt(_ i: Int, _ w: Int, _ h: Int, _ fps: Double, _ p: [ColorProfile], binned: Bool = false, bit: Int = 10) -> FormatDescriptor {
            FormatDescriptor(index: i, width: w, height: h, frameRateRanges: [FrameRateRange(min: 1, max: fps)],
                             pixelFormat: bit == 10 ? "x420" : "420v", bitDepth: bit, colorProfiles: p, isVideoHDRSupported: true,
                             stabilizationModes: [.off, .standard, .cinematic, .cinematicExtended], minISO: 32, maxISO: 3072,
                             minExposureSeconds: 1.0 / 24000, maxExposureSeconds: 1.0 / 3, fieldOfView: 70, isBinned: binned,
                             maxZoom: 100, isMultiCamSupported: true, lensApertureRange: nil, recommendedApertureStops: [])
        }
        let formats = [fmt(0, 1920, 1080, 240, [.rec709], binned: true, bit: 8), fmt(1, 1920, 1080, 60, [.rec709, .hlg, .appleLog]),
                       fmt(2, 3840, 2160, 30, [.rec709, .hlg, .appleLog, .appleLog2]), fmt(3, 3840, 2160, 60, [.rec709, .hlg]),
                       fmt(4, 3840, 2160, 120, [.rec709], binned: true, bit: 8)]
        func cam(_ id: String, _ lens: LensKind, _ focal: Double, _ pos: CameraPosition = .back) -> CameraDescriptor {
            CameraDescriptor(id: id, name: "Demo \(lens.label)", position: pos, lens: lens, isVirtual: false, deviceType: "demo",
                             switchOverZoomFactors: [], displayZoomMultiplier: 1, minZoom: 1, maxZoom: 10, fixedAperture: 1.78,
                             equivalentFocalLength: focal, formats: formats, supportsFocusLock: true, supportsCustomExposure: true,
                             supportsCustomWhiteBalance: true, hasTorch: true)
        }
        return DeviceCapabilities(modelIdentifier: "Demo (Simulador)", systemVersion: UIDevice.current.systemVersion,
                                  cameras: [cam("demo.uw", .ultraWide, 13), cam("demo.w", .wide, 24), cam("demo.t", .telephoto, 120),
                                            cam("demo.f", .frontWide, 23, .front)],
                                  isMultiCamSupported: true, supportsExternalStorage: false, thermalSensitive: false)
    }
}
