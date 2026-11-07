# Testes e validação

## Automatizados (rodam no simulador) — 29 testes, todos passando

```bash
xcodebuild -project TRCamera.xcodeproj -scheme TRCamera -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

| Suíte | Cobre |
|---|---|
| `ExposureMathTests` | 180° @ 24 fps = 1/48; ida e volta ângulo↔tempo; shutter nunca > 1/fps; limites de ISO; rótulos |
| `FormatResolverTests` | Só oferece fps reportados; Log indisponível em 4K60; escolha de formato não-binned; reparo de combinação impossível com explicação; fallback de resolução; ProRes → HEVC quando não listado; 29.97 = 1001/30000 |
| `AdvisorAndPresetTests` | Cinema = 24 fps/180°; Log indisponível em aparelho sem Log; prefere Apple Log 2; alto movimento ≥ 60; aviso de pouco espaço; validação de preset com substituições; persistência |
| `StorageAndLUTTests` | HEVC 4K30 ≈ 170 MB/min; ProRes ≫ HEVC; reserva de espaço; parser `.cube` (e rejeições); curva Apple Log (ida/volta, cinza 18% ≈ 48%, continuidade); LUT monotônica; scopes com frame sintético |

## Exigem iPhone físico (o simulador não tem câmera)

| # | Teste | Como validar | Aparelhos |
|---|---|---|---|
| H1 | Detecção de lentes e formatos | Abrir “Perfil do iPhone” (ícone CPU), exportar JSON | Todos da matriz |
| H2 | Preview estável e orientação | Girar retrato ↔ paisagem gravando e parado | Todos |
| H3 | Arquivo válido | Gravar 10 s; na Biblioteca conferir codec, dimensões, fps, áudio, “Reproduzível: Sim” | Todos |
| H4 | Apple Log / Log 2 | Selecionar perfil; conferir “Transferência” no detalhe do arquivo | 15 Pro+ / iOS 26+ |
| H5 | HLG / Dolby Vision | Gravar HLG; conferir transferência `ITU_R_2100_HLG` e reprodução HDR no Fotos | Compatíveis |
| H6 | ProRes | Selecionar ProRes; conferir codec `apch/apcn` | Pro |
| H7 | Shutter/ISO manual e prioridade | 1/48 fixo com ISO auto: variar a luz; no iOS < 27 conferir badge EMUL | Todos |
| H8 | Abertura variável | Card APERTURE ajustável | Somente hardware com íris (iOS 27) |
| H9 | Sincronia A/V | Gravar claquete (palmas); verificar no editor desvio < 1 frame | Todos |
| H10 | Gravação longa | 30 min 4K30 HEVC; observar térmica, quedas de frame (comparar duração × fps nominal) | Base, Plus, Pro, Pro Max |
| H11 | SSD externo | Conectar SSD APFS/exFAT, escolher destino, gravar ProRes | iPhone 15 Pro+ USB-C |
| H12 | Interrupções | Receber ligação, abrir Control Center, ir para background gravando → arquivo preservado | Todos |
| H13 | Espaço cheio | Encher o disco; gravar até o limite → arquivo finalizado e aviso | Qualquer |
| H14 | Monitoramento | Zebra/peaking/LUT: imagem não espelhada/invertida, desempenho estável a 4K60 | Todos |
| H15 | Áudio USB | Interface USB: entrada aparece, ganho conforme suporte, medidores respondem | USB-C |

Matriz mínima sugerida: iPhone XS/XR ou 11 (mais antigo com iOS 17), iPhone 13, iPhone 15 Pro, iPhone 16/16 Plus, iPhone 17 Pro Max.

## Qualidade de vídeo — como medir
- **Resolução/fps/codec/cor:** tela de detalhe do arquivo (lê o próprio `.mov` via `AVURLAsset`).
- **Frames perdidos:** `ffprobe -count_frames` no Mac e comparar com `duração × fps`.
- **Sincronia:** claquete + inspeção da forma de onda no editor.
- **Metadados:** `exiftool arquivo.mov` (Make, Model, Software, Description com JSON técnico) e o sidecar `.json`.
