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
            let landscape = geo.size.width > geo.size.height
            ZStack {
                Theme.background.ignoresSafeArea()
                switch model.phase {
                case .launching:
                    LaunchStateView()
                case .cameraDenied:
                    PermissionDeniedView()
                case .noCamera:
                    MessageStateView(icon: "video.slash", title: "Câmera indisponível", message: "Nenhuma câmera de vídeo foi encontrada neste dispositivo. O simulador não possui câmera: use um iPhone físico.")
                case .ready:
                    if landscape { landscapeLayout } else { portraitLayout }
                }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task { await model.bootstrap() }
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
            topBar
            preview
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottom) { adjustPanel.padding(8) }
            if model.mode == .pro {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { ParameterCards(model: model, compact: true) }.padding(.horizontal, 12)
                }
            }
            lensRow.padding(.horizontal, 12)
            HStack {
                libraryButton
                Spacer()
                RecordButton(isRecording: model.isRecording, action: model.toggleRecording)
                Spacer()
                VStack(spacing: 10) {
                    iconButton("slider.horizontal.3") { sheet = .settings }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 6)
        }
    }

    private var landscapeLayout: some View {
        HStack(spacing: 10) {
            VStack(spacing: 10) {
                lensInfo
                Spacer()
                VStack(spacing: 8) { lensButtons }
                Spacer()
                iconButton("square.stack.3d.up") { sheet = .presets }
                iconButton("cpu") { sheet = .capabilities }
            }
            .frame(width: 70)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.panel))

            VStack(spacing: 8) {
                topBar
                preview.overlay(alignment: .bottom) { adjustPanel.padding(8) }
            }

            HStack(spacing: 10) {
                if model.mode == .pro {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 8) { ParameterCards(model: model, compact: false) }
                    }
                    .frame(width: 170)
                }
                VStack(spacing: 14) {
                    iconButton("slider.horizontal.3") { sheet = .settings }
                    Spacer()
                    RecordButton(isRecording: model.isRecording, action: model.toggleRecording)
                    Text(model.isRecording ? "REC" : "VIDEO").font(Theme.label(10)).foregroundStyle(model.isRecording ? Theme.recording : Theme.accent)
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

    // MARK: Pieces

    private var preview: some View {
        ZStack {
            PreviewContainer(engine: model.engine, showsProcessed: model.showsProcessedPreview,
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

    @ViewBuilder private var adjustPanel: some View {
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
        let landscape = CGFloat(r.width) / CGFloat(r.height) * CGFloat(model.monitoring.anamorphicSqueeze)
        return UIDevice.current.orientation.isLandscape || UIScreen.main.bounds.width > UIScreen.main.bounds.height ? landscape : 1 / landscape
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            if model.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(Theme.recording).frame(width: 8, height: 8)
                    Text(Self.timecode(model.telemetry.recordedSeconds)).font(Theme.value(14))
                }
                .padding(.horizontal, 10).frame(height: 32).background(Capsule().fill(Theme.card))
            }
            Button { sheet = .settings } label: {
                Text(model.configuration.summary).font(.system(size: 11, weight: .bold).width(.expanded))
                    .padding(.horizontal, 10).frame(height: 32).background(Capsule().fill(Theme.card))
            }.buttonStyle(.plain)
            ChipButton(title: model.monitoring.look == .none ? "FILTRO" : model.monitoring.look.title.uppercased(),
                       isOn: model.showLookPicker || model.monitoring.look != .none, systemImage: "camera.filters") {
                withAnimation(.snappy) { model.showLookPicker.toggle(); if model.showLookPicker { model.activePanel = nil } }
            }
            ChipButton(title: "ZEBRA", isOn: model.monitoring.zebraEnabled) { model.monitoring.zebraEnabled.toggle() }
            ChipButton(title: "PEAK", isOn: model.monitoring.peakingEnabled) { model.monitoring.peakingEnabled.toggle() }
            if model.configuration.colorProfile.isLog {
                ChipButton(title: "LUT", isOn: model.monitoring.lutID != nil) {
                    model.monitoring.lutID = model.monitoring.lutID == nil ? BuiltInLUT.appleLogTo709.id : nil
                }
            }
            Spacer(minLength: 0)
            if model.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                Image(systemName: "thermometer.high").foregroundStyle(Theme.recording)
            }
            if let minutes = model.estimatedMinutesRemaining {
                Label(StorageEstimator.format(minutes: minutes), systemImage: model.destination == .appStorage ? "internaldrive" : "externaldrive")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(minutes < 10 ? Theme.warning : Theme.textSecondary)
            }
            Picker("", selection: $model.mode) {
                ForEach(InterfaceMode.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).frame(width: 110)
        }
        .padding(.horizontal, 8)
        .lineLimit(1)
    }

    private var lensInfo: some View {
        VStack(spacing: 4) {
            Image(systemName: "camera.aperture").foregroundStyle(Theme.accent)
            Text(model.camera?.lens.label.uppercased() ?? "").font(Theme.label(8)).foregroundStyle(Theme.textSecondary)
            if let f = model.equivalentFocalLength {
                Text("≈\(Int(f.rounded()))MM").font(Theme.label(9)).foregroundStyle(Theme.textPrimary)
            }
            if model.isDigitalZoom {
                Text("DIGITAL").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.warning)
            }
        }
    }

    @ViewBuilder private var lensButtons: some View {
        ForEach(model.selectableCameras.filter { !$0.isVirtual || $0.lens == .virtualMulti }) { cam in
            Button { model.select(camera: cam) } label: {
                Text(lensShortLabel(cam))
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(cam.id == model.camera?.id ? Theme.accent : Theme.card))
                    .foregroundStyle(cam.id == model.camera?.id ? .black : .white)
            }.buttonStyle(.plain)
        }
    }

    private var lensRow: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { lensButtons } }
            Divider().frame(height: 30).overlay(Theme.textSecondary.opacity(0.3))
            ForEach(model.zoomPresets, id: \.factor) { preset in
                Button { model.engine.setZoom(preset.factor, rate: 4) } label: {
                    Text(preset.label).font(.system(size: 11, weight: .bold))
                        .frame(width: 38, height: 30)
                        .background(Capsule().fill(abs(model.telemetry.zoom - preset.factor) < 0.05 ? Theme.accentDeep : Theme.card))
                }.buttonStyle(.plain)
            }
            Button { withAnimation(.snappy) { model.activePanel = model.activePanel == .zoom ? nil : .zoom } } label: {
                Image(systemName: "plus.magnifyingglass").frame(width: 30, height: 30)
            }.buttonStyle(.plain)
            iconButton("square.stack.3d.up") { sheet = .presets }
        }
        .foregroundStyle(.white)
    }

    private func lensShortLabel(_ cam: CameraDescriptor) -> String {
        switch cam.lens {
        case .ultraWide: "UW"
        case .wide: "W"
        case .telephoto: "T"
        case .frontWide, .frontUltraWide: "F"
        case .virtualMulti: "A"
        case .external: "EXT"
        case .other: "C"
        }
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

    private func iconButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 17, weight: .semibold))
                .frame(width: 46, height: 46).background(Circle().fill(Theme.card)).foregroundStyle(.white)
        }.buttonStyle(.plain)
    }

    static func timecode(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}

struct BannerView: View {
    var banner: Banner
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: banner.kind == .error ? "exclamationmark.octagon.fill" : banner.kind == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(banner.kind == .error ? Theme.recording : banner.kind == .warning ? Theme.warning : Theme.accent)
            Text(banner.message).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.75)))
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
                             message: "O TR Camera precisa da câmera para gravar. Tudo é processado localmente — nada é enviado para servidores.")
            Button("Abrir Ajustes") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(.black)
        }
    }
}
