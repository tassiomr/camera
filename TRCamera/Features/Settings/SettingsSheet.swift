import SwiftUI
import UniformTypeIdentifiers

struct SettingsSheet: View {
    @Bindable var model: CameraViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var importingLUT = false
    @State private var audioInputs: [AudioRouteManager.Input] = []
    @State private var selectedInput: String?
    @State private var gain: Float = AudioRouteManager.shared.gain

    var body: some View {
        NavigationStack {
            Form {
                formatSection
                monitoringSection
                guidesSection
                audioSection
                storageSection
                Section("Interface") {
                    Picker("Modo", selection: $model.mode) { ForEach(InterfaceMode.allCases) { Text($0.label).tag($0) } }
                }
            }
            .navigationTitle("Configurações")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
            .tint(Theme.accent)
            .fileImporter(isPresented: $importingLUT, allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data]) { result in
                do {
                    let entry = try model.lutLibrary.importLUT(from: result.get())
                    model.monitoring.lutID = entry.id
                } catch {
                    model.show(.error, "LUT inválida: \(error.localizedDescription)")
                }
            }
            .onAppear {
                audioInputs = AudioRouteManager.shared.availableInputs()
                selectedInput = AudioRouteManager.shared.currentInputID
            }
        }
    }

    // MARK: Format — every picker lists only combinations the hardware reports.

    private var formatSection: some View {
        Section {
            Picker("Lente", selection: Binding(get: { model.camera?.id ?? "" }, set: { id in
                if let cam = model.selectableCameras.first(where: { $0.id == id }) { model.select(camera: cam) }
            })) {
                ForEach(model.selectableCameras) { Text("\($0.lens.label) — \($0.name)").tag($0.id) }
            }
            Picker("Resolução", selection: Binding(get: { model.configuration.resolution }, set: { r in model.update { $0.resolution = r } })) {
                ForEach(model.availableResolutions) { Text($0.label).tag($0) }
            }
            Picker("Frame rate", selection: Binding(get: { model.configuration.frameRate }, set: { f in model.update { $0.frameRate = f } })) {
                ForEach(model.availableFrameRates, id: \.self) { Text("\(FrameRateFormatter.string($0)) fps").tag($0) }
            }
            Picker("Perfil de cor", selection: Binding(get: { model.configuration.colorProfile }, set: { p in model.update { $0.colorProfile = p } })) {
                ForEach(model.availableProfiles) { Text($0.label).tag($0) }
            }
            Picker("Codec", selection: Binding(get: { model.configuration.codec }, set: { c in model.update { $0.codec = c } })) {
                ForEach(model.codecs.isEmpty ? [model.configuration.codec] : model.codecs) { Text($0.label).tag($0) }
            }
            Picker("Estabilização", selection: Binding(get: { model.configuration.stabilization }, set: { s in model.update { $0.stabilization = s } })) {
                Text("Off").tag(StabilizationMode.off)
                ForEach(model.availableStabilization.filter { $0 != .off }) { Text($0.label).tag($0) }
            }
            LabeledContent("Estimativa", value: "\(StorageEstimator.format(bytes: StorageEstimator.bytesPerMinute(model.configuration)))/min")
            if let f = model.format {
                LabeledContent("Formato ativo", value: "\(f.pixelFormat) · \(f.bitDepth)-bit\(f.isBinned ? " · binned" : "")")
                LabeledContent("Curva / gamut", value: "\(model.configuration.colorProfile.transferCurve) · \(model.configuration.colorProfile.gamut)")
            }
        } header: { Text("Formato de gravação") } footer: {
            Text("Só aparecem combinações que esta lente realmente suporta. Ao mudar uma opção, as dependentes são ajustadas automaticamente. O controle de bitrate não é exposto pelo AVCaptureMovieFileOutput; o valor é uma estimativa.")
        }
    }

    private var monitoringSection: some View {
        Section {
            Toggle("Histograma", isOn: $model.monitoring.histogramEnabled)
            Toggle("Waveform", isOn: $model.monitoring.waveformEnabled)
            Toggle("Zebra", isOn: $model.monitoring.zebraEnabled)
            if model.monitoring.zebraEnabled {
                Picker("Nível da zebra", selection: $model.monitoring.zebraLevel) {
                    ForEach([0.7, 0.8, 0.9, 0.95, 1.0], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
                }
            }
            Toggle("Focus peaking", isOn: $model.monitoring.peakingEnabled)
            if model.monitoring.peakingEnabled {
                Picker("Cor", selection: $model.monitoring.peakingColor) {
                    ForEach(MonitoringSettings.PeakingColor.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                Slider(value: $model.monitoring.peakingSensitivity, in: 0...1) { Text("Intensidade") }
            }
            Toggle("False color", isOn: $model.monitoring.falseColorEnabled)
            Picker("LUT de visualização", selection: $model.monitoring.lutID) {
                Text("Nenhuma").tag(String?.none)
                ForEach(model.lutLibrary.entries()) { Text($0.title).tag(Optional($0.id)) }
            }
            Button("Importar LUT .cube…") { importingLUT = true }
            Picker("Desqueeze anamórfico", selection: $model.monitoring.anamorphicSqueeze) {
                ForEach([1.0, 1.33, 1.55, 1.8, 2.0], id: \.self) { Text($0 == 1 ? "Off" : String(format: "%.2fx", $0)).tag($0) }
            }
        } header: { Text("Monitoramento") } footer: {
            Text("Zebra e peaking medem o sinal gravado. LUT, false color e desqueeze afetam só a visualização — o arquivo nunca é alterado. Com essas ferramentas ativas o preview passa pelo processador (latência um pouco maior).")
        }
    }

    private var guidesSection: some View {
        Section("Guias") {
            Picker("Aspect ratio", selection: $model.monitoring.aspectGuide) {
                ForEach(MonitoringSettings.AspectGuide.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Regra dos terços", isOn: $model.monitoring.thirdsGrid)
            Toggle("Marca central", isOn: $model.monitoring.centerMark)
            Toggle("Safe areas (90/80%)", isOn: $model.monitoring.safeAreas)
            Toggle("Nível do horizonte", isOn: $model.monitoring.levelIndicator)
        }
    }

    private var audioSection: some View {
        Section {
            if model.microphoneAuthorized {
                Picker("Entrada", selection: Binding(get: { selectedInput ?? "" }, set: { id in
                    selectedInput = id
                    do { try AudioRouteManager.shared.select(inputID: id) } catch { model.show(.error, error.localizedDescription) }
                })) {
                    ForEach(audioInputs) { Text("\($0.name) (\($0.kind))").tag($0.id) }
                }
                if AudioRouteManager.shared.isGainSettable {
                    Slider(value: $gain, in: 0...1) { Text("Ganho") } onEditingChanged: { editing in
                        if !editing { try? AudioRouteManager.shared.setGain(gain) }
                    }
                } else {
                    Text("Esta entrada não permite ajuste de ganho pelo iOS.").font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Text("Microfone não autorizado: os vídeos serão gravados sem áudio. Ative em Ajustes › TR Camera.")
                    .font(.footnote).foregroundStyle(Theme.warning)
            }
        } header: { Text("Áudio") }
    }

    private var storageSection: some View {
        Section {
            Picker("Destino", selection: Binding(get: { model.destination == .appStorage ? 0 : 1 }, set: { v in
                Task { await model.selectDestination(external: v == 1) }
            })) {
                Text("iPhone").tag(0)
                Text("SSD externo (USB-C)").tag(1)
            }
            if let free = model.library.freeBytes {
                LabeledContent("Livre no iPhone", value: StorageEstimator.format(bytes: Double(free)))
            }
            if let minutes = model.estimatedMinutesRemaining {
                LabeledContent("Tempo restante (estimado)", value: StorageEstimator.format(minutes: minutes))
            }
        } header: { Text("Armazenamento") } footer: {
            Text("A gravação externa usa a API oficial AVExternalStorageDevice (iPhone com USB-C e drive compatível). Os arquivos também ficam acessíveis no app Arquivos.")
        }
    }
}
