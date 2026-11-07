import Foundation

/// Deterministic, explainable recommendations. No AI: each rule is a plain
/// technical decision that is covered by unit tests.
struct RecordingConfigurationAdvisor {
    enum Goal: String, CaseIterable, Identifiable, Codable {
        case automatic, cinematic, creatorVertical, lowLight, highMotion, concert, maximumQuality, editingLog

        var id: String { rawValue }

        var title: String {
            switch self {
            case .automatic: "Automático"
            case .cinematic: "Cinema"
            case .creatorVertical: "Creator / Vertical"
            case .lowLight: "Pouca luz"
            case .highMotion: "Alto movimento"
            case .concert: "Show / Palco"
            case .maximumQuality: "Qualidade máxima"
            case .editingLog: "Log profissional"
            }
        }

        var question: String {
            switch self {
            case .automatic: "Qual a configuração mais equilibrada?"
            case .cinematic: "Qual a melhor configuração cinematográfica?"
            case .creatorVertical: "Qual a melhor configuração para conteúdo vertical?"
            case .lowLight: "Qual a melhor configuração para gravar à noite?"
            case .highMotion: "Qual a melhor configuração para esportes e ação?"
            case .concert: "Qual a melhor configuração para gravar um show?"
            case .maximumQuality: "Qual a melhor qualidade possível neste iPhone?"
            case .editingLog: "Qual a melhor configuração para preservar qualidade na edição?"
            }
        }
    }

    struct Context {
        var camera: CameraDescriptor
        var freeBytes: Int64?
        var thermalElevated: Bool
        /// Codecs reported by the movie output for the current format; nil when unknown.
        var knownCodecs: [VideoCodec]?
    }

    struct Recommendation {
        var goal: Goal
        var configuration: CaptureConfiguration
        var shutterAngle: Double?
        var reasons: [String]
        var limitations: [String]
        var available: Bool
    }

    func recommend(_ goal: Goal, context: Context) -> Recommendation {
        let resolver = FormatResolver(camera: context.camera)
        let resolutions = resolver.resolutions()
        let uhd = resolutions.first { $0.height == 2160 } ?? resolutions.first ?? VideoResolution(width: 1920, height: 1080)
        let hd = resolutions.first { $0.height == 1080 } ?? uhd
        var reasons: [String] = []
        var limitations: [String] = []
        var available = true

        func rate(_ preferred: [Double], at res: VideoResolution) -> Double {
            let rates = resolver.frameRates(for: res)
            return preferred.first { p in rates.contains { abs($0 - p) < 0.01 } } ?? rates.max() ?? 30
        }

        var config = CaptureConfiguration.fallback(cameraID: context.camera.id)
        var angle: Double? = nil

        switch goal {
        case .automatic:
            config.resolution = uhd
            config.frameRate = rate([30], at: uhd)
            config.codec = .hevc
            config.stabilization = .cinematicExtended
            reasons.append("4K 30 fps em HEVC equilibra nitidez, tamanho de arquivo e aquecimento.")
        case .cinematic:
            config.resolution = uhd
            config.frameRate = rate([24, 25, 30], at: uhd)
            config.codec = .hevc
            config.colorProfile = .rec709
            config.stabilization = .cinematicExtended
            angle = 180
            reasons.append("24 fps com shutter 180° (1/48) gera o motion blur natural do cinema.")
            reasons.append("Estabilização cinematográfica estendida suaviza movimentos de câmera na mão.")
        case .creatorVertical:
            config.resolution = uhd
            config.frameRate = rate([30], at: uhd)
            config.codec = .hevc
            config.stabilization = .cinematicExtended
            reasons.append("Grave em 4K e enquadre com o guia 9:16 — sobra resolução para recortar o vertical em 1080×1920.")
        case .lowLight:
            config.resolution = uhd
            config.frameRate = rate([24, 25, 30], at: uhd)
            config.codec = .hevc
            config.stabilization = .standard
            angle = 360
            reasons.append("Frame rate baixo permite exposições mais longas; shutter 360° captura o dobro de luz que 180°.")
            reasons.append("Prefira a lente principal (Wide): normalmente tem o maior sensor e a maior abertura.")
            limitations.append("Shutter 360° aumenta o motion blur.")
        case .highMotion:
            config.resolution = uhd
            config.frameRate = rate([60, 50, 30], at: uhd)
            if resolver.frameRates(for: hd).contains(where: { $0 >= 119 }), config.frameRate < 60 {
                config.resolution = hd
                config.frameRate = 120
            }
            config.codec = .hevc
            config.stabilization = .standard
            angle = 180
            reasons.append("Frame rate alto congela o movimento e permite câmera lenta na edição.")
            limitations.append("Formatos de alta velocidade podem usar binning (menos detalhe) e limitar a estabilização.")
        case .concert:
            config.resolution = uhd
            config.frameRate = rate([30, 25], at: uhd)
            config.codec = .hevc
            config.colorProfile = .rec709
            config.stabilization = .cinematicExtended
            angle = 180
            reasons.append("Use AE Lock ou ISO manual: luzes de palco enganam o automático.")
            reasons.append("Ative a zebra a 95% para não estourar os rostos sob refletores.")
            reasons.append("Diminua o ganho de áudio se o medidor de pico ficar vermelho.")
        case .maximumQuality:
            config.resolution = resolutions.first ?? uhd
            config.frameRate = rate([30, 25, 24], at: config.resolution)
            config.codec = .proRes422HQ
            let profiles = resolver.colorProfiles(for: config.resolution, fps: config.frameRate)
            config.colorProfile = profiles.contains(.hlg) ? .hlg : .rec709
            config.stabilization = .standard
            reasons.append("Maior resolução nativa sem upscale, menor compressão disponível.")
        case .editingLog:
            config.resolution = uhd
            config.frameRate = rate([24, 25, 30], at: uhd)
            config.codec = .proRes422HQ
            config.colorProfile = .appleLog2
            config.stabilization = .standard
            angle = 180
            let profiles = resolver.colorProfiles(for: config.resolution, fps: config.frameRate)
            if !profiles.contains(where: \.isLog) {
                available = false
                limitations.append("Este iPhone não expõe Apple Log para apps de terceiros nesta lente.")
            } else {
                reasons.append("Log preserva a faixa dinâmica do sensor para correção de cor. Monitore com a LUT Log→709.")
            }
        }

        // Resolve against hardware; record every forced change as a limitation.
        if let resolved = resolver.resolve(config, availableCodecs: context.knownCodecs) {
            config = resolved.configuration
            limitations.append(contentsOf: resolved.adjustments)
        } else {
            available = false
        }

        if config.codec.isProRes && context.knownCodecs == nil {
            limitations.append("A disponibilidade de ProRes é confirmada pela câmera após aplicar o formato; se não houver, o app usa HEVC.")
        }
        if let free = context.freeBytes {
            let minutes = StorageEstimator.minutesRemaining(freeBytes: free, config: config)
            if minutes < 10 {
                limitations.append("Pouco espaço: cerca de \(StorageEstimator.format(minutes: minutes)) nesta configuração.")
            }
        }
        if context.thermalElevated && (config.codec.isProRes || config.frameRate >= 60) {
            limitations.append("O iPhone está aquecido; esta configuração exige mais processamento.")
        }
        return Recommendation(goal: goal, configuration: config, shutterAngle: angle, reasons: reasons, limitations: limitations, available: available)
    }
}
