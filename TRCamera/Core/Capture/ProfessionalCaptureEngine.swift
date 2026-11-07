import AVFoundation
import UIKit

struct CaptureTelemetry: Equatable {
    var iso: Float = 0
    var exposureSeconds: Double = 0
    var exposureOffsetEV: Float = 0
    var kelvin: Float = 0
    var tint: Float = 0
    var lensPosition: Float = 0
    var aperture: Float = 0
    var zoom: Double = 1
    var isAdjustingFocus = false
    var audioAverageDB: [Float] = []
    var audioPeakDB: [Float] = []
    var recordedSeconds: Double = 0
    var recordedBytes: Int64 = 0
}

struct RecordingResult {
    var url: URL
    var duration: Double
    var isPlayable: Bool
    /// Present when the recording stopped with an error (file may still be valid).
    var errorMessage: String?
}

enum EngineEvent {
    case sessionRunning(Bool)
    case configured(camera: CameraDescriptor, configuration: CaptureConfiguration, format: FormatDescriptor, codecs: [VideoCodec], adjustments: [String])
    case telemetry(CaptureTelemetry)
    case recordingStarted(URL)
    case recordingFinished(RecordingResult)
    case interrupted(String)
    case interruptionEnded
    case systemPressure(level: AVCaptureDevice.SystemPressureState.Level, factors: [String])
    case failure(String)
}

/// Owns the AVCaptureSession. All session/device work happens on `sessionQueue`
/// (Apple's recommended pattern); results are delivered on the main queue through
/// `onEvent`. SwiftUI never talks to AVFoundation directly.
final class ProfessionalCaptureEngine: NSObject, @unchecked Sendable {
    enum ExposureControl { case auto, manual(Float) }
    enum ShutterControl { case auto, manual(Double) }

    let session = AVCaptureSession()
    let previewLayer: AVCaptureVideoPreviewLayer
    let monitoring = MonitoringProcessor()
    var onEvent: ((EngineEvent) -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.trmedia.camera.session", qos: .userInitiated)
    private let movieOutput = AVCaptureMovieFileOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var device: AVCaptureDevice? { videoInput?.device }
    private var currentCamera: CameraDescriptor?
    private var currentConfig: CaptureConfiguration?
    private var telemetryTimer: DispatchSourceTimer?
    private var observations: [NSKeyValueObservation] = []
    private var rotationObservations: [NSKeyValueObservation] = []
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var captureRotationAngle: CGFloat = 90
    private var notificationTokens: [NSObjectProtocol] = []
    private var isConfigured = false

    // Emulated priority modes for iOS < 27 (closed loop on exposureTargetOffset).
    private var emulatedISOPriority: Float?
    private var emulatedShutterPriority: Double?
    private var focusRamp: DispatchSourceTimer?

    override init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspect // show the true recorded framing
        super.init()
    }

    // MARK: Lifecycle

    func configureSession(capabilities: DeviceCapabilities, initial: CaptureConfiguration, camera: CameraDescriptor, includeAudio: Bool) {
        sessionQueue.async { [self] in
            guard !isConfigured else { return }
            session.beginConfiguration()
            session.sessionPreset = .inputPriority
            session.automaticallyConfiguresCaptureDeviceForWideColor = false
            session.automaticallyConfiguresApplicationAudioSession = false
            AudioRouteManager.shared.configureSession()

            if includeAudio, let mic = AVCaptureDevice.default(for: .audio),
               let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
                session.addInput(input)
                audioInput = input
            }
            if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
            videoDataOutput.alwaysDiscardsLateVideoFrames = true
            videoDataOutput.videoSettings = [:] // native format, no conversion cost
            videoDataOutput.setSampleBufferDelegate(monitoring, queue: monitoring.queue)
            if session.canAddOutput(videoDataOutput) { session.addOutput(videoDataOutput) }
            session.commitConfiguration()
            movieOutput.minFreeDiskSpaceLimit = 300_000_000
            isConfigured = true
            observeSession()
            applyLocked(initial, camera: camera)
            session.startRunning()
            emit(.sessionRunning(session.isRunning))
            startTelemetry()
        }
    }

    func start() {
        sessionQueue.async { [self] in
            guard isConfigured, !session.isRunning else { return }
            session.startRunning()
            emit(.sessionRunning(session.isRunning))
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            guard session.isRunning, !movieOutput.isRecording else { return }
            session.stopRunning()
            emit(.sessionRunning(false))
        }
    }

    // MARK: Format configuration

    func apply(_ configuration: CaptureConfiguration, camera: CameraDescriptor) {
        sessionQueue.async { [self] in applyLocked(configuration, camera: camera) }
    }

    private func applyLocked(_ requested: CaptureConfiguration, camera: CameraDescriptor) {
        guard !movieOutput.isRecording else {
            emit(.failure("Não é possível trocar o formato durante a gravação."))
            return
        }
        let resolver = FormatResolver(camera: camera)
        guard var resolved = resolver.resolve(requested),
              let newDevice = AVCaptureDevice(uniqueID: camera.id) else {
            emit(.failure("Câmera indisponível."))
            return
        }
        session.beginConfiguration()
        if videoInput?.device.uniqueID != newDevice.uniqueID {
            if let old = videoInput { session.removeInput(old) }
            do {
                let input = try AVCaptureDeviceInput(device: newDevice)
                if session.canAddInput(input) {
                    session.addInput(input)
                    videoInput = input
                } else if let old = videoInput, session.canAddInput(old) {
                    session.addInput(old)
                }
            } catch {
                session.commitConfiguration()
                emit(.failure("Falha ao abrir a câmera: \(error.localizedDescription)"))
                return
            }
            emulatedISOPriority = nil
            emulatedShutterPriority = nil
            DispatchQueue.main.async { [self] in setupRotation(for: newDevice) }
            observeDevice(newDevice)
        }

        do {
            try newDevice.lockForConfiguration()
            let format = newDevice.formats[resolved.format.index]
            newDevice.activeFormat = format
            if let space = AVCaptureColorSpace(rawValue: resolved.configuration.colorProfile.captureColorSpaceRawValue),
               format.supportedColorSpaces.contains(space) {
                newDevice.activeColorSpace = space
            }
            let duration = Self.frameDuration(resolved.configuration.frameRate)
            newDevice.activeVideoMinFrameDuration = duration
            newDevice.activeVideoMaxFrameDuration = duration
            if newDevice.isFocusModeSupported(.continuousAutoFocus) { newDevice.focusMode = .continuousAutoFocus }
            if newDevice.isExposureModeSupported(.continuousAutoExposure) { newDevice.exposureMode = .continuousAutoExposure }
            if newDevice.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { newDevice.whiteBalanceMode = .continuousAutoWhiteBalance }
            newDevice.unlockForConfiguration()
        } catch {
            emit(.failure("Falha ao configurar a câmera: \(error.localizedDescription)"))
        }
        session.commitConfiguration()

        // Codec availability depends on the active format: probe it now.
        let codecs = movieOutput.availableVideoCodecTypes.compactMap { VideoCodec(rawValue: $0.rawValue) }
        if let withCodec = resolver.resolve(resolved.configuration, availableCodecs: codecs) {
            resolved.adjustments += withCodec.adjustments.filter { !resolved.adjustments.contains($0) }
            resolved.configuration = withCodec.configuration
        }
        if let connection = movieOutput.connection(with: .video) {
            let codecType = AVVideoCodecType(rawValue: resolved.configuration.codec.rawValue)
            if movieOutput.availableVideoCodecTypes.contains(codecType) {
                movieOutput.setOutputSettings([AVVideoCodecKey: codecType], for: connection)
            }
            if connection.isVideoStabilizationSupported,
               let mode = AVCaptureVideoStabilizationMode(rawValue: resolved.configuration.stabilization.rawValue) {
                connection.preferredVideoStabilizationMode = mode
            }
        }
        currentCamera = camera
        currentConfig = resolved.configuration
        emit(.configured(camera: camera, configuration: resolved.configuration, format: resolved.format, codecs: codecs, adjustments: resolved.adjustments))
    }

    static func frameDuration(_ fps: Double) -> CMTime {
        let rounded = fps.rounded()
        if abs(fps - rounded) < 0.01 { return CMTime(value: 1, timescale: CMTimeScale(rounded)) }
        return CMTime(value: 1001, timescale: CMTimeScale((fps * 1001).rounded()))
    }

    // MARK: Exposure

    func setExposure(iso: ExposureControl, shutter: ShutterControl) {
        sessionQueue.async { [self] in
            guard let device else { return }
            emulatedISOPriority = nil
            emulatedShutterPriority = nil
            let format = device.activeFormat
            let maxVideo = min(format.maxExposureDuration.seconds, device.activeVideoMinFrameDuration.seconds)
            func clampISO(_ v: Float) -> Float { min(max(v, format.minISO), format.maxISO) }
            func clampDur(_ s: Double) -> CMTime {
                CMTime(seconds: min(max(s, format.minExposureDuration.seconds), maxVideo), preferredTimescale: 1_000_000)
            }
            withLock(device) { d in
                switch (iso, shutter) {
                case (.auto, .auto):
                    if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                case let (.manual(i), .manual(s)):
                    guard d.isExposureModeSupported(.custom) else { return }
                    d.setExposureModeCustom(duration: clampDur(s), iso: clampISO(i), completionHandler: nil)
                case let (.manual(i), .auto):
                    if !setNativePriority(d, duration: nil, iso: clampISO(i)) {
                        emulatedISOPriority = clampISO(i)
                        d.setExposureModeCustom(duration: AVCaptureDevice.currentExposureDuration, iso: clampISO(i), completionHandler: nil)
                    }
                case let (.auto, .manual(s)):
                    if !setNativePriority(d, duration: clampDur(s), iso: nil) {
                        emulatedShutterPriority = clampDur(s).seconds
                        d.setExposureModeCustom(duration: clampDur(s), iso: AVCaptureDevice.currentISO, completionHandler: nil)
                    }
                }
            }
        }
    }

    /// iOS 27 adds native priority modes (pass the "Auto" constant for the free parameter).
    private func setNativePriority(_ d: AVCaptureDevice, duration: CMTime?, iso: Float?) -> Bool {
        guard #available(iOS 27.0, *), d.isExposureModeSupported(.custom) else { return false }
        let dur = duration ?? AVCaptureDevice.autoExposureDuration
        let i = iso ?? AVCaptureDevice.autoISO
        guard d.activeFormat.supportsExposureModeCustom(lensAperture: AVCaptureDevice.currentLensAperture, duration: dur, iso: i) else { return false }
        d.setExposureModeCustom(duration: dur, iso: i, completionHandler: nil)
        return true
    }

    /// Variable aperture (iOS 27 hardware only). nil returns aperture to auto.
    func setAperture(_ value: Float?) {
        sessionQueue.async { [self] in
            guard #available(iOS 27.0, *), let device else { return }
            let format = device.activeFormat
            guard format.maxLensAperture > format.minLensAperture else { return }
            let target = value.map { min(max($0, format.minLensAperture), format.maxLensAperture) } ?? AVCaptureDevice.autoLensAperture
            let dur = AVCaptureDevice.autoExposureDuration, iso = AVCaptureDevice.autoISO
            guard format.supportsExposureModeCustom(lensAperture: target, duration: dur, iso: iso) else {
                emit(.failure("Esta combinação de abertura não é suportada pelo formato atual."))
                return
            }
            withLock(device) { $0.setExposureModeCustom(lensAperture: target, duration: dur, iso: iso, completionHandler: nil) }
        }
    }

    func setExposureBias(_ ev: Float) {
        sessionQueue.async { [self] in
            guard let device else { return }
            withLock(device) { d in
                d.setExposureTargetBias(min(max(ev, d.minExposureTargetBias), d.maxExposureTargetBias), completionHandler: nil)
            }
        }
    }

    func setAutoExposureLock(_ locked: Bool) {
        sessionQueue.async { [self] in
            guard let device else { return }
            emulatedISOPriority = nil
            emulatedShutterPriority = nil
            withLock(device) { d in
                let mode: AVCaptureDevice.ExposureMode = locked ? .locked : .continuousAutoExposure
                if d.isExposureModeSupported(mode) { d.exposureMode = mode }
            }
        }
    }

    // MARK: White balance

    func setWhiteBalance(kelvin: Float?, tint: Float = 0, locked: Bool = false) {
        sessionQueue.async { [self] in
            guard let device else { return }
            withLock(device) { d in
                if let kelvin, d.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                    let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: tint)
                    d.setWhiteBalanceModeLocked(with: Self.clamp(d.deviceWhiteBalanceGains(for: values), max: d.maxWhiteBalanceGain), completionHandler: nil)
                } else if locked, d.isWhiteBalanceModeSupported(.locked) {
                    d.whiteBalanceMode = .locked
                } else if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    d.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            }
        }
    }

    static func clamp(_ g: AVCaptureDevice.WhiteBalanceGains, max m: Float) -> AVCaptureDevice.WhiteBalanceGains {
        AVCaptureDevice.WhiteBalanceGains(redGain: min(max(g.redGain, 1), m), greenGain: min(max(g.greenGain, 1), m), blueGain: min(max(g.blueGain, 1), m))
    }

    // MARK: Focus

    func setFocusAuto(at devicePoint: CGPoint? = nil) {
        sessionQueue.async { [self] in
            guard let device else { return }
            focusRamp?.cancel()
            withLock(device) { d in
                if let p = devicePoint {
                    if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = p }
                    if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = p }
                    if d.isFocusModeSupported(.autoFocus) { d.focusMode = .autoFocus }
                    if d.exposureMode == .continuousAutoExposure || d.exposureMode == .autoExpose { d.exposureMode = .continuousAutoExposure }
                } else if d.isFocusModeSupported(.continuousAutoFocus) {
                    d.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
                    d.focusMode = .continuousAutoFocus
                }
            }
        }
    }

    func setFocusLocked() {
        sessionQueue.async { [self] in
            guard let device else { return }
            withLock(device) { if $0.isFocusModeSupported(.locked) { $0.focusMode = .locked } }
        }
    }

    /// Manual focus. With `duration` > 0 performs a smooth rack focus (stepped at 60 Hz),
    /// since AVFoundation has no lens-position ramp API.
    func setFocus(lensPosition target: Float, duration: Double = 0) {
        sessionQueue.async { [self] in
            guard let device, device.isLockingFocusWithCustomLensPositionSupported else { return }
            focusRamp?.cancel()
            let start = device.lensPosition
            let clampedTarget = min(max(target, 0), 1)
            guard duration > 0 else {
                withLock(device) { $0.setFocusModeLocked(lensPosition: clampedTarget, completionHandler: nil) }
                return
            }
            let steps = max(1, Int(duration * 60))
            var step = 0
            let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 60)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                step += 1
                let t = Float(step) / Float(steps)
                let eased = t * t * (3 - 2 * t) // smoothstep
                let value = start + (clampedTarget - start) * eased
                self.withLock(device) { $0.setFocusModeLocked(lensPosition: value, completionHandler: nil) }
                if step >= steps { self.focusRamp?.cancel() }
            }
            focusRamp = timer
            timer.resume()
        }
    }

    // MARK: Zoom

    func setZoom(_ factor: Double, rate: Float? = nil) {
        sessionQueue.async { [self] in
            guard let device else { return }
            let clamped = CGFloat(min(max(factor, Double(device.minAvailableVideoZoomFactor)), Double(device.maxAvailableVideoZoomFactor)))
            withLock(device) { d in
                if let rate { d.ramp(toVideoZoomFactor: clamped, withRate: rate) } else { d.videoZoomFactor = clamped }
            }
        }
    }

    // MARK: Monitoring

    func setMonitoringEnabled(_ enabled: Bool) {
        sessionQueue.async { [self] in
            videoDataOutput.connection(with: .video)?.isEnabled = enabled
        }
    }

    // MARK: Recording

    func startRecording(to url: URL, metadata: [AVMetadataItem]) {
        sessionQueue.async { [self] in
            guard !movieOutput.isRecording else { return }
            guard session.isRunning else {
                emit(.failure("A câmera não está ativa."))
                return
            }
            if let connection = movieOutput.connection(with: .video), connection.isVideoRotationAngleSupported(captureRotationAngle) {
                connection.videoRotationAngle = captureRotationAngle
            }
            movieOutput.metadata = metadata
            movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording() {
        sessionQueue.async { [self] in
            if movieOutput.isRecording { movieOutput.stopRecording() }
        }
    }

    var isRecording: Bool { movieOutput.isRecording }

    // MARK: Rotation

    @MainActor
    private func setupRotation(for device: AVCaptureDevice) {
        rotationObservations.removeAll()
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        let previewAngle = coordinator.videoRotationAngleForHorizonLevelPreview
        previewLayer.connection?.videoRotationAngle = previewAngle
        updateDataOutputRotation(previewAngle, mirrored: device.position == .front)
        captureRotationAngle = coordinator.videoRotationAngleForHorizonLevelCapture
        rotationObservations.append(coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] c, _ in
            let angle = c.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async {
                self?.previewLayer.connection?.videoRotationAngle = angle
                self?.updateDataOutputRotation(angle, mirrored: device.position == .front)
            }
        })
        rotationObservations.append(coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] c, _ in
            let angle = c.videoRotationAngleForHorizonLevelCapture
            self?.sessionQueue.async { self?.captureRotationAngle = angle }
        })
    }

    private func updateDataOutputRotation(_ angle: CGFloat, mirrored: Bool) {
        sessionQueue.async { [self] in
            guard let c = videoDataOutput.connection(with: .video) else { return }
            if c.isVideoRotationAngleSupported(angle) { c.videoRotationAngle = angle }
            if c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = mirrored
            }
        }
    }

    // MARK: Observation

    private func observeDevice(_ device: AVCaptureDevice) {
        observations.removeAll()
        observations.append(device.observe(\.systemPressureState, options: [.initial, .new]) { [weak self] d, _ in
            let state = d.systemPressureState
            var factors: [String] = []
            if state.factors.contains(.systemTemperature) { factors.append("temperatura") }
            if state.factors.contains(.peakPower) { factors.append("pico de energia") }
            if state.factors.contains(.depthModuleTemperature) { factors.append("módulo de profundidade") }
            if state.factors.contains(.cameraTemperature) { factors.append("temperatura da câmera") }
            self?.emit(.systemPressure(level: state.level, factors: factors))
        })
    }

    private func observeSession() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] note in
            var reason = "A câmera foi interrompida."
            if let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
               let r = AVCaptureSession.InterruptionReason(rawValue: raw) {
                switch r {
                case .videoDeviceNotAvailableInBackground: reason = "Câmera pausada em segundo plano."
                case .audioDeviceInUseByAnotherClient: reason = "O microfone está em uso por outro app."
                case .videoDeviceInUseByAnotherClient: reason = "A câmera está em uso por outro app."
                case .videoDeviceNotAvailableWithMultipleForegroundApps: reason = "Câmera indisponível com vários apps abertos."
                case .videoDeviceNotAvailableDueToSystemPressure: reason = "Câmera desligada pelo sistema por temperatura/energia."
                default: break
                }
            }
            self?.emit(.interrupted(reason))
        })
        notificationTokens.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            self?.emit(.interruptionEnded)
        })
        notificationTokens.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            guard let self else { return }
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
            self.emit(.failure("Erro da câmera: \(error?.localizedDescription ?? "desconhecido")"))
            if error?.code == .mediaServicesWereReset {
                self.sessionQueue.async { self.session.startRunning(); self.emit(.sessionRunning(self.session.isRunning)) }
            }
        })
    }

    // MARK: Telemetry

    private func startTelemetry() {
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now(), repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        telemetryTimer = timer
    }

    private func tick() {
        guard let device else { return }
        runEmulatedPriority(device)
        var t = CaptureTelemetry()
        t.iso = device.iso
        t.exposureSeconds = device.exposureDuration.seconds
        t.exposureOffsetEV = device.exposureTargetOffset
        let wb = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
        t.kelvin = wb.temperature
        t.tint = wb.tint
        t.lensPosition = device.lensPosition
        t.aperture = device.lensAperture
        t.zoom = Double(device.videoZoomFactor)
        t.isAdjustingFocus = device.isAdjustingFocus
        if let channels = movieOutput.connection(with: .audio)?.audioChannels {
            t.audioAverageDB = channels.map(\.averagePowerLevel)
            t.audioPeakDB = channels.map(\.peakHoldLevel)
        }
        if movieOutput.isRecording {
            t.recordedSeconds = movieOutput.recordedDuration.seconds
            t.recordedBytes = movieOutput.recordedFileSize
        }
        emit(.telemetry(t))
    }

    /// Software ISO/shutter priority for iOS 17–26: nudges the free parameter so the
    /// metered offset converges to 0 EV. Clearly labelled "emulado" in the UI.
    private func runEmulatedPriority(_ d: AVCaptureDevice) {
        let offset = d.exposureTargetOffset
        guard abs(offset) > 0.15, d.exposureMode == .custom else { return }
        let factor = pow(2, -offset * 0.5)
        let format = d.activeFormat
        if let shutter = emulatedShutterPriority {
            let iso = min(max(d.iso * factor, format.minISO), format.maxISO)
            withLock(d) { $0.setExposureModeCustom(duration: CMTime(seconds: shutter, preferredTimescale: 1_000_000), iso: iso, completionHandler: nil) }
        } else if let iso = emulatedISOPriority {
            let maxVideo = min(format.maxExposureDuration.seconds, d.activeVideoMinFrameDuration.seconds)
            let seconds = min(max(d.exposureDuration.seconds * Double(factor), format.minExposureDuration.seconds), maxVideo)
            withLock(d) { $0.setExposureModeCustom(duration: CMTime(seconds: seconds, preferredTimescale: 1_000_000), iso: iso, completionHandler: nil) }
        }
    }

    // MARK: Helpers

    private func withLock(_ device: AVCaptureDevice, _ body: (AVCaptureDevice) -> Void) {
        do {
            try device.lockForConfiguration()
            body(device)
            device.unlockForConfiguration()
        } catch {
            emit(.failure("Não foi possível controlar a câmera: \(error.localizedDescription)"))
        }
    }

    private func emit(_ event: EngineEvent) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }
}

extension ProfessionalCaptureEngine: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        emit(.recordingStarted(fileURL))
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        var playable = error == nil
        var message: String?
        if let error = error as NSError? {
            // Recordings stopped by disk-full / interruption are often still complete.
            playable = (error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false
            message = error.localizedDescription
        }
        let duration = output.recordedDuration.seconds
        emit(.recordingFinished(RecordingResult(url: outputFileURL, duration: duration, isPlayable: playable, errorMessage: message)))
    }
}
