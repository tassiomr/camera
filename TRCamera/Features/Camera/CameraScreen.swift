import SwiftUI

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

    var body: some View {
        GeometryReader { geo in
            let landscape = DebugLaunch.forceLandscape || geo.size.width > geo.size.height
            ZStack {
                Theme.background.ignoresSafeArea()
                switch model.phase {
                case .launching:
                    LaunchStateView()
                case .cameraDenied:
                    PermissionDeniedView()
                case .noCamera:
                    MessageStateView(icon: "video.slash", title: "Câmera indisponível", message: "Nenhuma câmera de vídeo foi encontrada neste dispositivo.")
                case .ready:
                    Group { if landscape { landscapeLayout } else { portraitLayout } }
                        .onAppear { model.setDemoPortrait(!landscape) }
                        .onChange(of: landscape) { _, value in model.setDemoPortrait(!value) }
                }
            }
            .modifier(DebugLandscapeModifier(size: geo.size))
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task {
            await model.bootstrap()
            DebugLaunch.apply(to: model) { sheet = $0 }
        }
        .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
        .sheet(item: $sheet) { sheet in
            Group {
                switch sheet {
                case .settings: SettingsSheet(model: model)
                case .presets: PresetsSheet(model: model)
                case .library: LibraryView(library: model.library)
                case .capabilities: CapabilityReportView(capabilities: model.capabilities)
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    // MARK: Layouts

    private var portraitLayout: some View {
        VStack(spacing: 10) {
            statusBar.padding(.horizontal, 12)
            toolRow
            preview
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottom) { overlayPanel.padding(8) }
                .padding(.horizontal, 6)
            if model.mode == .pro {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { ParameterCards(model: model, compact: true) }.padding(.horizontal, 12)
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
            .padding(.horizontal, 28)
            .padding(.bottom, 4)
        }
    }

    private var landscapeLayout: some View {
        HStack(spacing: 8) {
            VStack(spacing: 8) {
                lensInfo
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 8) { lensButtons(vertical: true) }
                }
                zoomButtons(vertical: true)
            }
            .frame(width: 84)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.panel))

            VStack(spacing: 8) {
                statusBar
                toolRow
                preview.overlay(alignment: .bottom) { overlayPanel.padding(8) }
            }

            HStack(spacing: 8) {
                if model.mode == .pro {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 8) { ParameterCards(model: model, compact: false) }
                    }
                    .frame(width: 168)
                }
                VStack(spacing: 12) {
                    modeButton
                    Spacer()
                    RecordButton(isRecording: model.isRecording, action: model.toggleRecording)
                    Text(model.isRecording ? "REC" : "VIDEO").font(Theme.label(11)).foregroundStyle(model.isRecording ? Theme.recording : Theme.accent)
                    Spacer()
                    libraryButton
                }
                .frame(width: 84)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.panel))
        }
        .padding(.horizontal, 8)
    }

    // MARK: Status & tools

    /// One readable line: what is being recorded, how much time is left, settings.
    private var statusBar: some View {
        HStack(spacing: 10) {
            if model.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(Theme.recording).frame(width: 8, height: 8)
                    Text(Self.timecode(model.telemetry.recordedSeconds)).font(Theme.value(15))
                }
                .fixedSize()
            }
            Button { sheet = .settings } label: {
                HStack(spacing: 6) {
                    Text(model.configuration.summary)
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                        .lineLimit(1).minimumScaleFactor(0.75)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textSecondary)
                }
                .foregroundStyle(Theme.textPrimary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Formato de gravação: \(model.configuration.summary). Abrir configurações")
            Spacer(minLength: 4)
            if model.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                Image(systemName: "thermometer.high").foregroundStyle(Theme.recording)
            }
            if let minutes = model.estimatedMinutesRemaining {
                Label(StorageEstimator.format(minutes: minutes), systemImage: model.destination == .appStorage ? "internaldrive" : "externaldrive")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(minutes < 10 ? Theme.warning : Theme.textSecondary)
                    .fixedSize()
            }
            Button { sheet = .settings } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36).background(Circle().fill(Theme.card))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Configurações")
        }
        .frame(height: 40)
    }

    /// Monitoring tools as labelled chips. Scrolls instead of truncating.
    private var toolRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ChipButton(title: model.monitoring.look == .none ? "Filtro" : model.monitoring.look.title,
                           isOn: model.showLookPicker || model.monitoring.look != .none, systemImage: "camera.filters") {
                    withAnimation(.snappy) { model.showLookPicker.toggle(); if model.showLookPicker { model.activePanel = nil } }
                }
                ChipButton(title: "Presets", systemImage: "square.stack.3d.up") { sheet = .presets }
                beatMenu
                if model.mode == .pro {
                    ChipButton(title: "Zebra", isOn: model.monitoring.zebraEnabled, systemImage: "line.diagonal") { model.monitoring.zebraEnabled.toggle() }
                    ChipButton(title: "Peaking", isOn: model.monitoring.peakingEnabled, systemImage: "scope") { model.monitoring.peakingEnabled.toggle() }
                    ChipButton(title: "False color", isOn: model.monitoring.falseColorEnabled, systemImage: "paintpalette") { model.monitoring.falseColorEnabled.toggle() }
                    if model.configuration.colorProfile.isLog {
                        ChipButton(title: "LUT 709", isOn: model.monitoring.lutID != nil, systemImage: "cube") {
                            model.monitoring.lutID = model.monitoring.lutID == nil ? BuiltInLUT.appleLogTo709.id : nil
                        }
                    }
                    ChipButton(title: "Histograma", isOn: model.monitoring.histogramEnabled, systemImage: "chart.bar") { model.monitoring.histogramEnabled.toggle() }
                    ChipButton(title: "Waveform", isOn: model.monitoring.waveformEnabled, systemImage: "waveform.path.ecg") { model.monitoring.waveformEnabled.toggle() }
                }
                ChipButton(title: "Lente", systemImage: "cpu") { sheet = .capabilities }
            }
            .padding(.horizontal, 12)
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
            HStack(spacing: 4) {
                Image(systemName: "metronome").font(.system(size: 12, weight: .semibold))
                Text(beatTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1).monospacedDigit()
            }
            .fixedSize()
            .padding(.horizontal, 12).frame(height: 34)
            .foregroundStyle(model.beatEffect != .off ? Color.black : Theme.textPrimary)
            .background(Capsule().fill(model.beatEffect != .off ? Theme.accent : Theme.card))
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
        ZStack {
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
                RoundedRectangle(cornerRadius: 4).stroke(Theme.accent, lineWidth: 1.5)
                    .frame(width: 70, height: 70).position(p).allowsHitTesting(false)
            }
            VStack {
                HStack(alignment: .top) {
                    scopes
                    Spacer()
                    if !model.telemetry.audioAverageDB.isEmpty {
                        AudioMeterView(average: model.telemetry.audioAverageDB, peak: model.telemetry.audioPeakDB).frame(height: 70)
                    }
                }
                Spacer()
                if let banner = model.banner { BannerView(banner: banner).transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
            .padding(8)
            if model.isDemo {
                Text("DEMO").font(Theme.label(9)).padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.warning)).foregroundStyle(.black)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(.top, 84).padding(.trailing, 10)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(model.isRecording ? Theme.recording : .clear, lineWidth: 2))
        .animation(.snappy, value: model.banner)
    }

    @ViewBuilder private var scopes: some View {
        if !model.auxiliaryToolsSuspended {
            VStack(alignment: .leading, spacing: 6) {
                if model.monitoring.histogramEnabled { HistogramView(data: model.scopes).frame(width: 120, height: 56) }
                if model.monitoring.waveformEnabled { WaveformView(data: model.scopes).frame(width: 120, height: 64) }
            }
        }
    }

    @ViewBuilder private var overlayPanel: some View {
        if model.showLookPicker {
            LookPicker(selection: $model.monitoring.look)
                .frame(maxWidth: 560)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let panel = model.activePanel {
            ParameterAdjustPanel(model: model, panel: panel)
                .id(panel)
                .frame(maxWidth: 520)
                .transition(.move(edge: .bottom).combined(with: .opacity))
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
        VStack(spacing: 3) {
            Image(systemName: "camera.aperture").foregroundStyle(Theme.accent)
            if let f = model.equivalentFocalLength {
                Text("\(Int(f.rounded())) mm").font(Theme.value(14)).foregroundStyle(Theme.textPrimary)
            }
            Text(model.isDigitalZoom ? "DIGITAL" : (model.camera?.lens.label.uppercased() ?? ""))
                .font(Theme.label(9)).foregroundStyle(model.isDigitalZoom ? Theme.warning : Theme.textSecondary)
        }
    }

    private func lensButtons(vertical: Bool) -> some View {
        ForEach(model.selectableCameras.filter { !$0.isVirtual || $0.lens == .virtualMulti }) { cam in
            let selected = cam.id == model.camera?.id
            Button { model.select(camera: cam) } label: {
                Text(Self.lensLabel(cam))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 12)
                    .frame(minWidth: vertical ? 68 : 0, minHeight: 38)
                    .background(Capsule().fill(selected ? Theme.accent : Theme.card))
                    .foregroundStyle(selected ? .black : .white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Lente \(cam.lens.label)")
        }
    }

    @ViewBuilder private func zoomButtons(vertical: Bool) -> some View {
        let content = Group {
            ForEach(model.zoomPresets, id: \.factor) { preset in
                let selected = abs(model.telemetry.zoom - preset.factor) < 0.05
                Button { model.engine.setZoom(preset.factor, rate: 4) } label: {
                    Text(preset.label).font(.system(size: 12, weight: .bold, design: .rounded))
                        .frame(width: 40, height: 32)
                        .background(Capsule().fill(selected ? Theme.accentDeep : Theme.card))
                }.buttonStyle(.plain)
            }
            Button { withAnimation(.snappy) { model.showLookPicker = false; model.activePanel = model.activePanel == .zoom ? nil : .zoom } } label: {
                Image(systemName: "plus.magnifyingglass").frame(width: 40, height: 32)
                    .background(Capsule().fill(model.activePanel == .zoom ? Theme.accentDeep : Theme.card))
            }.buttonStyle(.plain)
            .accessibilityLabel("Zoom contínuo")
        }
        if vertical { VStack(spacing: 6) { content } } else { HStack(spacing: 6) { content } }
    }

    private var lensRow: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { lensButtons(vertical: false) }.padding(.leading, 12)
            }
            zoomButtons(vertical: false).padding(.trailing, 12)
        }
        .foregroundStyle(.white)
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
        Button { withAnimation(.snappy) { model.mode = model.mode == .pro ? .simple : .pro } } label: {
            Text(model.mode == .pro ? "PRO" : "AUTO")
                .font(Theme.label(11))
                .frame(width: 52, height: 52)
                .background(Circle().fill(model.mode == .pro ? Theme.card : Theme.accentDeep))
                .overlay(Circle().stroke(Theme.accent.opacity(0.5), lineWidth: 1))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.mode == .pro ? "Modo Pro. Tocar para modo simples" : "Modo simples. Tocar para modo Pro")
    }

    private var libraryButton: some View {
        Button { sheet = .library } label: {
            ThumbnailView(url: model.lastRecording?.url)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.6), lineWidth: 1))
        }.buttonStyle(.plain)
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
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: banner.kind == .error ? "exclamationmark.octagon.fill" : banner.kind == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(banner.kind == .error ? Theme.recording : banner.kind == .warning ? Theme.warning : Theme.accent)
            Text(banner.message).font(.system(size: 13, weight: .medium)).foregroundStyle(.white).multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.8)))
        .frame(maxWidth: 520)
    }
}

struct ThumbnailView: View {
    var url: URL?
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Theme.card
            if let image { Image(uiImage: image).resizable().scaledToFill() } else { Image(systemName: "photo.on.rectangle").foregroundStyle(Theme.textSecondary) }
        }
        .task(id: url) { image = nil; if let url { image = await RecordingLibrary.thumbnail(for: url) } }
    }
}

struct LaunchStateView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView().tint(Theme.accent)
            Text("Analisando as câmeras deste iPhone…").font(.footnote).foregroundStyle(Theme.textSecondary)
        }
    }
}

struct MessageStateView: View {
    var icon: String
    var title: String
    var message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(Theme.accent)
            Text(title).font(.title3.bold())
            Text(message).font(.callout).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
        }.padding(32)
    }
}

struct PermissionDeniedView: View {
    var body: some View {
        VStack(spacing: 16) {
            MessageStateView(icon: "video.badge.ellipsis", title: "Acesso à câmera necessário",
                             message: "O Luminous Cam precisa da câmera para gravar. Tudo é processado localmente — nada é enviado para servidores.")
            Button("Abrir Ajustes") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(.black)
        }
    }
}
