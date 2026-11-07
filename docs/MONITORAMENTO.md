# Ferramentas de monitoramento

Todas são **somente visualização**: o arquivo gravado nunca é alterado.

| Ferramenta | Opera sobre | Detalhe |
|---|---|---|
| Zebra | Sinal gravado (valores de código) | Listras onde luma Rec.709 ≥ nível (70/80/90/95/100%). Em Log os níveis são do sinal Log (ex.: 95% em Log ≈ próximo do clip do sensor), não de IRE em 709 |
| Focus peaking | Sinal gravado | Bordas (`CIEdges`) com limiar ajustável; cor configurável. Calculado na resolução da tela |
| False color | Imagem monitorada (após LUT) | Faixas abaixo |
| LUT | Visualização | `.cube` 3D até 256³; LUT técnica Apple Log→709 embutida (aproximação) |
| Desqueeze | Visualização | 1.33 / 1.55 / 1.8 / 2.0× horizontal |
| Histograma | Sinal | Luma + RGB, 64 bins, 10 Hz, alerta “CLIP” > 1% de pixels ≥ 98% |
| Waveform | Sinal | Luma por coluna (96×48), linhas de referência 10/50/90% |

## Escala de false color

| Sinal | Cor | Significado |
|---|---|---|
| 0–2,5% | Roxo | Pretos esmagados, sem detalhe |
| 2,5–10% | Azul | Quase preto |
| 38–44% | Verde | Cinza médio 18% em Rec.709 |
| 52–58% | Rosa | Pele clara (~+1 stop) |
| 90–97% | Amarelo | Próximo do clip |
| 97–100% | Vermelho | Clipado |
| Demais | Cinza escurecido | — |

Limitação: as faixas assumem Rec.709. Em Log use com a LUT ativa; em HLG os valores são aproximados.
