# Arquitetura — Luminous Cam (`com.trmedia.camera`)

```
TRCamera/
├── App/                     TRCameraApp (injeta o CameraViewModel)
├── Domain/                  Lógica pura, sem AVFoundation → 100% testável
│   ├── CaptureModels        CameraDescriptor, FormatDescriptor, ColorProfile, VideoCodec, StabilizationMode, CaptureConfiguration
│   ├── FormatResolver       Opções válidas + resolução de dependências (resolução → fps → perfil → formato → estabilização → codec)
│   ├── ExposureMath         Shutter angle ↔ tempo, passos de ISO/shutter/Kelvin, EV
│   ├── StorageEstimator     Bytes/min por codec, minutos restantes
│   ├── RecordingAdvisor     RecordingConfigurationAdvisor (regras determinísticas e explicadas)
│   └── Presets              MonitoringSettings, CapturePreset, PresetValidator, PresetStore (JSON)
├── Core/
│   ├── Capabilities/        CameraCapabilityEngine: AVCaptureDevice → DeviceCapabilities
│   ├── Capture/             ProfessionalCaptureEngine: sessão, formatos, exposição, WB, foco, zoom, abertura, gravação, interrupções, telemetria
│   ├── Processing/          MonitoringProcessor (Core Image/Metal), CubeLUT, AppleLogCurve, LUTLibrary
│   ├── Storage/             RecordingLibrary: destino interno/SSD, metadados, sidecar JSON, inspeção do arquivo, Fotos
│   ├── Audio/               AudioRouteManager: AVAudioSession, entrada, ganho
│   └── Diagnostics/         Logger, ThermalMonitor, LevelMonitor
├── Features/
│   ├── Camera/              CameraViewModel (@Observable, @MainActor) + CameraScreen + Components
│   ├── Settings/            SettingsSheet, PresetsSheet/AdvisorDetail, CapabilityReportView
│   └── Library/             LibraryView, RecordingDetailView
├── DesignSystem/            Theme, ParameterCard, AutoPill, ChipButton, RecordButton, StepDial
└── Resources/               Assets (AppIcon, AccentColor)
TRCameraTests/               29 testes de unidade (domínio, LUT, scopes)
```

## Decisões

| Decisão | Motivo |
|---|---|
| Fluxo **View → ViewModel → Engine → AVFoundation**; engine publica `EngineEvent` na main queue | UI desacoplada da captura (regra 12); engine testável isoladamente |
| Uma `DispatchQueue` serial para sessão/dispositivo | Padrão recomendado pela Apple; `startRunning` é bloqueante e não pode rodar na main |
| Domínio sem AVFoundation (`FormatDescriptor` é um snapshot) | Permite testar compatibilidade sem iPhone |
| `AVCaptureMovieFileOutput` para gravação | Mais robusto: finaliza o arquivo sozinho em interrupções, suporta ProRes/Log/HLG e metadados. Custo: sem bitrate manual nem LUT gravada → `AVAssetWriter` na Fase 4 |
| Preview via `AVCaptureVideoPreviewLayer` (`.resizeAspect`) | Latência mínima e enquadramento real |
| Monitoramento num `CAMetalLayer` **sobreposto** só quando necessário | Zebra/peaking/LUT exigem processar o frame; quando desligados o caminho de baixa latência é usado e a saída de dados é desativada (economia de bateria) |
| Filtros nativos do Core Image (`CIColorCube`, `CIColorMap`, `CIEdges`, `CIColorThreshold`, `CIStripesGenerator`) | Rodam na GPU sem kernels customizados; imagem reduzida à resolução da tela antes dos filtros |
| Scopes a 10 Hz em imagem 192×108 | Custo desprezível, sem bloquear a captura |
| Sinal sem gerência de cor (`NSNull` colorspace) | Zebra/false color leem valores de código reais do arquivo |
| Prioridade de exposição: nativa no iOS 27, **emulada** (malha fechada em `exposureTargetOffset`) no 17–26 | Funciona em todos, sem fingir que é nativo (badge “EMUL”) |
| `automaticallyConfiguresApplicationAudioSession = false` | Respeitar a entrada escolhida (USB, lapela) e o ganho |
| `automaticallyConfiguresCaptureDeviceForWideColor = false` | O app controla `activeColorSpace` (Log/HLG) explicitamente |
| Swift 5 language mode, `@preconcurrency import AVFoundation` | AVFoundation ainda não é `Sendable`; Swift 6 estrito geraria ruído sem ganho real de segurança aqui |
| Projeto com *File System Synchronized Groups* (Xcode 16+) | Novos arquivos entram no target sem editar o `.pbxproj` |

## Fluxo de troca de configuração

1. Usuário escolhe algo (ex.: 4K 60 + Apple Log).
2. `CameraViewModel.update` → `engine.apply`.
3. `FormatResolver.resolve` repara: Log não existe em 4K60 → HLG; registra o motivo.
4. Engine aplica formato, `activeColorSpace`, duração de frame; **sonda codecs** do formato ativo; resolve o codec de novo.
5. Evento `.configured` volta com a configuração real e a lista de ajustes → banner explica ao usuário.

## Segurança da gravação

- Checa espaço antes (≥ 1 min estimado + 300 MB); `minFreeDiskSpaceLimit` = 300 MB.
- `AVErrorRecordingSuccessfullyFinishedKey` diferencia “arquivo válido com aviso” de falha real.
- Interrupções, erros de runtime (`mediaServicesWereReset` → reinicia sessão), pressão do sistema e térmica são todos apresentados ao usuário.
- Troca de formato bloqueada durante gravação; tela não apaga gravando.
- Pressão térmica **nunca** reduz a qualidade em silêncio: só pausa ferramentas auxiliares e avisa.
