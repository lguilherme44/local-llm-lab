# Benchmark Report — substituído

Este arquivo era escrito à mão a partir do `scripts/run_moe_benchmark_pipeline.py` e o
conteúdo estava errado. Ele afirmava:

> **Issues:** None detected.

para modelos cujo `index.html` estava cortado no meio de uma tag. O pipeline não
registrava `finish_reason`, então não tinha como detectar a truncagem, e o relatório
herdou essa cegueira.

O relatório atual é gerado automaticamente:

```bash
python3 scripts/run_benchmark.py
```

- **[`benchmark-report/BENCHMARK.md`](benchmark-report/BENCHMARK.md)** — para ler
- `benchmark-report/benchmark_summary.json` — para processar
- `benchmark-report/responses/<perfil>/` — resposta bruta de cada tarefa, para auditar
  um FAIL

Por que o anterior não servia:
[`docs/diagnostico-linux-benchmark.md`](docs/diagnostico-linux-benchmark.md).
