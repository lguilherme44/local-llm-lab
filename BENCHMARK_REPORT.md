# Benchmark Report

## Model: DeepSeek‑Coder‑V2‑Lite
- **Median throughput:** ~18 tok/s (benchmark completed successfully).
- **Landing page:** Generated successfully.
  - File: [index.html](file:///Users/guilhermelellis/Desktop/local-llm-lab/examples/landing-page-deepseek-v2-lite/index.html)
  - README: [README.md](file:///Users/guilhermelellis/Desktop/local-llm-lab/examples/landing-page-deepseek-v2-lite/README.md)
- **Issues:** None detected.

## Model: Unsloth‑Qwen3.6‑35B‑MoE
- **Benchmark status:** *(pending / not yet executed)*
- **Landing page:** *(not generated yet)*
- **Notes:** Need to run `run_moe_benchmark_pipeline` for profile `unsloth` and generate landing page.

## Model: Bonsai‑27B (Prism‑ML) – gguf
- **Benchmark status:** Pending download and test.
- **Landing page:** Pending generation.
- **Notes:** Ensure model is pulled via `llm-server.sh pull bonsai` and then run benchmark + landing page generation.

---

### Next Steps
1. Execute benchmark for **Unsloth‑Qwen3.6‑35B‑MoE** and generate its landing page.
2. Pull and benchmark **Bonsai‑27B‑gguf**, then generate its landing page.
3. Commit this documentation (and any newly generated files) using conventional commits.

*All actions will be recorded in Engram for future reference.*
