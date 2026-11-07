# TR Camera — Diretriz do projeto

Bundle ID: **`com.trmedia.camera`** · Nome exibido: **TR Camera** · iOS mínimo **17.0** · iPhone · SwiftUI + AVFoundation + Core Image/Metal
Estado em 07/11/2026: **Fases 1–3 completas, Fase 4 parcial, site pronto.** Compila sem warnings para iPhone físico; **32/32 testes passando** no simulador.

---

## 1. Como abrir e rodar

```bash
open TRCamera.xcodeproj
```
1. Em *Signing & Capabilities*, escolha seu Team (o bundle `com.trmedia.camera` já está configurado).
2. Rode em um **iPhone físico** (o simulador não tem câmera; ele só roda os testes).
3. Testes: `⌘U` ou
```bash
xcodebuild -project TRCamera.xcodeproj -scheme TRCamera -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Arquivos novos colocados em `TRCamera/` entram no target automaticamente (pastas sincronizadas do Xcode 16+).

---

## 2. O que foi feito — por funcionalidade

### F1. Pesquisa técnica + matriz → `docs/PESQUISA_E_MATRIZ.md`
- Feita direto nos **headers do SDK iOS 27.2** (a fonte mais confiável sobre o que é API pública).
- Novidades encontradas e já usadas: **Apple Log 2** (iOS 26), **ProRes 4444 XQ** (18), **ProRes RAW** (26, só detectado), **modos de prioridade nativos** e **abertura variável** (27), focal 35 mm nativa (26), `AVExternalStorageDevice` (17).
- A matriz separa hardware × iOS × terceiros × só o app Câmera da Apple × processamento próprio × inviável. Inclui a análise de concorrentes e os riscos.

### F2. CameraCapabilityEngine → `Core/Capabilities/`
- Descobre lentes (UW/W/Tele/virtual/frontal/externa) e **todos os formatos** de cada uma: resolução, faixas de fps, bit depth, perfis de cor, HDR, estabilização, ISO, exposição, FOV, binning, zoom, multicam e abertura.
- **Nenhuma tabela de modelos é usada para decidir recursos.** O identificador do modelo é só informativo.
- Tela **“Perfil do iPhone”** (ícone de CPU) mostra tudo e exporta um JSON. Use isso para montar a matriz real em cada aparelho.

### F3. Resolução de compatibilidade → `Domain/FormatResolver.swift`
- Os pickers só listam combinações reais. Ao trocar uma opção, as dependentes são reparadas em cadeia (resolução → fps → perfil → formato → estabilização → codec), e um banner explica o que mudou.
- Codecs são **sondados em runtime** no formato ativo (`availableVideoCodecTypes`). ProRes só aparece quando existe de fato.

### F4. ProfessionalCaptureEngine → `Core/Capture/`
- Fila serial de sessão. A UI não toca em AVFoundation.
- Preview de baixa latência (`AVCaptureVideoPreviewLayer`, enquadramento real) e rotação correta via `RotationCoordinator`.
- Exposição: ISO/shutter manual; prioridade de shutter ou ISO **nativa no iOS 27** e **emulada no 17–26** (badge “EMUL”). EV, AE Lock.
- WB em Kelvin + tint, com presets de luz. Foco: AF, toque para focar, manual, e **rack focus A→B** suave.
- Zoom: botões nos pontos ópticos reais (`switchOver…`), pinça, rampa com velocidade, aviso “DIGITAL” e focal equivalente.
- Abertura: ajustável só em hardware com íris (iOS 27); nos demais aparece como **“FIXA”**, somente leitura.
- Telemetria a 10 Hz (ISO, shutter, Kelvin, foco, zoom, abertura, áudio, tempo e tamanho gravados).

### F5. Gravação segura e armazenamento → `Core/Storage/`
- `AVCaptureMovieFileOutput`, com checagem de espaço antes de gravar e limite mínimo de disco.
- Identifica arquivo **válido com aviso** versus falha real.
- Interrupções, erros de runtime (reinício automático), pressão do sistema e térmica são todos avisados. Não dá para trocar formato gravando, e a tela não apaga durante a gravação.
- **SSD USB-C** pela API oficial `AVExternalStorageDevice`.
- Metadados QuickTime (Make/Model/Software/data + JSON técnico) e sidecar `.json`, **sem localização**.
- Biblioteca: player, **inspeção do arquivo real** (codec, dimensões, fps, áudio, transferência, primárias), renomear, excluir (com confirmação), compartilhar e salvar no Fotos (somente adição). Arquivos visíveis no app Arquivos.

### F6. Monitoramento profissional → `Core/Processing/` + `docs/MONITORAMENTO.md`
- Zebra (70–100%), focus peaking (cor e intensidade), false color (escala documentada), histograma RGB+luma, waveform, LUT `.cube` (import + validação), **LUT técnica Apple Log→709** gerada pela curva oficial da Apple, e desqueeze 1.33–2×.
- Tudo com filtros nativos do Core Image na GPU. A camada Metal só é ligada quando necessária; desligada, a saída de dados também desliga (economia de bateria).
- Em pressão térmica, as ferramentas pausam sozinhas e o app avisa. **A qualidade da gravação nunca é reduzida em silêncio.**
- Guias: terços, centro, safe areas 90/80%, aspect (16:9, 9:16, 1:1, 4:3, 4:5, 2.39) e nível do horizonte.

### F7. Áudio → `Core/Audio/`
- Escolha de entrada (interno/USB/headset), ganho quando o iOS permite (avisa quando não) e medidores de média/pico por canal com cor de clipping.

### F8. Advisor + presets → `Domain/RecordingAdvisor.swift`, `Domain/Presets.swift`
- `RecordingConfigurationAdvisor` determinístico com 8 objetivos (Auto, Cinema, Creator/Vertical, Pouca luz, Alto movimento, Show, Qualidade máxima, Log). Cada um mostra “Por quê” e as “Limitações neste iPhone”.
- Presets inteligentes gerados a partir do advisor, mais presets do usuário salvos em JSON. Todo preset é **validado** antes de aplicar, com lista de substituições.

### F9. Interface → `Features/`, `DesignSystem/`
- Visual escuro inspirado na referência: cards com pílula AUTO e valores grandes, acento menta `#3EE3C1`, botão de gravar luminoso e dial de ticks com háptico.
- **Simple** e **Pro**. Layouts próprios para **retrato** (cards em linha, barra inferior) e **paisagem** (trilho de lentes, preview central, coluna de cards).
- Estados: inicialização, câmera negada (com botão Ajustes), sem câmera, microfone negado (grava sem áudio e avisa), banners de erro/aviso.

### F10. Ícone → `Resources/Assets.xcassets/AppIcon.appiconset`
- Na estética do Luminous: fundo grafite, **crescente luminoso menta→azul-violeta** como anel da lente, vidro escuro com anéis e o **ponto de luz** no topo. Inclui variante *tinted* do iOS.
- Gerador reproduzível em `tools/make_icon.swift` (`swiftc -O tools/make_icon.swift -o mk && ./mk AppIcon.png`).

### F11. Site (Vercel) → `site/`
- `index.html` (landing), `privacidade.html`, `termos.html`, `suporte.html`, `styles.css`. O `vercel.json` fica na **raiz do repositório** e publica a pasta `site` (URLs limpas: `/privacidade`, `/termos`, `/suporte`; redirects de `/privacy`, `/terms`, `/support`; headers de segurança).
- **Antes de publicar:** troque `CONTATO_EMAIL` (aparece em 3 arquivos) pelo e-mail de contato real e confirme o nome da empresa (“TR Media”).
- Deploy:
```bash
npx vercel --prod
```
  Ou importe o repositório pela interface da Vercel **sem alterar nada** (Root Directory `./`): o `vercel.json` da raiz já aponta a saída para `site/`.
- App Store Connect: *Privacy Policy URL* = `https://SEU-DOMINIO/privacidade`, *Support URL* = `/suporte`, rótulo de privacidade = **“Data Not Collected”**.

### F12. Filtros criativos (looks) → `Core/Processing/VideoLook.swift`
- 12 looks com filtros nativos do Core Image: Original, Vivid, Teal & Orange, Warm Film, Cool, Fade, Bleach, Vintage, Mono, Noir, Chrome e Dream.
- **Ao vivo:** o chip **FILTRO** na barra superior abre uma faixa de looks sobre o preview. O filtro aparece só na visualização, e o arquivo é gravado limpo. O look usado fica registrado nos metadados como "somente preview".
- **No vídeo:** na Biblioteca, **"Exportar cópia com filtro"** gera um novo `.mov` (HEVC, `AVVideoComposition` + `AVAssetExportSession`) com o look aplicado. **O original é mantido.**
- O mesmo código aplica o look no preview e na exportação (o raio do Dream é proporcional à largura para manter o resultado igual).
- Limitações: os looks foram pensados para material Rec.709. Em Log, use a LUT no preview. Gravar já com o filtro aplicado exige o pipeline `AVAssetWriter` (Fase 4).

---

## 3. Pendências que dependem de você
1. **Testar em iPhone físico** com o roteiro H1–H15 de `docs/TESTES_E_VALIDACAO.md`. Pontos críticos: orientação da imagem processada (zebra/LUT), Log/HLG no arquivo, 4K60 com monitoramento ligado e SSD.
2. Definir Team de assinatura, e-mail de contato e domínio do site.

## 4. Próximos passos (roadmap)
| Fase | Item | Observação técnica |
|---|---|---|
| 4 | Pipeline `AVAssetWriter` opcional | Libera **bitrate manual**, **LUT gravada** e **filtro gravado ao vivo** (hoje inviável com `MovieFileOutput`) |
| 4 | Modo Cinematográfico (iOS 26) e redução de ruído low light (iOS 27) | `isCinematicVideoCaptureSupported`, `lowLightVideoNoiseReduction*` |
| 5 | Multicâmera (PiP / lado a lado / arquivos separados) | `AVCaptureMultiCamSession`, já detectado no perfil |
| 5 | ProRes RAW, `AVProVideoStorage` (27), timecode, genlock | Exigem validação em hardware Pro |
| 5 | Personalização dos cards do Pro Mode | O modelo já separa cada card |
| 6 | Profiling no Instruments (térmica, memória, gravação de 30+ min) | Roteiro H10 |
| 7 | TestFlight, screenshots e revisão de privacidade | Site e políticas já prontos |

## 5. Mapa rápido dos arquivos
| Quero mexer em… | Arquivo |
|---|---|
| Regras de compatibilidade | `TRCamera/Domain/FormatResolver.swift` |
| Recomendações/presets | `TRCamera/Domain/RecordingAdvisor.swift`, `Presets.swift` |
| Controle da câmera | `TRCamera/Core/Capture/ProfessionalCaptureEngine.swift` |
| Zebra/peaking/LUT/scopes | `TRCamera/Core/Processing/MonitoringProcessor.swift` |
| Estado da tela | `TRCamera/Features/Camera/CameraViewModel.swift` |
| Layout | `TRCamera/Features/Camera/CameraScreen.swift` |
| Cores e componentes | `TRCamera/DesignSystem/Theme.swift` |
