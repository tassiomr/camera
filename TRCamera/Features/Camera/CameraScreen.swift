import SwiftUI
import TRDesignSystem

enum CameraSheet: String, Identifiable {
    case settings, presets, library, capabilities
    var id: String { rawValue }
}

struct CameraScreen: View {
    @Bindable var model: CameraViewModel
    @State private var sheet: CameraSheet?
    @State private var focusIndicator: CGPoint?
    @State private var pinchStartZoom: Double = 1
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.trTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let landscape = DebugLaunch.forceLandscape || geo.size.width > geo.size.height
            ZStack {
                switch model.phase {
                case .launching:
                    TRStateView(.loading, title: "Analisando as câmeras deste iPhone…")
                case .cameraDenied:
                    PermissionDeniedView()
                case .noCamera:
                    TRStateView(.error, title: "Câmera indisponível", message: "Nenhuma câmera de vídeo foi encontrada neste dispositivo.",
                                icon: .cameraUnavailable)
                case .ready:
                    Group { if landscape { landscapeLayout } else { portraitLayout } }
                        .onAppear { model.setDemoPortrait(!landscape) }
                        .onChange(of: landscape) { _, value in model.setDemoPortrait(!value) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.colors.background.primary)
            .modifier(DebugLandscapeModifier(size: geo.size))
        }
        // The viewfinder is dark in every appearance (it frames a live image);
        // only this subtree is forced dark, so sheets follow the system.
        .environment(\.colorScheme, .dark)
        // Keeps the HUD layout intact at the largest text sizes.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task {
            await model.bootstrap()
            DebugLaunch.apply(to: model) { sheet = $0 }
        }
        .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
        .sheet(item: $sheet, onDismiss: model.refreshLibrary) { sheet in
            Group {
                switch sheet {
                case .settings: SettingsSheet(model: model)
                case .presets: PresetsSheet(model: model)
                case .library: LibraryView(library: model.library)
                case .capabilities: CapabilityReportView(capabilities: model.capabilities)
                }
            }
            .trTheme(theme)
        }
    }

    private func animate(_ change: () -> Void) {
        withTRAnimation(.snappy, reduceMotion: reduceMotion, change)
    }

    // MARK: Layouts

    private var portraitLayout: some View {
        VStack(spacing: theme.spacing.stack.regular) {
            statusBar.padding(.horizontal, theme.spacing.sm)
            toolRow
            preview
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottom) { overlayPanel.padding(theme.spacing.xs) }
                .padding(.horizontal, theme.spacing.xxs)
            if model.mode == .pro {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: theme.spacing.stack.regular) { ParameterCards(model: model, compact: true) }
                        .padding(.horizontal, theme.spacing.sm)
                }
            }
            lensRow
            HStack {
                libraryButton
                Spacer()
                RecordButton(isRecording: model.isRecording, action: model.toggleRecording)
                Spacer()
                modeButton
            }
            .padding(.horizontal, theme.spacing.lg)
            .padding(.bottom, theme.spacing.xxs)
        }
    }

    private var landscapeLayout: some View {
        HStack(spacing: theme.spacing.stack.regular) {
            VStack(spacing: theme.spacing.stack.regular) {
                lensInfo
                ScrollView(showsIndicators: false) {
                    VStack(spacing: theme.spacing.stack.regular) { lensButtons(vertical: true) }
                }
                zoomButtons(vertical: true)
            }
            .frame(width: 84)
            .padding(.vertical, theme.spacing.sm)
            .background(RoundedRectangle.tr(theme.shape.card).fill(theme.colors.background.secondary))

            VStack(spacing: theme.spacing.stack.regular) {
                statusBar
                toolRow
                preview.overlay(alignment: .bottom) { overlayPanel.padding(theme.spacing.xs) }
            }

            HStack(spacing: theme.spacing.stack.regular) {
                if model.mode == .pro {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: theme.spacing.stack.regular) { ParameterCards(model: model, compact: false) }
                    }
                    .frame(width: 168)
                }
                VStack(spacing: theme.spacing.sm) {
                    modeButton
                    Spacer()
                    RecordButton(isRecording: model.isRecording, action: model.toggleRecording)
                    Text(model.isRecording ? "REC" : "VIDEO")
                        .trTextStyle(.overline)
                        .foregroundStyle(model.isRecording ? theme.colors.feedback.error : theme.colors.foreground.accent)
                    Spacer()
                    libraryButton
                }
                .frame(width: 84)
            }
            .padding(theme.spacing.xs)
            .background(RoundedRectangle.tr(theme.shape.card).fill(theme.colors.background.secondary))
        }
        .padding(.horizontal, theme.spacing.xs)
    }

    // MARK: Status & tools

    /// One readable line: what is being recorded, how much time is left, settings.
    private var statusBar: some View {
        let c = theme.colors
        return HStack(spacing: theme.spacing.stack.regular) {
            if model.isRecording {
                HStack(spacing: theme.spacing.xxs) {
                    Circle().fill(c.recording).frame(width: 8, height: 8)
                    Text(Self.timecode(model.telemetry.recordedSeconds)).trTextStyle(.metricSmall)
                }
                .foregroundStyle(c.foreground.primary)
                .fixedSize()
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Gravando \(Self.timecode(model.telemetry.recordedSeconds))")
            }
            Button { sheet = .settings } label: {
                HStack(spacing: theme.spacing.xxs) {
                    Text(model.configuration.summary)
                        .trTextStyle(.metricSmall)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    TRIconView(.chevronDown, size: .small).foregroundStyle(c.foreground.secondary)
                }
                .foregroundStyle(c.foreground.primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Formato de gravação: \(model.configuration.summary). Abrir configurações")
            Spacer(minLength: theme.spacing.xxs)
            if model.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                Image(systemName: "thermometer.high").foregroundStyle(c.feedback.error)
                    .accessibilityLabel("Temperatura alta")
            }
            if let minutes = model.estimatedMinutesRemaining {
                Label(StorageEstimator.format(minutes: minutes), systemImage: model.destination == .appStorage ? "internaldrive" : "externaldrive")
                    .trTextStyle(.footnote)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(minutes < 10 ? c.feedback.warning : c.foreground.secondary)
                    .fixedSize()
            }
            TRIconButton(.settings, label: "Configurações", variant: .secondary, size: .small) { sheet = .settings }
        }
        .frame(minHeight: theme.metrics.minimumHitTarget)
    }

    /// Monitoring tools as labelled chips. Scrolls instead of truncating.
    private var toolRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: theme.spacing.stack.regular) {
                TRTag(verbatim: model.monitoring.look == .none ? "Filtro" : model.monitoring.look.title, icon: .lookFilter,
                      isSelected: model.showLookPicker || model.monitoring.look != .none, onTap: {
                    animate { model.showLookPicker.toggle(); if model.showLookPicker { model.activePanel = nil } }
                })
                TRTag(verbatim: "Presets", icon: .presets, onTap: { sheet = .presets })
                beatMenu
                if model.mode == .pro {
                    TRTag(verbatim: "Zebra", icon: .zebra, isSelected: model.monitoring.zebraEnabled, onTap: { model.monitoring.zebraEnabled.toggle() })
                    TRTag(verbatim: "Peaking", icon: .peaking, isSelected: model.monitoring.peakingEnabled, onTap: { model.monitoring.peakingEnabled.toggle() })
                    TRTag(verbatim: "False color", icon: .falseColor, isSelected: model.monitoring.falseColorEnabled, onTap: { model.monitoring.falseColorEnabled.toggle() })
                    if model.configuration.colorProfile.isLog {
                        TRTag(verbatim: "LUT 709", icon: .lut, isSelected: model.monitoring.lutID != nil, onTap: {
                            model.monitoring.lutID = model.monitoring.lutID == nil ? BuiltInLUT.appleLogTo709.id : nil
                        })
                    }
                    TRTag(verbatim: "Histograma", icon: .histogram, isSelected: model.monitoring.histogramEnabled, onTap: { model.monitoring.histogramEnabled.toggle() })
                    TRTag(verbatim: "Waveform", icon: .waveformScope, isSelected: model.monitoring.waveformEnabled, onTap: { model.monitoring.waveformEnabled.toggle() })
                }
                TRTag(verbatim: "Lente", icon: .lensProfile, onTap: { sheet = .capabilities })
            }
            .padding(.horizontal, theme.spacing.sm)
        }
    }

    /// Beat-reactive preview effect. Disabled while recording: adding the audio
    /// analysis output reconfigures the session.
    private var beatMenu: some View {
        Menu {
            Picker("Efeito na batida", selection: $model.beatEffect) {
                ForEach(BeatEffect.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
            }
            Text("Só no preview. O vídeo é gravado limpo.")
        } label: {
            // The tag is only the look; the Menu handles the tap.
            TRTag(verbatim: beatTitle, icon: .beat, isSelected: model.beatEffect != .off)
                .monospacedDigit()
                .allowsHitTesting(false)
        }
        .disabled(model.isRecording && model.beatEffect == .off)
        .accessibilityLabel("Efeito na batida da música")
    }

    private var beatTitle: String {
        guard model.beatEffect != .off else { return "Batida" }
        if let bpm = model.liveBPM { return "\(Int(bpm.rounded())) BPM" }
        return "Ouvindo…"
    }

    // MARK: Preview

    private var preview: some View {
        let c = theme.colors
        let shape = RoundedRectangle.tr(theme.shape.card)
        return ZStack {
            PreviewContainer(engine: model.engine, showsProcessed: model.showsProcessedPreview || model.isDemo,
                             onTap: { layerPoint, devicePoint in
                                 model.focus(at: devicePoint)
                                 focusIndicator = layerPoint
                                 Task { try? await Task.sleep(for: .seconds(1.2)); focusIndicator = nil }
                             },
                             onPinch: { scale, state in
                                 if state == .began { pinchStartZoom = model.telemetry.zoom }
                                 model.engine.setZoom(pinchStartZoom * Double(scale))
                             })
            GuidesOverlay(settings: model.monitoring, videoAspect: videoAspect, roll: model.roll)
            if let p = focusIndicator {
                RoundedRectangle.tr(theme.shape.small).stroke(c.foreground.accent, lineWidth: 1.5)
                    .frame(width: 70, height: 70).position(p).allowsHitTesting(false)
            }
            VStack {
                HStack(alignment: .top) {
                    scopes
                    Spacer()
                    if !model.telemetry.audioAverageDB.isEmpty {
                        AudioMeterView(average: model.telemetry.audioAverageDB, peak: model.telemetry.audioPeakDB)
                    }
                }
                Spacer()
                if let banner = model.banner { BannerView(banner: banner).trTransition(.slide(.bottom)) }
            }
            .padding(theme.spacing.xs)
            if let job = model.postProcess {
                PostProcessPill(status: job)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, theme.spacing.sm)
                    .trTransition(.slide(.top))
                    .allowsHitTesting(false)
            }
            if model.isDemo {
                TRBadge(verbatim: "DEMO", tone: .warning, emphasis: .solid)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 84).padding(.trailing, theme.spacing.sm)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(c.recording.opacity(model.isRecording ? 1 : 0), lineWidth: TRBorder.emphasized))
        .trAnimation(.snappy, value: model.banner)
        .trAnimation(.snappy, value: model.postProcess == nil)
    }

    @ViewBuilder private var scopes: some View {
        if !model.auxiliaryToolsSuspended {
            VStack(alignment: .leading, spacing: theme.spacing.stack.regular) {
                if model.monitoring.histogramEnabled { HistogramView(data: model.scopes).frame(width: 120, height: 56) }
                if model.monitoring.waveformEnabled { WaveformView(data: model.scopes).frame(width: 120, height: 64) }
            }
        }
    }

    @ViewBuilder private var overlayPanel: some View {
        if model.showLookPicker {
            LookPicker(selection: $model.monitoring.look)
                .frame(maxWidth: 560)
                .trTransition(.slide(.bottom))
        } else if let panel = model.activePanel {
            ParameterAdjustPanel(model: model, panel: panel)
                .id(panel)
                .frame(maxWidth: 520)
                .trTransition(.slide(.bottom))
        }
    }

    private var videoAspect: CGFloat {
        let r = model.configuration.resolution
        guard r.height > 0 else { return 16 / 9 }
        let landscapeAspect = CGFloat(r.width) / CGFloat(r.height) * CGFloat(model.monitoring.anamorphicSqueeze)
        let landscape = DebugLaunch.forceLandscape || UIScreen.main.bounds.width > UIScreen.main.bounds.height
        return landscape ? landscapeAspect : 1 / landscapeAspect
    }

    // MARK: Lenses & zoom

    private var lensInfo: some View {
        let c = theme.colors
        return VStack(spacing: theme.spacing.xxxs) {
            Image(systemName: "camera.aperture").foregroundStyle(c.foreground.accent)
            if let f = model.equivalentFocalLength {
                Text("\(Int(f.rounded())) mm").trTextStyle(.metricSmall).foregroundStyle(c.foreground.primary)
            }
            Text(model.isDigitalZoom ? "Digital" : (model.camera?.lens.label ?? ""))
                .trTextStyle(.overline)
                .foregroundStyle(model.isDigitalZoom ? c.feedback.warning : c.foreground.secondary)
        }
    }

    private func lensButtons(vertical: Bool) -> some View {
        ForEach(model.selectableCameras.filter { !$0.isVirtual || $0.lens == .virtualMulti }) { cam in
            TRTag(verbatim: Self.lensLabel(cam), isSelected: cam.id == model.camera?.id, onTap: { model.select(camera: cam) })
                .fixedSize()
                .accessibilityLabel("Lente \(cam.lens.label)")
        }
    }

    @ViewBuilder private func zoomButtons(vertical: Bool) -> some View {
        let content = Group {
            ForEach(model.zoomPresets, id: \.factor) { preset in
                TRTag(verbatim: preset.label, isSelected: abs(model.telemetry.zoom - preset.factor) < 0.05, onTap: {
                    model.engine.setZoom(preset.factor, rate: 4)
                })
                .fixedSize()
            }
            TRIconButton(.zoomContinuous, label: "Zoom contínuo", variant: model.activePanel == .zoom ? .primary : .secondary, size: .small) {
                animate { model.showLookPicker = false; model.activePanel = model.activePanel == .zoom ? nil : .zoom }
            }
        }
        if vertical {
            VStack(spacing: theme.spacing.stack.regular) { content }
        } else {
            HStack(spacing: theme.spacing.stack.tight) { content }
        }
    }

    private var lensRow: some View {
        HStack(spacing: theme.spacing.stack.regular) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: theme.spacing.stack.regular) { lensButtons(vertical: false) }.padding(.leading, theme.spacing.sm)
            }
            zoomButtons(vertical: false).padding(.trailing, theme.spacing.sm)
        }
    }

    /// Lenses are named by their 35 mm equivalent focal length (what filmmakers use).
    static func lensLabel(_ cam: CameraDescriptor) -> String {
        switch cam.lens {
        case .frontWide, .frontUltraWide: return "Frontal"
        case .virtualMulti: return "Auto"
        case .external: return "Externa"
        default:
            if let f = cam.equivalentFocalLength { return "\(Int(f.rounded())) mm" }
            return cam.lens.label
        }
    }

    // MARK: Buttons

    private var modeButton: some View {
        Button(model.mode == .pro ? "PRO" : "AUTO") { animate { model.mode = model.mode == .pro ? .simple : .pro } }
            .buttonStyle(.tr(.secondary, size: .large))
            .accessibilityLabel(model.mode == .pro ? "Modo Pro. Tocar para modo simples" : "Modo simples. Tocar para modo Pro")
    }

    private var libraryButton: some View {
        let shape = RoundedRectangle.tr(theme.shape.control)
        return Button { sheet = .library } label: {
            ThumbnailView(url: model.lastRecording?.url)
                .frame(width: 52, height: 52)
                .clipShape(shape)
                .overlay(shape.strokeBorder(theme.colors.border.default, lineWidth: TRBorder.default))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Biblioteca de vídeos")
    }

    static func timecode(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}

/// Launch arguments used to capture every screen in the Simulator for review.
enum DebugLaunch {
    static let args = ProcessInfo.processInfo.arguments
    static var forceLandscape: Bool { args.contains("-landscape") }

    static func value(_ key: String) -> String? {
        guard let i = args.firstIndex(of: key), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    @MainActor
    static func apply(to model: CameraViewModel, presentSheet: (CameraSheet) -> Void) {
        guard model.isDemo else { return }
        if args.contains("-simple") { model.mode = .simple }
        if args.contains("-lookPicker") { model.showLookPicker = true }
        if let panel = value("-panel").flatMap(ParameterPanel.init(rawValue:)) { model.activePanel = panel }
        if let sheet = value("-sheet").flatMap(CameraSheet.init(rawValue:)) { presentSheet(sheet) }
    }
}

/// Renders the landscape layout rotated inside a portrait Simulator (screenshot review only).
struct DebugLandscapeModifier: ViewModifier {
    var size: CGSize
    func body(content: Content) -> some View {
        if DebugLaunch.forceLandscape && size.height > size.width {
            content.frame(width: size.height, height: size.width).rotationEffect(.degrees(90)).frame(width: size.width, height: size.height)
        } else {
            content
        }
    }
}

struct BannerView: View {
    var banner: Banner

    var body: some View {
        TRBanner(LocalizedStringKey(banner.message), tone: tone)
            .frame(maxWidth: 520)
    }

    private var tone: TRTone {
        switch banner.kind {
        case .info: .info
        case .warning: .warning
        case .error: .error
        }
    }
}

/// Shown while the chosen filter is being applied to a just-recorded clip.
struct PostProcessPill: View {
    @Environment(\.trTheme) private var theme
    var status: PostProcessStatus

    var body: some View {
        let c = theme.colors
        HStack(spacing: theme.spacing.stack.regular) {
            ProgressView(value: status.progress)
                .progressViewStyle(.circular).controlSize(.small)
            Text("Aplicando \(status.title)… \(Int(status.progress * 100))%\(status.remaining > 1 ? " · +\(status.remaining - 1)" : "")")
                .trTextStyle(.footnote).fontWeight(.semibold).monospacedDigit()
                .foregroundStyle(c.foreground.primary)
        }
        .padding(.horizontal, theme.spacing.sm)
        .frame(minHeight: theme.metrics.height(.small))
        .trSurface(.overlay, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// Fills whatever frame it is given and never draws outside it: the image is an
/// overlay of a flexible background, so scaledToFill cannot grow the layout.
struct ThumbnailView: View {
    @Environment(\.trTheme) private var theme
    var url: URL?
    @State private var image: UIImage?
    private static let cache = NSCache<NSURL, UIImage>()

    var body: some View {
        Rectangle()
            .fill(theme.colors.background.tertiary)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    TRIconView(.film).foregroundStyle(theme.colors.foreground.tertiary)
                }
            }
            .clipped()
            .task(id: url) {
                guard let url else { image = nil; return }
                if let cached = Self.cache.object(forKey: url as NSURL) { image = cached; return }
                image = nil
                if let thumb = await RecordingLibrary.thumbnail(for: url) {
                    Self.cache.setObject(thumb, forKey: url as NSURL)
                    image = thumb
                }
            }
    }

    static func invalidate(_ url: URL) { cache.removeObject(forKey: url as NSURL) }
}

struct PermissionDeniedView: View {
    var body: some View {
        TRStateView(.error, title: "Acesso à câmera necessário",
                    message: "O Luminous Cam precisa da câmera para gravar. Tudo é processado localmente — nada é enviado para servidores.",
                    icon: .cameraPermission,
                    action: .init("Abrir Ajustes") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    })
    }
}
