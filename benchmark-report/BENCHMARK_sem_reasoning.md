# Benchmark — Local LLM Lab

Execução: 2026-08-03T22:40:48+00:00

## Ambiente

- GPU: NVIDIA GeForce RTX 3060 Ti, 8192 MiB, 595.84
- Backend ggml: `base cpu-alderlake cpu-cannonlake cpu-cascadelake cpu-cooperlake cpu-haswell cpu-icelake cpu-ivybridge cpu-piledriver cpu-sandybridge cpu-sapphirerapids cpu-skylakex cpu cpu-sse42 cpu-x64 cpu-zen4 cuda rpc vulkan`
- CUDA: **sim** · Vulkan: sim

## Qualidade (taxa de acerto por eixo)

| Modelo | bugfix | patch | tool call | ctx longo | instrução | truncadas |
|---|---|---|---|---|---|---|
| Qwen 3.6 35B-A3B MoE | 100% | 100% | 100% | 100% | 100% | 0 |

## Performance

| Modelo | TTFT med | Geração med | Prefill med | VRAM pico | RAM pico | Swap pico | Confiável |
|---|---|---|---|---|---|---|---|
| Qwen 3.6 35B-A3B MoE | — | — | — | — | — | — | — |

## Notas de método

- Sem score agregado único: os eixos medem capacidades distintas e a média de vereditos binários esconde o que interessa.
- `pass_rate` é acerto sobre todas as tentativas; o JSON também traz `pass_at_1` e `pass_at_k` por tarefa.
- Percentil só é reportado com n ≥ 20 amostras.
- Truncagem é diagnóstico, não veredito: pode passar truncado ou reprovar sem truncar. Se a coluna `truncadas` estiver alta, o `max_tokens` está curto para o gasto de reasoning do modelo.
