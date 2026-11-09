import SwiftUI
import TRDesignSystem

struct PresetsSheet: View {
    @Bindable var model: CameraViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var askingName = false
    @State private var selectedGoal: RecordingConfigurationAdvisor.Goal?

    var body: some View {
        NavigationStack {
            List {
                Group {
                    Section("Presets inteligentes") {
                        ForEach(BuiltInPresets.goals) { goal in
                            let rec = model.recommendation(for: goal)
                            Button {
                                selectedGoal = goal
                            } label: {
                                TRListRow(verbatim: goal.title, subtitle: rec?.configuration.summary ?? "—", showsChevron: true) {
                                    if rec?.available == false { TRBadge("Indisponível", tone: .warning) }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Section("Meus presets") {
                        ForEach(model.userPresets) { preset in
                            Button { model.apply(preset: preset); dismiss() } label: {
                                TRListRow(verbatim: preset.name, subtitle: preset.configuration?.summary ?? "")
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { idx in idx.map { model.userPresets[$0] }.forEach(model.deletePreset) }
                        Button("Salvar configuração atual…", systemImage: "plus") { askingName = true }
                    }
                }
                .themedListRows()
            }
            .themedGroupedList()
            .navigationTitle("Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
            .alert("Nome do preset", isPresented: $askingName) {
                TextField("Ex.: Entrevista externa", text: $newName)
                Button("Salvar") { if !newName.isEmpty { model.saveCurrentAsPreset(named: newName); newName = "" } }
                Button("Cancelar", role: .cancel) {}
            }
            .navigationDestination(item: $selectedGoal) { goal in
                AdvisorDetail(model: model, goal: goal) { dismiss() }
            }
        }
    }
}

/// Shows the advisor's reasoning before applying — recommendations are transparent.
struct AdvisorDetail: View {
    @Bindable var model: CameraViewModel
    let goal: RecordingConfigurationAdvisor.Goal
    var onApplied: () -> Void

    var body: some View {
        let rec = model.recommendation(for: goal)
        List {
            Group { advisorSections(rec) }.themedListRows()
        }
        .themedGroupedList()
        .navigationTitle(goal.title)
    }

    @ViewBuilder private func advisorSections(_ rec: RecordingConfigurationAdvisor.Recommendation?) -> some View {
        Section { Text(goal.question).trTextStyle(.headline) }
        if let rec {
            Section("Configuração") {
                TRKeyValueRow("Resolução", value: rec.configuration.resolution.label, isNumeric: true)
                TRKeyValueRow("Frame rate", value: "\(FrameRateFormatter.string(rec.configuration.frameRate)) fps", isNumeric: true)
                TRKeyValueRow("Codec", value: rec.configuration.codec.label)
                TRKeyValueRow("Perfil", value: rec.configuration.colorProfile.label)
                TRKeyValueRow("Estabilização", value: rec.configuration.stabilization.label)
                if let angle = rec.shutterAngle {
                    TRKeyValueRow("Shutter", value: "\(ExposureMath.angleLabel(angle)) (\(ExposureMath.shutterLabel(ExposureMath.exposureDuration(shutterAngle: angle, fps: rec.configuration.frameRate))))", isNumeric: true)
                }
            }
            if !rec.reasons.isEmpty {
                Section("Por quê") { ForEach(rec.reasons, id: \.self) { Text($0) } }
            }
            if !rec.limitations.isEmpty {
                Section("Limitações neste iPhone") { ForEach(rec.limitations, id: \.self) { TRValidationMessage(.warning($0)) } }
            }
            Section {
                TRButton("Aplicar", fullWidth: true) {
                    model.apply(preset: BuiltInPresets.make(for: goal))
                    onApplied()
                }
                .disabled(!rec.available)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
    }
}

struct CapabilityReportView: View {
    let capabilities: DeviceCapabilities?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.trTheme) private var theme

    var body: some View {
        NavigationStack {
            List {
                Group { sections }.themedListRows()
            }
            .themedGroupedList()
            .navigationTitle("Perfil do iPhone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
                if let caps = capabilities, let data = try? JSONEncoder().encode(caps), let json = String(data: data, encoding: .utf8) {
                    ToolbarItem(placement: .topBarLeading) {
                        ShareLink(item: json, preview: SharePreview("Capacidades \(caps.modelIdentifier).json")) { TRIconView(.share) }
                    }
                }
            }
        }
    }

    @ViewBuilder private var sections: some View {
            if let caps = capabilities {
                Section("Dispositivo") {
                    TRKeyValueRow("Modelo", value: caps.modelIdentifier)
                    TRKeyValueRow("iOS", value: caps.systemVersion)
                    TRKeyValueRow("Multicâmera", value: caps.isMultiCamSupported ? "Sim" : "Não")
                    TRKeyValueRow("Gravação externa", value: caps.supportsExternalStorage ? "Sim" : "Não")
                    TRKeyValueRow("Apple Log", value: caps.supportsLog ? "Sim" : "Não")
                    TRKeyValueRow("HDR HLG", value: caps.supportsHLG ? "Sim" : "Não")
                    TRKeyValueRow("FPS máximo", value: FrameRateFormatter.string(caps.maxFrameRate), isNumeric: true)
                }
                ForEach(caps.cameras) { cam in
                    Section("\(cam.lens.label) — \(cam.name)") {
                        if let f = cam.equivalentFocalLength { TRKeyValueRow("Focal equivalente", value: "≈\(Int(f.rounded())) mm", isNumeric: true) }
                        TRKeyValueRow("Abertura", value: String(format: "f/%.2f", cam.fixedAperture), isNumeric: true)
                        TRKeyValueRow("Zoom", value: String(format: "%.1f–%.1f×", cam.minZoom, cam.maxZoom), isNumeric: true)
                        if !cam.switchOverZoomFactors.isEmpty {
                            TRKeyValueRow("Troca de lente em", value: cam.switchOverZoomFactors.map { String(format: "%.1f×", $0) }.joined(separator: ", "), isNumeric: true)
                        }
                        TRKeyValueRow("Formatos", value: "\(cam.formats.count)", isNumeric: true)
                        ForEach(cam.resolutions) { res in
                            let r = FormatResolver(camera: cam)
                            let fps = r.frameRates(for: res).map(FrameRateFormatter.string).joined(separator: "/")
                            let profiles = Set(r.frameRates(for: res).flatMap { r.colorProfiles(for: res, fps: $0) })
                            VStack(alignment: .leading, spacing: theme.spacing.xxxs) {
                                Text(res.label).trTextStyle(.bodyEmphasized).foregroundStyle(theme.colors.foreground.primary)
                                Text("\(fps) fps").trTextStyle(.footnote).monospacedDigit().foregroundStyle(theme.colors.foreground.secondary)
                                Text(ColorProfile.allCases.filter(profiles.contains).map(\.shortLabel).joined(separator: " · "))
                                    .trTextStyle(.footnote).foregroundStyle(theme.colors.foreground.accent)
                            }
                        }
                    }
                }
            } else {
                TRStateView(.loading, title: "Capacidades ainda não detectadas.")
            }
    }
}
