import SwiftUI

struct PresetsSheet: View {
    @Bindable var model: CameraViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var askingName = false
    @State private var selectedGoal: RecordingConfigurationAdvisor.Goal?

    var body: some View {
        NavigationStack {
            List {
                Section("Presets inteligentes") {
                    ForEach(BuiltInPresets.goals) { goal in
                        let rec = model.recommendation(for: goal)
                        Button {
                            selectedGoal = goal
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(goal.title).foregroundStyle(.white)
                                    Text(rec?.configuration.summary ?? "—").font(.caption).foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                                if rec?.available == false {
                                    Text("Indisponível").font(.caption2).foregroundStyle(Theme.warning)
                                }
                                Image(systemName: "chevron.right").foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
                Section("Meus presets") {
                    ForEach(model.userPresets) { preset in
                        Button { model.apply(preset: preset); dismiss() } label: {
                            VStack(alignment: .leading) {
                                Text(preset.name).foregroundStyle(.white)
                                Text(preset.configuration?.summary ?? "").font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                    .onDelete { idx in idx.map { model.userPresets[$0] }.forEach(model.deletePreset) }
                    Button("Salvar configuração atual…", systemImage: "plus") { askingName = true }
                }
            }
            .navigationTitle("Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
            .tint(Theme.accent)
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
            Section { Text(goal.question).font(.headline) }
            if let rec {
                Section("Configuração") {
                    LabeledContent("Resolução", value: rec.configuration.resolution.label)
                    LabeledContent("Frame rate", value: "\(FrameRateFormatter.string(rec.configuration.frameRate)) fps")
                    LabeledContent("Codec", value: rec.configuration.codec.label)
                    LabeledContent("Perfil", value: rec.configuration.colorProfile.label)
                    LabeledContent("Estabilização", value: rec.configuration.stabilization.label)
                    if let angle = rec.shutterAngle {
                        LabeledContent("Shutter", value: "\(ExposureMath.angleLabel(angle)) (\(ExposureMath.shutterLabel(ExposureMath.exposureDuration(shutterAngle: angle, fps: rec.configuration.frameRate))))")
                    }
                }
                if !rec.reasons.isEmpty {
                    Section("Por quê") { ForEach(rec.reasons, id: \.self) { Text($0) } }
                }
                if !rec.limitations.isEmpty {
                    Section("Limitações neste iPhone") { ForEach(rec.limitations, id: \.self) { Text($0).foregroundStyle(Theme.warning) } }
                }
                Section {
                    Button("Aplicar") {
                        model.apply(preset: BuiltInPresets.make(for: goal))
                        onApplied()
                    }
                    .disabled(!rec.available)
                }
            }
        }
        .navigationTitle(goal.title)
    }
}

struct CapabilityReportView: View {
    let capabilities: DeviceCapabilities?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let caps = capabilities {
                    Section("Dispositivo") {
                        LabeledContent("Modelo", value: caps.modelIdentifier)
                        LabeledContent("iOS", value: caps.systemVersion)
                        LabeledContent("Multicâmera", value: caps.isMultiCamSupported ? "Sim" : "Não")
                        LabeledContent("Gravação externa", value: caps.supportsExternalStorage ? "Sim" : "Não")
                        LabeledContent("Apple Log", value: caps.supportsLog ? "Sim" : "Não")
                        LabeledContent("HDR HLG", value: caps.supportsHLG ? "Sim" : "Não")
                        LabeledContent("FPS máximo", value: FrameRateFormatter.string(caps.maxFrameRate))
                    }
                    ForEach(caps.cameras) { cam in
                        Section("\(cam.lens.label) — \(cam.name)") {
                            if let f = cam.equivalentFocalLength { LabeledContent("Focal equivalente", value: "≈\(Int(f.rounded())) mm") }
                            LabeledContent("Abertura", value: String(format: "f/%.2f", cam.fixedAperture))
                            LabeledContent("Zoom", value: String(format: "%.1f–%.1f×", cam.minZoom, cam.maxZoom))
                            if !cam.switchOverZoomFactors.isEmpty {
                                LabeledContent("Troca de lente em", value: cam.switchOverZoomFactors.map { String(format: "%.1f×", $0) }.joined(separator: ", "))
                            }
                            LabeledContent("Formatos", value: "\(cam.formats.count)")
                            ForEach(cam.resolutions) { res in
                                let r = FormatResolver(camera: cam)
                                let fps = r.frameRates(for: res).map(FrameRateFormatter.string).joined(separator: "/")
                                let profiles = Set(r.frameRates(for: res).flatMap { r.colorProfiles(for: res, fps: $0) })
                                VStack(alignment: .leading) {
                                    Text(res.label).font(.subheadline.bold())
                                    Text("\(fps) fps").font(.caption)
                                    Text(ColorProfile.allCases.filter(profiles.contains).map(\.shortLabel).joined(separator: " · "))
                                        .font(.caption).foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                } else {
                    Text("Capacidades ainda não detectadas.")
                }
            }
            .navigationTitle("Perfil do iPhone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
                if let caps = capabilities, let data = try? JSONEncoder().encode(caps), let json = String(data: data, encoding: .utf8) {
                    ToolbarItem(placement: .topBarLeading) {
                        ShareLink(item: json, preview: SharePreview("Capacidades \(caps.modelIdentifier).json")) { Image(systemName: "square.and.arrow.up") }
                    }
                }
            }
            .tint(Theme.accent)
        }
    }
}
