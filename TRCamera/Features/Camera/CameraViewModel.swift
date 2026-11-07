import AVFoundation
import Observation
import SwiftUI

enum InterfaceMode: String, CaseIterable, Identifiable {
    case simple, pro
    var id: String { rawValue }
    var label: String { self == .simple ? "Simple" : "Pro" }
}

enum ParameterPanel: String, Identifiable {
    case iso, shutter, whiteBalance, focus, aperture, exposureBias, zoom
    var id: String { rawValue }
}

struct Banner: Identifiable, Equatable {
    enum Kind { case info, warning, error }
    var id = UUID()
    var kind: Kind
    var message: String
}

enum AppPhase: Equatable {
    case launching
    case cameraDenied
    case noCamera
    case ready
}

@MainActor
@Observable
final class CameraViewModel {
    // Dependencies
    let engine = ProfessionalCaptureEngine()
    let library = RecordingLibrary()
    let lutLibrary = LUTLibrary()
    private let presetStore = PresetStore()
    private let thermal = ThermalMonitor()
    private let level = LevelMonitor()

    // Device
    var phase: AppPhase = .launching
    var microphoneAuthorized = false
    var capabilities: DeviceCapabilities?
    var camera: CameraDescriptor?
    var configuration = CaptureConfiguration.fallback(cameraID: "")
    var format: FormatDescriptor?
    var codecs: [VideoCodec] = []
    var telemetry = CaptureTelemetry()
    var isSessionRunning = false

    // Manual controls
    var isoAuto = true
    var isoValue: Float = 100
    var shutterAuto = true
    var shutterSeconds: Double = 1.0 / 48
    var showShutterAsAngle = true
    var wbAuto = true
    var kelvin: Float = 5600
    var tint: Float = 0
    var focusAuto = true
    var focusPosition: Float = 0.5
    var exposureBias: Float = 0
    var aeLocked = false
    var apertureAuto = true
    var apertureValue: Float = 0

    // Monitoring & UI
    var monitoring = MonitoringSettings() { didSet { monitoringChanged() } }
    var scopes = ScopeData()
    var mode: InterfaceMode = .pro
    var activePanel: ParameterPanel?
    var showLookPicker = false
    /// Beat-reactive preview effect. Off = no audio analysis at all.
    var beatEffect: BeatEffect = .off { didSet { if beatEffect != oldValue { beatEffectChanged(from: oldValue) } } }
    var liveBPM: Double?
    var banner: Banner?
    var roll: Double = 0
    var thermalState: ProcessInfo.ThermalState = .nominal
    var pressureLevel: AVCaptureDevice.SystemPressureState.Level = .nominal
    var auxiliaryToolsSuspended = false

    // Recording
    var isRecording = false
    var destination: RecordingDestination = .appStorage
    var lastRecording: RecordingItem?
    var userPresets: [CapturePreset] = []

    private var defaults = UserDefaults.standard
    private let configKey = "lastConfiguration"

    init() {
        engine.onEvent = { [weak self] in self?.handle($0) }
        engine.monitoring.onScopes = { [weak self] data in
            DispatchQueue.main.async { self?.scopes = data }
        }
        engine.beats.onBeat = { [weak monitoring = engine.monitoring] in monitoring?.triggerBeat() }
        engine.beats.onTempo = { [weak self] bpm in DispatchQueue.main.async { self?.liveBPM = bpm } }
        userPresets = presetStore.load()
        lastRecording = library.items().first
    }

    // MARK: Bootstrap

    func bootstrap() async {
        guard phase == .launching else { return }
        if DemoCamera.isEnabled, AVCaptureDevice.default(for: .video) == nil || ProcessInfo.processInfo.arguments.contains("-demo") {
            startDemo()
            return
        }
        let videoGranted = await Self.requestAccess(for: .video)
        guard videoGranted else { phase = .cameraDenied; return }
        microphoneAuthorized = await Self.requestAccess(for: .audio)

        let caps = await Task.detached { CameraCapabilityEngine.discover() }.value
        capabilities = caps
        guard let initialCamera = caps.cameras.first(where: { $0.lens == .wide && $0.position == .back })
                ?? caps.cameras.first(where: { !$0.formats.isEmpty }) else {
            phase = .noCamera
            return
        }
        var initial = CaptureConfiguration(cameraID: initialCamera.id,
                                           resolution: VideoResolution(width: 3840, height: 2160),
                                           frameRate: 30, colorProfile: .rec709, codec: .hevc, stabilization: .cinematicExtended)
        var startCamera = initialCamera
        if let data = defaults.data(forKey: configKey),
           let saved = try? JSONDecoder().decode(CaptureConfiguration.self, from: data),
           let savedCamera = caps.cameras.first(where: { $0.id == saved.cameraID }) {
            initial = saved
            startCamera = savedCamera
        }
        camera = startCamera
        phase = .ready
        thermal.onChange = { [weak self] in self?.thermalChanged($0) }
        thermal.start()
        level.onRoll = { [weak self] in self?.roll = $0 }
        level.start()
        engine.configureSession(capabilities: caps, initial: initial, camera: startCamera, includeAudio: microphoneAuthorized)
        monitoringChanged()
    }

    // MARK: Demo (Simulator / UI review)

    private(set) var isDemo = false
    private let demoCamera = DemoCamera()

    private func startDemo() {
        isDemo = true
        let caps = DemoCamera.capabilities
        capabilities = caps
        let wide = caps.cameras[1]
        camera = wide
        phase = .ready
        isSessionRunning = true
        telemetry = CaptureTelemetry(iso: 200, exposureSeconds: 1.0 / 60, exposureOffsetEV: 0, kelvin: 5600, tint: 0,
                                     lensPosition: 0.6, aperture: 1.78, zoom: 1, audioAverageDB: [-24, -26], audioPeakDB: [-12, -14])
        level.onRoll = { [weak self] in self?.roll = $0 }
        demoCamera.start(feeding: engine.monitoring)
        applyConfiguration(CaptureConfiguration(cameraID: wide.id, resolution: VideoResolution(width: 3840, height: 2160), frameRate: 30,
                                                colorProfile: .rec709, codec: .hevc, stabilization: .cinematicExtended), camera: wide)
        if let look = ProcessInfo.processInfo.arguments.firstIndex(of: "-look").flatMap({ i in
            ProcessInfo.processInfo.arguments.indices.contains(i + 1) ? VideoLook(rawValue: ProcessInfo.processInfo.arguments[i + 1]) : nil
        }) { monitoring.look = look }
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-beat"), ProcessInfo.processInfo.arguments.indices.contains(i + 1),
           let effect = BeatEffect(rawValue: ProcessInfo.processInfo.arguments[i + 1]) { beatEffect = effect }
        monitoringChanged()
    }

    func setDemoPortrait(_ portrait: Bool) { demoCamera.setPortrait(portrait) }

    /// Single path for every format change. The demo resolves with the same rules
    /// the device uses and reports a plausible codec list for the chosen format.
    private func applyConfiguration(_ next: CaptureConfiguration, camera: CameraDescriptor) {
        guard isDemo else { engine.apply(next, camera: camera); return }
        let resolver = FormatResolver(camera: camera)
        guard let first = resolver.resolve(next) else { return }
        let codecs: [VideoCodec] = first.format.bitDepth >= 10 ? [.hevc, .h264, .proRes422HQ, .proRes422, .proRes422LT, .proRes422Proxy] : [.hevc, .h264]
        guard var resolved = resolver.resolve(first.configuration, availableCodecs: codecs) else { return }
        resolved.adjustments = first.adjustments + resolved.adjustments.filter { !first.adjustments.contains($0) }
        demoCamera.setResolution(resolved.configuration.resolution)
        handle(.configured(camera: camera, configuration: resolved.configuration, format: resolved.format, codecs: codecs, adjustments: resolved.adjustments))
    }

    private static func requestAccess(for media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: media)
        default: return false
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard self.phase == .ready else { return }
        switch phase {
        case .active: engine.start(); level.start()
        case .background: engine.stop(); level.stop()
        default: break
        }
    }

    // MARK: Engine events

    private func handle(_ event: EngineEvent) {
        switch event {
        case .sessionRunning(let running):
            isSessionRunning = running
        case let .configured(camera, configuration, format, codecs, adjustments):
            self.camera = camera
            self.configuration = configuration
            self.format = format
            self.codecs = codecs
            if let data = try? JSONEncoder().encode(configuration) { defaults.set(data, forKey: configKey) }
            if !adjustments.isEmpty { show(.info, adjustments.joined(separator: "\n")) }
            aeLocked = false
            clampManualValues()
            reapplyExposure()
        case .telemetry(let t):
            telemetry = t
        case .recordingStarted:
            isRecording = true
            UIApplication.shared.isIdleTimerDisabled = true
        case .recordingFinished(let result):
            isRecording = false
            UIApplication.shared.isIdleTimerDisabled = false
            finishRecording(result)
        case .interrupted(let reason):
            show(.warning, reason)
        case .interruptionEnded:
            banner = nil
        case let .systemPressure(level, factors):
            pressureLevel = level
            if level == .serious || level == .critical {
                setAuxiliarySuspended(true)
                show(.warning, "Pressão do sistema (\(factors.joined(separator: ", "))). Ferramentas de monitoramento pausadas para proteger a gravação.")
            } else if level == .shutdown {
                show(.error, "A câmera será desligada pelo sistema para resfriar.")
            } else if thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue {
                setAuxiliarySuspended(false)
            }
        case .failure(let message):
            show(.error, message)
        }
    }

    func show(_ kind: Banner.Kind, _ message: String) {
        let banner = Banner(kind: kind, message: message)
        self.banner = banner
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(kind == .error ? 6 : 4))
            if self?.banner?.id == banner.id { self?.banner = nil }
        }
    }

    // MARK: Format selection (always routed through FormatResolver)

    var resolver: FormatResolver? { camera.map(FormatResolver.init) }
    var availableResolutions: [VideoResolution] { resolver?.resolutions() ?? [] }
    var availableFrameRates: [Double] { resolver?.frameRates(for: configuration.resolution) ?? [] }
    var availableProfiles: [ColorProfile] { resolver?.colorProfiles(for: configuration.resolution, fps: configuration.frameRate) ?? [] }
    var availableStabilization: [StabilizationMode] {
        resolver?.stabilizationModes(for: configuration.resolution, fps: configuration.frameRate, profile: configuration.colorProfile) ?? []
    }
    var selectableCameras: [CameraDescriptor] { capabilities?.cameras.filter { !$0.formats.isEmpty } ?? [] }

    func update(_ change: (inout CaptureConfiguration) -> Void) {
        guard let camera, !isRecording else {
            if isRecording { show(.warning, "Pare a gravação para alterar o formato.") }
            return
        }
        var next = configuration
        change(&next)
        applyConfiguration(next, camera: camera)
    }

    func select(camera newCamera: CameraDescriptor) {
        guard !isRecording else { return }
        var next = configuration
        next.cameraID = newCamera.id
        applyConfiguration(next, camera: newCamera)
    }

    // MARK: Exposure / WB / Focus

    var isoRange: ClosedRange<Float> { (format?.minISO ?? 25)...(format?.maxISO ?? 3200) }
    var isoSteps: [Float] { ExposureMath.isoSteps(min: isoRange.lowerBound, max: isoRange.upperBound) }
    var shutterSteps: [Double] {
        ExposureMath.shutterSteps(fps: configuration.frameRate, minExposure: format?.minExposureSeconds ?? 1.0 / 10000, maxExposure: format?.maxExposureSeconds ?? 1)
    }
    var angleSteps: [Double] {
        ExposureMath.angleSteps(fps: configuration.frameRate, minExposure: format?.minExposureSeconds ?? 1.0 / 10000, maxExposure: format?.maxExposureSeconds ?? 1)
    }
    var priorityIsEmulated: Bool {
        if #available(iOS 27.0, *) { return false }
        return isoAuto != shutterAuto
    }

    func reapplyExposure() {
        engine.setExposure(iso: isoAuto ? .auto : .manual(isoValue),
                           shutter: shutterAuto ? .auto : .manual(shutterSeconds))
    }

    func setShutterAngle(_ angle: Double) {
        shutterSeconds = ExposureMath.exposureDuration(shutterAngle: angle, fps: configuration.frameRate)
        shutterAuto = false
        reapplyExposure()
    }

    func applyWhiteBalance() { engine.setWhiteBalance(kelvin: wbAuto ? nil : kelvin, tint: tint) }

    func applyFocus(rackDuration: Double = 0) {
        if focusAuto { engine.setFocusAuto() } else { engine.setFocus(lensPosition: focusPosition, duration: rackDuration) }
    }

    func focus(at devicePoint: CGPoint) {
        focusAuto = true
        engine.setFocusAuto(at: devicePoint)
    }

    func applyAperture() { engine.setAperture(apertureAuto ? nil : apertureValue) }

    private func clampManualValues() {
        isoValue = min(max(isoValue, isoRange.lowerBound), isoRange.upperBound)
        if let maxS = shutterSteps.first { shutterSeconds = min(shutterSeconds, maxS) }
        if let range = format?.lensApertureRange { apertureValue = min(max(apertureValue, range.lowerBound), range.upperBound) }
    }

    // MARK: Zoom

    /// Zoom buttons: physical switch-over points of the virtual device (optical), or
    /// 1× / 2× crop for a physical lens. Labelled with the system multiplier.
    var zoomPresets: [(factor: Double, label: String, optical: Bool)] {
        guard let camera else { return [] }
        let m = camera.displayZoomMultiplier
        if camera.isVirtual {
            let points = [camera.minZoom] + camera.switchOverZoomFactors
            return points.map { ($0, Self.zoomLabel($0 * m), true) }
        }
        var list = [(1.0, Self.zoomLabel(m), true)]
        if camera.maxZoom >= 2, let fmt = format, !fmt.isBinned { list.append((2.0, Self.zoomLabel(2 * m), false)) }
        return list
    }

    static func zoomLabel(_ v: Double) -> String {
        v < 1 ? String(format: ".%d×", Int((v * 10).rounded())) : (abs(v - v.rounded()) < 0.05 ? "\(Int(v.rounded()))×" : String(format: "%.1f×", v))
    }

    var isDigitalZoom: Bool {
        guard let camera else { return false }
        let lastOptical = camera.isVirtual ? (camera.switchOverZoomFactors.last ?? 1) : 1
        return telemetry.zoom > lastOptical + 0.01
    }

    var equivalentFocalLength: Double? {
        guard let base = camera?.equivalentFocalLength else { return nil }
        let start = camera?.isVirtual == true ? (camera?.minZoom ?? 1) : 1
        return base * telemetry.zoom / start
    }

    // MARK: Monitoring

    private func monitoringChanged() {
        let lut = monitoring.lutID.flatMap { lutLibrary.load(id: $0) }
        engine.monitoring.update(settings: monitoring, lut: lut)
        let enabled = !auxiliaryToolsSuspended && (monitoring.needsProcessedPreview || monitoring.needsAnalysis || beatEffect != .off)
        engine.setMonitoringEnabled(enabled)
        guard enabled, !isDemo, phase == .ready else { return }
        // Never fail silently: if no frames reach the processor, say so.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.isSessionRunning, !self.auxiliaryToolsSuspended,
                  self.monitoring.needsProcessedPreview || self.monitoring.needsAnalysis,
                  self.engine.monitoring.secondsSinceLastFrame > 1.5 else { return }
            Log.capture.error("Monitoring output delivered no frames")
            self.show(.warning, "Filtros e ferramentas de monitoramento não estão recebendo imagem neste formato. Tente outra resolução/fps e, se persistir, envie o Perfil do iPhone para análise.")
        }
    }

    var showsProcessedPreview: Bool { (monitoring.needsProcessedPreview || beatEffect != .off) && !auxiliaryToolsSuspended }

    // MARK: Beat detection

    private var demoBeatTimer: Timer?

    private func beatEffectChanged(from old: BeatEffect) {
        engine.monitoring.setBeatEffect(beatEffect)
        monitoringChanged()
        guard (old == .off) != (beatEffect == .off) else { return }
        if beatEffect == .off {
            demoBeatTimer?.invalidate(); demoBeatTimer = nil
            if !isDemo { engine.setBeatDetectionEnabled(false) { _ in } }
            liveBPM = nil
            return
        }
        if isDemo {
            // No microphone in the simulator: a steady 120 BPM shows the effect.
            liveBPM = 120
            demoBeatTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak monitoring = engine.monitoring] _ in
                monitoring?.triggerBeat()
            }
            return
        }
        guard microphoneAuthorized else {
            show(.error, "A detecção de batidas precisa do microfone. Ative em Ajustes › TR Camera.")
            beatEffect = .off
            return
        }
        engine.setBeatDetectionEnabled(true) { [weak self] ok in
            guard let self, !ok else { return }
            self.show(.error, self.isRecording
                      ? "Ative a detecção de batidas antes de começar a gravar."
                      : "Este iPhone não permite analisar o áudio junto com a gravação nesta configuração.")
            self.beatEffect = .off
        }
        show(.info, "Batidas: o efeito aparece só no preview. O vídeo é gravado limpo; aplique o efeito no ritmo pela Biblioteca.")
    }

    private func thermalChanged(_ state: ProcessInfo.ThermalState) {
        thermalState = state
        switch state {
        case .serious:
            setAuxiliarySuspended(true)
            show(.warning, "iPhone aquecido: ferramentas de monitoramento pausadas. A gravação continua na mesma qualidade.")
        case .critical:
            setAuxiliarySuspended(true)
            show(.error, "Temperatura crítica. Considere parar a gravação; o iOS pode interromper a câmera.")
        default:
            if pressureLevel != .serious && pressureLevel != .critical { setAuxiliarySuspended(false) }
        }
    }

    private func setAuxiliarySuspended(_ value: Bool) {
        guard auxiliaryToolsSuspended != value else { return }
        auxiliaryToolsSuspended = value
        engine.monitoring.setSuspended(value)
        monitoringChanged()
    }

    // MARK: Recording

    var estimatedMinutesRemaining: Double? {
        switch destination {
        case .appStorage:
            return library.freeBytes.map { StorageEstimator.minutesRemaining(freeBytes: $0, config: configuration) }
        case .external:
            return RecordingLibrary.externalDevice().map { StorageEstimator.minutesRemaining(freeBytes: Int64($0.freeSize), config: configuration, reserveBytes: 50_000_000) }
        }
    }

    func toggleRecording() {
        if isRecording { engine.stopRecording(); return }
        if isDemo { show(.info, "Modo demo: a gravação real precisa de um iPhone com câmera."); return }
        guard isSessionRunning else { show(.error, "A câmera não está ativa."); return }
        let minimum = Int64(StorageEstimator.bytesPerMinute(configuration)) + 300_000_000
        do {
            let url = try library.nextURL(destination: destination, minimumBytes: minimum)
            let meta = currentMetadata()
            pendingMetadata = meta
            engine.startRecording(to: url, metadata: RecordingLibrary.metadataItems(for: meta))
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    private var pendingMetadata: RecordingMetadata?

    private func currentMetadata() -> RecordingMetadata {
        RecordingMetadata(
            createdAt: Date(), deviceModel: capabilities?.modelIdentifier ?? "", systemVersion: capabilities?.systemVersion ?? "",
            camera: camera?.name ?? "", resolution: configuration.resolution.id, frameRate: configuration.frameRate,
            codec: configuration.codec.label, colorProfile: configuration.colorProfile.label, stabilization: configuration.stabilization.label,
            iso: isoAuto ? nil : isoValue, shutter: shutterAuto ? nil : ExposureMath.shutterLabel(shutterSeconds),
            whiteBalanceKelvin: wbAuto ? nil : kelvin, equivalentFocalLength: equivalentFocalLength, zoom: telemetry.zoom,
            lut: monitoring.lutID.map { "\($0) (somente preview)" },
            look: monitoring.look == .none ? nil : "\(monitoring.look.title) (somente preview)")
    }

    private func finishRecording(_ result: RecordingResult) {
        if var meta = pendingMetadata {
            meta.createdAt = Date()
            meta.beatMap = engine.beats.endRecording()
            library.writeSidecar(meta, for: result.url)
        }
        pendingMetadata = nil
        if let message = result.errorMessage {
            show(result.isPlayable ? .warning : .error,
                 result.isPlayable ? "Gravação finalizada com aviso: \(message). O arquivo foi preservado." : "Falha na gravação: \(message)")
        }
        lastRecording = library.items().first
    }

    func selectDestination(external: Bool) async {
        guard external else { destination = .appStorage; return }
        guard await RecordingLibrary.requestExternalAccess() else {
            show(.error, "Permissão para armazenamento externo negada.")
            return
        }
        if let device = RecordingLibrary.externalDevice() {
            destination = .external(name: device.displayName ?? "SSD")
        } else {
            show(.warning, "Nenhum armazenamento externo compatível conectado.")
        }
    }

    // MARK: Presets & advisor

    func recommendation(for goal: RecordingConfigurationAdvisor.Goal) -> RecordingConfigurationAdvisor.Recommendation? {
        guard let camera else { return nil }
        let context = RecordingConfigurationAdvisor.Context(camera: camera, freeBytes: library.freeBytes,
                                                            thermalElevated: thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue,
                                                            knownCodecs: nil)
        return RecordingConfigurationAdvisor().recommend(goal, context: context)
    }

    func apply(recommendation: RecordingConfigurationAdvisor.Recommendation) {
        guard let camera, recommendation.available else { return }
        applyConfiguration(recommendation.configuration, camera: camera)
        if let angle = recommendation.shutterAngle {
            shutterSeconds = ExposureMath.exposureDuration(shutterAngle: angle, fps: recommendation.configuration.frameRate)
            shutterAuto = false
            isoAuto = true
        } else {
            shutterAuto = true; isoAuto = true
        }
    }

    func apply(preset: CapturePreset) {
        guard let camera else { return }
        if let goal = preset.goal, preset.isBuiltIn, let rec = recommendation(for: goal) {
            if !rec.available { show(.warning, rec.limitations.joined(separator: "\n")); return }
            apply(recommendation: rec)
        } else if let validation = PresetValidator.validate(preset, camera: camera, knownCodecs: codecs) {
            applyConfiguration(validation.configuration, camera: camera)
            if !validation.isExact { show(.info, validation.substitutions.joined(separator: "\n")) }
            isoAuto = preset.exposure.iso == nil
            if let iso = preset.exposure.iso { isoValue = iso }
            shutterAuto = preset.exposure.shutterAngle == nil
            if let angle = preset.exposure.shutterAngle {
                shutterSeconds = ExposureMath.exposureDuration(shutterAngle: angle, fps: validation.configuration.frameRate)
            }
            wbAuto = preset.exposure.whiteBalanceKelvin == nil
            if let k = preset.exposure.whiteBalanceKelvin { kelvin = k }
            applyWhiteBalance()
        }
        monitoring = preset.monitoring
    }

    func saveCurrentAsPreset(named name: String) {
        var preset = CapturePreset(name: name, isBuiltIn: false, configuration: configuration)
        preset.exposure = ExposureIntent(iso: isoAuto ? nil : isoValue,
                                         shutterAngle: shutterAuto ? nil : ExposureMath.shutterAngle(exposure: shutterSeconds, fps: configuration.frameRate),
                                         whiteBalanceKelvin: wbAuto ? nil : kelvin,
                                         manualFocus: focusAuto ? nil : focusPosition)
        preset.monitoring = monitoring
        userPresets.append(preset)
        persistPresets()
    }

    func deletePreset(_ preset: CapturePreset) {
        userPresets.removeAll { $0.id == preset.id }
        persistPresets()
    }

    private func persistPresets() {
        do { try presetStore.save(userPresets) } catch { show(.error, "Não foi possível salvar o preset.") }
    }
}
