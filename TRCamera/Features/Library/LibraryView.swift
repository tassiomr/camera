import AVKit
import SwiftUI
import TRDesignSystem

struct LibraryView: View {
    let library: RecordingLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.trTheme) private var theme
    @State private var items: [RecordingItem] = []

    var body: some View {
        let gap = theme.spacing.xxs
        NavigationStack {
            ScrollView {
                if items.isEmpty {
                    TRStateView(.empty, title: "Nenhum vídeo ainda", message: "Suas gravações aparecem aqui e também no app Arquivos › Luminous Cam.",
                                icon: .filmStack)
                        .padding(.top, theme.spacing.xxl)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: gap)], spacing: gap) {
                    ForEach(items) { item in
                        NavigationLink(value: item) { LibraryCell(item: item) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(gap)
            }
            .background(theme.colors.background.primary)
            .navigationTitle("Biblioteca")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
            .navigationDestination(for: RecordingItem.self) { item in
                RecordingDetailView(library: library, item: item) { items = library.items() }
            }
            .onAppear { items = library.items() }
        }
    }
}

/// Square cell: the size comes from the grid column, never from the image.
private struct LibraryCell: View {
    @Environment(\.trTheme) private var theme
    let item: RecordingItem

    var body: some View {
        let shape = RoundedRectangle.tr(theme.shape.control)
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { ThumbnailView(url: item.url) }
            .clipShape(shape)
            .overlay(alignment: .topLeading) {
                if let edit = item.metadata?.editLabel {
                    TRBadge(verbatim: edit, tone: .accent, emphasis: .solid, icon: item.metadata?.beatEffect != nil ? .beat : .lookFilter)
                        .lineLimit(1)
                        .padding(theme.spacing.xxs)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let format = formatLabel {
                    // Over a video frame: badge colors stay dark in every appearance.
                    TRBadge(verbatim: format, tone: .neutral, emphasis: .solid)
                        .environment(\.colorScheme, .dark)
                        .padding(theme.spacing.xxs)
                }
            }
            .contentShape(shape)
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
    @Environment(\.trTheme) private var theme
    @State private var player = AVPlayer()
    @State private var inspection: FileInspection?
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var status: Status?
    @State private var exportTitle: String?
    @State private var progress: Double = 0
    /// Last copy exported from this screen, shown right away so the result is visible.
    @State private var copy: (url: URL, title: String)?
    @State private var showingCopy = false

    struct Status: Equatable {
        var message: String
        var tone: TRTone
    }

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
        status = Status(message: message, tone: .success)
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
                status = Status(message: "Falha ao exportar: \(error.localizedDescription)", tone: .error)
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
                status = Status(message: "Falha: \(error.localizedDescription)", tone: .error)
            }
            exportTitle = nil
        }
    }

    var body: some View {
        List {
            Group { sections }.themedListRows()
        }
        .themedGroupedList()
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { if player.currentItem == nil { play(shownURL) } }
        .onDisappear { player.pause() }
        .alert("Renomear", isPresented: $renaming) {
            TextField("Nome", text: $newName)
            Button("Salvar") {
                do { _ = try library.rename(item, to: newName); onChange(); dismiss() } catch { status = Status(message: error.localizedDescription, tone: .error) }
            }
            Button("Cancelar", role: .cancel) {}
        }
        .confirmationDialog("Excluir este vídeo? Esta ação não pode ser desfeita.", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Excluir", role: .destructive) {
                do { try library.delete(item); onChange(); dismiss() } catch { status = Status(message: error.localizedDescription, tone: .error) }
            }
        }
    }

    @ViewBuilder private var sections: some View {
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
                VStack(alignment: .leading, spacing: theme.spacing.stack.regular) {
                    Text("\(exportTitle)… \(Int(progress * 100))%")
                        .trTextStyle(.bodyEmphasized).monospacedDigit()
                        .foregroundStyle(theme.colors.foreground.primary)
                    ProgressView(value: progress).progressViewStyle(.trLinear)
                    Text("Pode demorar em vídeos longos ou em 4K. O original não é alterado.")
                        .trTextStyle(.footnote).foregroundStyle(theme.colors.foreground.secondary)
                }
                .padding(.vertical, theme.spacing.xxs)
            }
        }
        if let status {
            Section {
                TRBanner(LocalizedStringKey(status.message), tone: status.tone)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
        Section {
            ShareLink(item: shownURL) { Label(showingCopy ? "Compartilhar cópia" : "Compartilhar", systemImage: "square.and.arrow.up") }
            Button(showingCopy ? "Salvar cópia no Fotos" : "Salvar no Fotos", systemImage: "photo.badge.plus") {
                let url = shownURL
                Task {
                    do { try await RecordingLibrary.saveToPhotos(url); status = Status(message: "Salvo no Fotos.", tone: .success) }
                    catch { status = Status(message: error.localizedDescription, tone: .error) }
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
                TRKeyValueRow("Codec", value: i.codec)
                TRKeyValueRow("Dimensões", value: "\(Int(i.dimensions.width))×\(Int(i.dimensions.height))", isNumeric: true)
                TRKeyValueRow("FPS nominal", value: String(format: "%.3f", i.nominalFrameRate), isNumeric: true)
                TRKeyValueRow("Duração", value: String(format: "%.1f s", i.duration), isNumeric: true)
                TRKeyValueRow("Áudio", value: "\(i.audioTracks) trilha(s), \(i.audioChannels) canal(is)")
                if let t = i.transferFunction { TRKeyValueRow("Transferência", value: t) }
                if let p = i.colorPrimaries { TRKeyValueRow("Primárias", value: p) }
                TRKeyValueRow("Reproduzível", value: i.isPlayable ? "Sim" : "Não")
            } else {
                ProgressView()
            }
        }
        if let m = item.metadata {
            Section("Captura") {
                if let edit = m.editLabel { TRKeyValueRow("Edição aplicada", value: edit) }
                if !m.camera.isEmpty { TRKeyValueRow("Câmera", value: m.camera) }
                if !m.colorProfile.isEmpty { TRKeyValueRow("Perfil", value: m.colorProfile) }
                if !m.stabilization.isEmpty { TRKeyValueRow("Estabilização", value: m.stabilization) }
                if let iso = m.iso { TRKeyValueRow("ISO", value: "\(Int(iso))", isNumeric: true) }
                if let s = m.shutter { TRKeyValueRow("Shutter", value: s, isNumeric: true) }
                if let k = m.whiteBalanceKelvin { TRKeyValueRow("WB", value: "\(Int(k))K", isNumeric: true) }
                if let f = m.equivalentFocalLength { TRKeyValueRow("Focal", value: "≈\(Int(f)) mm", isNumeric: true) }
                if !m.deviceModel.isEmpty { TRKeyValueRow("Dispositivo", value: "\(m.deviceModel) · iOS \(m.systemVersion)") }
                if let beats = m.beatMap {
                    TRKeyValueRow(beats.source == .live ? "Batidas (ao vivo)" : "Batidas",
                                   value: "\(beats.beats.count)\(beats.bpm.map { " · \(Int($0.rounded())) BPM" } ?? "")")
                }
            }
        }
        Section {
            TRKeyValueRow("Tamanho do original", value: StorageEstimator.format(bytes: Double(item.fileSize)), isNumeric: true)
            Button("Renomear", systemImage: "pencil") { newName = item.name; renaming = true }
                .disabled(exporting)
            Button("Excluir", systemImage: "trash", role: .destructive) { confirmDelete = true }
                .disabled(exporting)
        }
    }
}
