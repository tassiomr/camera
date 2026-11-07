# Pesquisa técnica e matriz de compatibilidade

**Fonte primária:** headers do SDK **iOS 27.2** (Xcode 27.2, `AVFoundation.framework/Headers`), lidos diretamente nesta máquina, e documentação da Apple (AVFoundation, Apple Log Profile white paper, HIG). Os headers são a fonte mais confiável: o que está neles é API pública; o que não está, não é.

## 1. APIs públicas relevantes (confirmadas no SDK)

| Área | API | Desde | Observação |
|---|---|---|---|
| Descoberta de câmeras | `AVCaptureDevice.DiscoverySession` | iOS 10 | Ultra wide, wide, tele, dual/triple (virtuais), TrueDepth, `external` (iOS 17) |
| Formatos | `AVCaptureDevice.Format` (`videoSupportedFrameRateRanges`, `supportedColorSpaces`, `isVideoBinned`, `minISO/maxISO`, `min/maxExposureDuration`, `videoFieldOfView`) | — | Base do `CameraCapabilityEngine` |
| Perfis de cor | `AVCaptureColorSpace`: `sRGB`(0), `P3_D65`(1), `HLG_BT2020`(2, iOS 14.1), `appleLog`(3, iOS 17), **`appleLog2`(4, iOS 26)** | — | Selecionado via `device.activeColorSpace` |
| Codecs | `AVCaptureMovieFileOutput.availableVideoCodecTypes`; `AVVideoCodecType` H.264, HEVC, ProRes 422 Proxy/LT/422/HQ, 4444, **4444 XQ (iOS 18)**, **ProRes RAW / RAW HQ (iOS 26)** | — | Lista depende do **formato ativo** → sondada em runtime |
| Estabilização | `off, standard, cinematic, cinematicExtended, previewOptimized (17), cinematicExtendedEnhanced (18), lowLatency (26), auto` | — | Por formato: `isVideoStabilizationModeSupported` |
| Exposição manual | `setExposureModeCustom(duration:iso:)` | iOS 8 | Os dois parâmetros fixos |
| **Modos de prioridade** | constantes `autoISO`, `autoExposureDuration` em `setExposureModeCustom` | **iOS 27** | Shutter priority / ISO priority nativos |
| **Abertura variável** | `Format.minLensAperture/maxLensAperture/recommendedLensApertureStops`, `setExposureModeCustom(lensAperture:duration:iso:)` | **iOS 27** | Só em hardware com íris variável; nos demais a abertura é **fixa** |
| White balance | `deviceWhiteBalanceGains(for: temperatureAndTint)`, `setWhiteBalanceModeLocked(with:)` | iOS 8 | Kelvin + tint |
| Foco | `setFocusModeLocked(lensPosition:)`, `focusPointOfInterest`; `focusRectOfInterest` (26); tracking contínuo (27) | — | Sem API de rampa → rack focus implementado por passos |
| Zoom | `videoZoomFactor`, `ramp(toVideoZoomFactor:withRate:)`, `virtualDeviceSwitchOverVideoZoomFactors`, `displayVideoZoomFactorMultiplier` (18) | — | Distingue óptico × recorte × digital |
| Focal equivalente | `nominalFocalLengthIn35mmFilm` | iOS 26 | Antes: estimada pelo FOV (marcada "≈") |
| Rotação | `AVCaptureDevice.RotationCoordinator` | iOS 17 | Ângulos de preview e captura separados |
| Armazenamento externo | `AVExternalStorageDevice` + `nextAvailableURLs(withPathExtensions:)` | iOS 17 | Gravação direta em SSD USB-C; `reasonsNotRecommendedForCaptureUse` (27) |
| ProVideo storage | `AVProVideoStorage`, `movieFileOutput.usesProVideoStorage` | iOS 27 | Reservado para fase futura (precisa de validação em aparelho) |
| Pressão do sistema | `device.systemPressureState` (+ fator `batteryStress` no 27) | iOS 11.1 | Monitorado por KVO |
| Multicâmera | `AVCaptureMultiCamSession.isMultiCamSupported`, `Format.isMultiCamSupported` | iOS 13 | Detectado; gravação multicam = Fase 5 |
| Sync externo | `AVExternalSyncDevice` / genlock | iOS 26–27 | Fora do escopo inicial |
| Redução de ruído low light | `lowLightVideoNoiseReduction*` | iOS 27 | Candidato para preset Low Light |
| Áudio | `AVAudioSession` (entradas, `setPreferredInput`, `inputGain`), `AVCaptureAudioChannel.averagePowerLevel/peakHoldLevel` | — | Ganho só quando `isInputGainSettable` |

## 2. Matriz de compatibilidade

Legenda das camadas: **HW** = existe no hardware · **iOS** = exposto pelo sistema · **3P** = acessível a apps de terceiros · **Apple-only** = só no app Câmera · **Próprio** = implementado por processamento do TR Camera · **Inviável**.

| Recurso | Camada | Compatibilidade | API | Restrições |
|---|---|---|---|---|
| 4K 24/25/30 | 3P | Praticamente todos os iPhones suportados pelo iOS 17 | `Format` | Por lente |
| 4K 60 | 3P | Conforme formato | `Format` | Pode excluir Log/estabilização forte |
| 4K 120 | 3P | Apenas formatos que reportam (Pro recentes) | `Format` | Frequentemente binned, sem Log |
| 1080p 240 | 3P | Conforme formato | `Format` | Binned; estabilização limitada |
| HDR HLG 10-bit | 3P | Formatos com `HLG_BT2020` | `activeColorSpace` | HEVC ou ProRes; Dolby Vision 8.4 é metadado gerado pelo encoder — **verificar no arquivo** |
| Dolby Vision (marca) | iOS | Não há chave pública para “ligar Dolby Vision” | — | O app só informa o que o arquivo contém |
| Apple Log | 3P | Formatos com `appleLog` (iPhone 15 Pro+) | `activeColorSpace` | Codec permitido conforme `availableVideoCodecTypes` |
| Apple Log 2 | 3P | Formatos com `appleLog2` (iOS 26+) | idem | Gamut Apple Wide Gamut |
| ProRes 422/HQ/LT/Proxy | 3P | Quando listados para o formato ativo | `setOutputSettings` | Espaço/térmica; 4K60 ProRes costuma exigir armazenamento externo |
| ProRes RAW | 3P | iOS 26+, hardware compatível | `AVVideoCodecTypeAppleProResRAW` | Fase futura (pipeline RAW) |
| Shutter/ISO manual | 3P | `isExposureModeSupported(.custom)` | `setExposureModeCustom` | Shutter ≤ 1/fps |
| Shutter priority nativo | 3P | iOS 27 | constantes `auto*` | iOS 17–26: **emulado** pelo app (marcado “EMUL”) |
| Abertura variável | 3P | Só hardware com íris (iOS 27) | `setExposureModeCustom(lensAperture:…)` | Demais: card “FIXA” somente leitura |
| WB Kelvin/tint | 3P | `isLockingWhiteBalanceWithCustomDeviceGainsSupported` | gains | Ganhos limitados a `maxWhiteBalanceGain` |
| Foco manual / rack | 3P + Próprio | `isLockingFocusWithCustomLensPositionSupported` | lensPosition | Rampa feita em passos de 60 Hz |
| Estabilização cinematográfica | 3P | Por formato | connection | Aumenta latência e recorte |
| Action Mode | Apple-only | — | — | Não exposto a terceiros |
| Modo Cinematográfico (bokeh) | 3P (iOS 26+) | `isCinematicVideoCaptureSupported` | — | Fase futura |
| Zebra, peaking, false color, waveform, histograma | Próprio | Todos | Core Image | Visualização apenas |
| LUT no preview | Próprio | Todos | `CIColorCube` | Não altera o arquivo |
| LUT “gravada” | Próprio (futuro) | — | exige `AVAssetWriter` | Fase 4 |
| Desqueeze anamórfico | Próprio | Todos | transform | Só preview |
| Controle de bitrate | **Inviável** com `AVCaptureMovieFileOutput` | — | exige `AVAssetWriter` | Hoje: apenas estimativa |
| Multicâmera | 3P | `isMultiCamSupported` | `AVCaptureMultiCamSession` | Fase 5; custo de hardware |
| Gravação em SSD | 3P | iPhone USB-C + iOS 17 | `AVExternalStorageDevice` | Drive compatível; autorização do usuário |
| Áudio USB/externo | 3P | Conforme rota | `AVAudioSession` | Ganho nem sempre ajustável |

## 3. Versão mínima: **iOS 17.0**

Justificativa: é a primeira versão com `RotationCoordinator`, Apple Log, `AVExternalStorageDevice`, estabilização `previewOptimized` e `@Observable`. Recursos de iOS 18/26/27 (ProRes 4444 XQ, Apple Log 2, prioridade nativa, abertura variável, focal 35 mm) são ativados com `#available` — aparelhos mais antigos continuam funcionando com o melhor que têm.

## 4. Concorrentes (análise)

| App | Pontos fortes | Pontos fracos / reclamações | Oportunidade para o TR Camera |
|---|---|---|---|
| Blackmagic Camera | Gratuito, controles de cinema completos, ProRes/Log, gravação externa, Blackmagic Cloud | Interface densa, curva de aprendizado alta | Modo Simple + advisor que explica escolhas |
| Final Cut Camera | Integração com Final Cut Pro iPad (multicam ao vivo), interface limpa | Menos ferramentas de exposição, focado no ecossistema FCP | Monitoramento mais rico (waveform, false color) |
| FiLMiC Pro | Pioneiro, muito conhecido | Mudança para assinatura cara, instabilidade relatada após atualizações | Preço justo, estabilidade e transparência |
| Beastcam | Bom para criadores, presets | Recursos avançados em compras | Presets validados pelo hardware real |
| Kino (Lux) | Simples, presets “look” | Pouco controle profissional | Mesma simplicidade + Pro Mode |

Diferenciais escolhidos: **(1)** só mostrar o que o hardware realmente faz (sem opções “fantasma”); **(2)** advisor determinístico que explica o porquê; **(3)** relatório de capacidades exportável; **(4)** inspeção do arquivo gravado (codec, transferência, primárias, fps reais).

## 5. Riscos e limitações conhecidas

1. O simulador **não tem câmera** — toda captura precisa de iPhone físico.
2. `AVCaptureVideoDataOutput` + `AVCaptureMovieFileOutput` na mesma sessão é suportado desde o iOS 16, mas pode restringir combinações em alguns formatos (validar em aparelho; a saída de dados fica desativada quando não há ferramentas ligadas).
3. Bitrate e LUT gravada exigem migração para `AVAssetWriter`.
4. A LUT Apple Log → Rec.709 embutida é **aproximação técnica** (curva oficial + matriz BT.2020→709 + curva filmic); para grading use a LUT oficial da Apple importada como `.cube`.
5. Orientação de renderização do `CIRenderDestination` no `CAMetalLayer` precisa de confirmação visual no aparelho.
