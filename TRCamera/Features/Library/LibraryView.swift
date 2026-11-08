import AVKit
import SwiftUI

struct LibraryView: View {
    let library: RecordingLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var items: [RecordingItem] = []

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 6)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if items.isEmpty {
                    MessageStateView(icon: "film.stack", title: "Nenhum vídeo ainda", message: "Suas gravações aparecem aqui e também no app Arquivos › Luminous Cam.")
                        .padding(.top, 60)
                }
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            ThumbnailView(url: item.url)
                                .aspectRatio(1, contentMode: .fill)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(alignment: .bottomLeading) {
                                    Text(item.metadata.map { "\($0.resolution.split(separator: "x").last ?? "")p\(FrameRateFormatter.string($0.frameRate))" } ?? "")
                                        .font(.system(size: 9, weight: .bold)).padding(4)
                                        .background(Capsule().fill(.black.opacity(0.6))).padding(4)
                                }
                        }
                    }
                }
                .padding(6)
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

struct RecordingDetailView: View {
    let library: RecordingLibrary
    let item: RecordingItem
    var onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var inspection: FileInspection?
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var status: String?
    @State private var exporting = false

    private func export(_ look: VideoLook) {
        exporting = true
        status = nil
        Task {
            do {
                let url = try await library.exportCopy(of: item, look: look)
                status = "Cópia \"\(url.deletingPathExtension().lastPathComponent)\" criada. O original foi mantido."
                onChange()
            } catch {
                status = "Falha ao exportar: \(error.localizedDescription)"
            }
            exporting = false
        }
    }

    private func exportBeat(_ effect: BeatEffect) {
        exporting = true
        status = "Analisando o áudio…"
        Task {
            do {
                let result = try await library.exportBeatEdit(of: item, effect: effect)
                let bpm = result.beats.bpm.map { " · \(Int($0.rounded())) BPM" } ?? ""
                status = "Cópia no ritmo criada (\(result.beats.beats.count) batidas\(bpm)). O original foi mantido."
                onChange()
            } catch {
                status = "Falha: \(error.localizedDescription)"
            }
            exporting = false
        }
    }

    var body: some View {
        List {
            Section {
                VideoPlayer(player: player).frame(height: 240).listRowInsets(EdgeInsets())
            }
            if let status { Section { Text(status).foregroundStyle(Theme.accent) } }
            Section("Arquivo (medido)") {
                LabeledContent("Tamanho", value: StorageEstimator.format(bytes: Double(item.fileSize)))
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
                    LabeledContent("Câmera", value: m.camera)
                    LabeledContent("Perfil", value: m.colorProfile)
                    LabeledContent("Estabilização", value: m.stabilization)
                    if let iso = m.iso { LabeledContent("ISO", value: "\(Int(iso))") }
                    if let s = m.shutter { LabeledContent("Shutter", value: s) }
                    if let k = m.whiteBalanceKelvin { LabeledContent("WB", value: "\(Int(k))K") }
                    if let f = m.equivalentFocalLength { LabeledContent("Focal", value: "≈\(Int(f)) mm") }
                    LabeledContent("Dispositivo", value: "\(m.deviceModel) · iOS \(m.systemVersion)")
                    if let beats = m.beatMap {
                        LabeledContent(beats.source == .live ? "Batidas (ao vivo)" : "Batidas",
                                       value: "\(beats.beats.count)\(beats.bpm.map { " · \(Int($0.rounded())) BPM" } ?? "")")
                    }
                    if let effect = m.beatEffect { LabeledContent("Efeito no ritmo", value: effect) }
                }
            }
            Section {
                ShareLink(item: item.url) { Label("Compartilhar", systemImage: "square.and.arrow.up") }
                Button("Salvar no Fotos", systemImage: "photo.badge.plus") {
                    Task {
                        do { try await RecordingLibrary.saveToPhotos(item.url); status = "Salvo no Fotos." }
                        catch { status = error.localizedDescription }
                    }
                }
                Menu {
                    ForEach(VideoLook.allCases.filter { $0 != .none }) { look in
                        Button(look.title) { export(look) }
                    }
                } label: {
                    if exporting {
                        HStack { ProgressView(); Text("Exportando…") }
                    } else {
                        Label("Exportar cópia com filtro", systemImage: "camera.filters")
                    }
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
                Button("Renomear", systemImage: "pencil") { newName = item.name; renaming = true }
                Button("Excluir", systemImage: "trash", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            player = AVPlayer(url: item.url)
            inspection = await RecordingLibrary.inspect(item.url)
        }
        .onDisappear { player?.pause() }
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
