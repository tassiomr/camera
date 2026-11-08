# Luminous Cam — Diretriz do projeto

Bundle ID: **`com.trmedia.camera`** · Nome exibido: **Luminous Cam** · iOS mínimo **17.0** · iPhone · SwiftUI + AVFoundation + Core Image/Metal
Estado em 07/11/2026: **Fases 1–3 completas, Fase 4 parcial, site pronto.** Compila sem warnings para iPhone físico; **65/65 testes passando** no simulador.

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
- Mesma família visual do Luminous (fundo grafite, luz menta→azul→violeta, **ponto de luz** com flare), mas com forma própria de câmera: um **diafragma de 6 lâminas** com vidro escuro na abertura. O crescente foi abandonado porque lembrava o ícone de playlist do Luminous. Inclui variante *tinted* do iOS; o site usa o mesmo ícone (`public/assets`).
- Gerador reproduzível em `tools/make_icon.swift` (`swiftc -O tools/make_icon.swift -o mk && ./mk AppIcon.png`).

### F11. Site (Vercel) → `public/`
- Visual no estilo Luminous: aurora de fundo, vidro, mockup do app feito só em CSS (preview com o efeito punch no ritmo), seções de recursos, “No ritmo”, filtros e privacidade. Páginas legais com índice lateral; suporte em formato de perguntas frequentes.
- Usa só fontes do sistema: o site não faz nenhuma requisição a terceiros (sem Google Fonts, scripts ou cookies), coerente com a política de privacidade.
- `index.html` (landing), `privacidade.html`, `termos.html`, `suporte.html`, `styles.css`. O `vercel.json` fica na **raiz do repositório** e publica a pasta `public` sem etapa de build (URLs limpas: `/privacidade`, `/termos`, `/suporte`; redirects de `/privacy`, `/terms`, `/support`; headers de segurança).
- **Antes de publicar:** troque `CONTATO_EMAIL` (aparece em 3 arquivos) pelo e-mail de contato real e confirme o nome da empresa (“TR Media”).
- Deploy:
```bash
npx vercel --prod
```
  Ou importe o repositório pela interface da Vercel **sem alterar nada** (Root Directory `./`): o `vercel.json` da raiz já aponta a saída para `public/`. Se o deploy falhar, confira em Settings › Build and Deployment que o Root Directory está vazio e que nenhum Build Command foi sobrescrito.
- App Store Connect: *Privacy Policy URL* = `https://SEU-DOMINIO/privacidade`, *Support URL* = `/suporte`, rótulo de privacidade = **“Data Not Collected”**.

### F12. Filtros criativos (looks) → `Core/Processing/VideoLook.swift`
- 12 looks com filtros nativos do Core Image: Original, Vivid, Teal & Orange, Warm Film, Cool, Fade, Bleach, Vintage, Mono, Noir, Chrome e Dream.
- **Ao vivo:** o chip **FILTRO** na barra superior abre uma faixa de looks sobre o preview. O filtro aparece só na visualização, e o arquivo é gravado limpo. O look usado fica registrado nos metadados como "somente preview".
- **No vídeo:** na Biblioteca, **"Exportar cópia com filtro"** gera um novo `.mov` (HEVC, `AVVideoComposition` + `AVAssetExportSession`) com o look aplicado. **O original é mantido.**
- O mesmo código aplica o look no preview e na exportação (o raio do Dream é proporcional à largura para manter o resultado igual).
- Limitações: os looks foram pensados para material Rec.709. Em Log, use a LUT no preview. Gravar já com o filtro aplicado exige o pipeline `AVAssetWriter` (Fase 4).

### F13. Batidas da música → `Domain/BeatDetector.swift`, `Core/Audio/BeatTracker.swift`, `Core/Processing/BeatEffect.swift`
- **Decisão de arquitetura:** o efeito **não é gravado no arquivo**. Para isso seria preciso trocar o `AVCaptureMovieFileOutput` por `AVAssetWriter`, o que traz mais risco de perder frames, mais aquecimento e efeitos irreversíveis no take. O fluxo tem duas etapas:
  1. **Ao vivo (preview):** o chip **BATIDA** escolhe o efeito: Zoom punch, Flash, Punch + flash, Tremor ou RGB split. O áudio do microfone é analisado e o preview pulsa no ritmo, mostrando o BPM no chip. As batidas detectadas vão para o sidecar JSON (`beatMap`, `source: live`; tempos aproximados, com erro de cerca de 1 frame).
  2. **Depois de gravado:** na Biblioteca, **"Editar no ritmo da música"** analisa o áudio do próprio arquivo, que é mais preciso porque o app conhece a faixa inteira. Gera uma cópia com o efeito em cada batida. **O original é mantido.**
- **Algoritmo:** FFT do Accelerate (janela de 2048, hop de 512). Calcula o *spectral flux* em escala logarítmica, com peso na faixa do bumbo (30–250 Hz).
  - O BPM vem da autocorrelação, entre 70 e 180 BPM, com soma harmônica para evitar ler metade do tempo.
  - **Offline:** as batidas são posicionadas por programação dinâmica (Ellis 2007).
  - **Ao vivo:** usa detecção de picos com limiar adaptativo e ignora os chimbais.
- **Custo e segurança:**
  - A saída de áudio só é adicionada à sessão quando o usuário liga a função; com ela desligada, nada muda.
  - Não dá para ligar no meio de uma gravação.
  - Se o iPhone recusar a saída de áudio, o app avisa e desliga a função.
  - O flash é limitado a menos de 3 por segundo (diretriz de fotossensibilidade) e a +1 EV.
- **Testes (`BeatTests.swift`):**
  - Faixas sintéticas de 90 a 174 BPM, com chimbal no contratempo, ruído forte e áudio a 48 kHz.
  - Silêncio e ruído branco não podem gerar batidas.
  - Streaming independente do tamanho do buffer; custo de CPU (60 s de áudio processados em cerca de 1 s no simulador, em build debug).
  - Exportação real em que o flash cai na batida e o original continua idêntico byte a byte.
- **Limitações honestas:**
  - O microfone em show (público, vento, AGC) vai errar algumas batidas. Por isso a edição final usa a análise do arquivo.
  - Ao vivo, a detecção tem atraso de cerca de 20–40 ms.
  - Músicas do Apple Music (DRM) não podem ser analisadas.
  - Mudanças bruscas de andamento ainda não são acompanhadas, porque o tempo estimado é um só por clipe.
  - **Validar no iPhone real:** se `canAddOutput` aceita a saída de áudio junto com a gravação em cada formato (sobretudo ProRes/Log), e a precisão com música ambiente.
- **Próximos passos possíveis:**
  - Escolher uma faixa do app Arquivos para sincronia exata antes de gravar.
  - Intensidade ajustável.
  - Trocar de look nos tempos fortes.
  - Exportar em 1080p a partir de 4K para o zoom não perder nitidez.

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
