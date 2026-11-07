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
                    MessageStateView(icon: "film.stack", title: "Nenhum vídeo ainda", message: "Suas gravações aparecem aqui e também no app Arquivos › TR Camera.")
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
