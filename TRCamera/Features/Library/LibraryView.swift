import AVKit
import SwiftUI

struct LibraryView: View {
    let library: RecordingLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var items: [RecordingItem] = []

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 4)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if items.isEmpty {
                    MessageStateView(icon: "film.stack", title: "Nenhum vídeo ainda", message: "Suas gravações aparecem aqui e também no app Arquivos › Luminous Cam.")
                        .padding(.top, 60)
                }
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(items) { item in
                        NavigationLink(value: item) { LibraryCell(item: item) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(4)
            }
            .navigationTitle("Biblioteca")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
            .navigationDestination(for: RecordingItem.self) { item in
                RecordingDetailView(library: library, item: item) { items = library.items() }
            }
            .onAppear { items = library.items() }
            .tint(Theme.accent)
        }
    }
}

/// Square cell: the size comes from the grid column, never from the image.
private struct LibraryCell: View {
    let item: RecordingItem

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { ThumbnailView(url: item.url) }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topLeading) {
                if let edit = item.metadata?.editLabel {
                    Label(edit, systemImage: item.metadata?.beatEffect != nil ? "metronome" : "camera.filters")
                        .font(.system(size: 9, weight: .bold)).lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .foregroundStyle(.black)
                        .background(Capsule().fill(Theme.accent))
                        .padding(5)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let format = formatLabel {
                    Text(format)
                        .font(.system(size: 9, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(.black.opacity(0.6))).padding(5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel(item.name)
    }

    private var formatLabel: String? {
        guard let m = item.metadata, let height = m.resolution.split(separator: "x").last, m.frameRate > 0 else { return nil }
        return "\(height)p\(FrameRateFormatter.string(m.frameRate))"
    }
}

struct RecordingDetailView: View {
    let library: RecordingLibrary
    let item: RecordingItem
    var onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    @State private var inspection: FileInspection?
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var status: String?
    @State private var exportTitle: String?
    @State private var progress: Double = 0
    /// Last copy exported from this screen, shown right away so the result is visible.
    @State private var copy: (url: URL, title: String)?
    @State private var showingCopy = false

    private var shownURL: URL { showingCopy ? copy?.url ?? item.url : item.url }
    private var exporting: Bool { exportTitle != nil }

    private func play(_ url: URL) {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        Task { inspection = await RecordingLibrary.inspect(url) }
    }

    private func didExport(_ url: URL, title: String, message: String) {
        ThumbnailView.invalidate(url)
        copy = (url, title)
        showingCopy = true
        play(url)
        player.play()
        status = message
        onChange()
    }

    private var progressHandler: @Sendable (Double) -> Void {
        { value in Task { @MainActor in progress = value } }
    }

    private func export(_ look: VideoLook) {
        exportTitle = "Aplicando \(look.title)"
        progress = 0
        status = nil
        Task {
            do {
                let url = try await library.exportCopy(of: item, look: look, progress: progressHandler)
                didExport(url, title: look.title, message: "Cópia com \(look.title) criada. O original foi mantido.")
            } catch {
                status = "Falha ao exportar: \(error.localizedDescription)"
            }
            exportTitle = nil
        }
    }

    private func exportBeat(_ effect: BeatEffect) {
        exportTitle = "Analisando o ritmo e aplicando \(effect.title)"
        progress = 0
        status = nil
        Task {
            do {
                let result = try await library.exportBeatEdit(of: item, effect: effect, progress: progressHandler)
                let bpm = result.beats.bpm.map { " · \(Int($0.rounded())) BPM" } ?? ""
                didExport(result.url, title: effect.title,
                          message: "Cópia no ritmo criada (\(result.beats.beats.count) batidas\(bpm)). O original foi mantido.")
            } catch {
                status = "Falha: \(error.localizedDescription)"
            }
            exportTitle = nil
        }
    }

    var body: some View {
        List {
            Section {
                VideoPlayer(player: player).frame(height: 260).listRowInsets(EdgeInsets())
                if let copy {
                    Picker("Versão", selection: $showingCopy) {
                        Text("Original").tag(false)
                        Text(copy.title).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: showingCopy) { _, _ in play(shownURL); player.play() }
                }
            }
            if let exportTitle {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(exportTitle)… \(Int(progress * 100))%").font(.subheadline.weight(.semibold))
                        ProgressView(value: progress)
                        Text("Pode demorar em vídeos longos ou em 4K. O original não é alterado.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            if let status { Section { Text(status).foregroundStyle(Theme.accent) } }
            Section {
                ShareLink(item: shownURL) { Label(showingCopy ? "Compartilhar cópia" : "Compartilhar", systemImage: "square.and.arrow.up") }
                Button(showingCopy ? "Salvar cópia no Fotos" : "Salvar no Fotos", systemImage: "photo.badge.plus") {
                    let url = shownURL
                    Task {
                        do { try await RecordingLibrary.saveToPhotos(url); status = "Salvo no Fotos." }
                        catch { status = error.localizedDescription }
                    }
                }
                Menu {
                    ForEach(VideoLook.allCases.filter { $0 != .none }) { look in
                        Button(look.title) { export(look) }
                    }
                } label: {
                    Label("Exportar cópia com filtro", systemImage: "camera.filters")
                }
                .disabled(exporting)
                Menu {
                    ForEach(BeatEffect.allCases.filter { $0 != .off }) { effect in
                        Button(effect.title, systemImage: effect.systemImage) { exportBeat(effect) }
                    }
                } label: {
                    Label("Editar no ritmo da música", systemImage: "metronome")
                }
                .disabled(exporting)
            }
            Section(showingCopy ? "Arquivo da cópia (medido)" : "Arquivo (medido)") {
                if let i = inspection {
                    LabeledContent("Codec", value: i.codec)
                    LabeledContent("Dimensões", value: "\(Int(i.dimensions.width))×\(Int(i.dimensions.height))")
                    LabeledContent("FPS nominal", value: String(format: "%.3f", i.nominalFrameRate))
                    LabeledContent("Duração", value: String(format: "%.1f s", i.duration))
                    LabeledContent("Áudio", value: "\(i.audioTracks) trilha(s), \(i.audioChannels) canal(is)")
                    if let t = i.transferFunction { LabeledContent("Transferência", value: t) }
                    if let p = i.colorPrimaries { LabeledContent("Primárias", value: p) }
                    LabeledContent("Reproduzível", value: i.isPlayable ? "Sim" : "Não")
                } else {
                    ProgressView()
                }
            }
            if let m = item.metadata {
                Section("Captura") {
                    if let edit = m.editLabel { LabeledContent("Edição aplicada", value: edit) }
                    if !m.camera.isEmpty { LabeledContent("Câmera", value: m.camera) }
                    if !m.colorProfile.isEmpty { LabeledContent("Perfil", value: m.colorProfile) }
                    if !m.stabilization.isEmpty { LabeledContent("Estabilização", value: m.stabilization) }
                    if let iso = m.iso { LabeledContent("ISO", value: "\(Int(iso))") }
                    if let s = m.shutter { LabeledContent("Shutter", value: s) }
                    if let k = m.whiteBalanceKelvin { LabeledContent("WB", value: "\(Int(k))K") }
                    if let f = m.equivalentFocalLength { LabeledContent("Focal", value: "≈\(Int(f)) mm") }
                    if !m.deviceModel.isEmpty { LabeledContent("Dispositivo", value: "\(m.deviceModel) · iOS \(m.systemVersion)") }
                    if let beats = m.beatMap {
                        LabeledContent(beats.source == .live ? "Batidas (ao vivo)" : "Batidas",
                                       value: "\(beats.beats.count)\(beats.bpm.map { " · \(Int($0.rounded())) BPM" } ?? "")")
                    }
                }
            }
            Section {
                LabeledContent("Tamanho do original", value: StorageEstimator.format(bytes: Double(item.fileSize)))
                Button("Renomear", systemImage: "pencil") { newName = item.name; renaming = true }
                    .disabled(exporting)
                Button("Excluir", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    .disabled(exporting)
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { if player.currentItem == nil { play(shownURL) } }
        .onDisappear { player.pause() }
        .alert("Renomear", isPresented: $renaming) {
            TextField("Nome", text: $newName)
            Button("Salvar") {
                do { _ = try library.rename(item, to: newName); onChange(); dismiss() } catch { status = error.localizedDescription }
            }
            Button("Cancelar", role: .cancel) {}
        }
        .confirmationDialog("Excluir este vídeo? Esta ação não pode ser desfeita.", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Excluir", role: .destructive) {
                do { try library.delete(item); onChange(); dismiss() } catch { status = error.localizedDescription }
            }
        }
    }
}
