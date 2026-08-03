#!/usr/bin/env python3
"""
Local LLM Lab — pipeline de benchmark.

Substitui o run_moe_benchmark_pipeline.py. As diferenças que importam:

  • Métricas vêm de `timings` do llama.cpp, não de `len(text) // 4`.
  • `finish_reason` é registrado, então truncagem é detectada em vez de virar
    "Issues: None detected".
  • Tokens de reasoning são contabilizados (eram invisíveis e são a causa das
    páginas truncadas).
  • Qualidade é medida por veredito binário verificável, não por presença de
    substring.
  • Falha de um modelo é registrada com diagnóstico, não engolida.
  • O backend e a cmdline efetiva entram no relatório, para que ninguém compare
    execuções feitas com backends diferentes sem perceber.

Uso:
    python3 scripts/run_benchmark.py                    # todos os perfis
    python3 scripts/run_benchmark.py qwen27b deepseek   # só estes
    python3 scripts/run_benchmark.py --perf-rounds 6
    python3 scripts/run_benchmark.py --repeats 3        # pass@k nas tarefas
    python3 scripts/run_benchmark.py --skip-perf        # só qualidade
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import traceback
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

sys.path.insert(0, str(Path(__file__).parent))

from bench_lib import (                                    # noqa: E402
    GenResult, InferenceClient, RemoteHardwareMonitor, describe, result_to_dict,
)
from bench_server import RemoteServer, ServerError         # noqa: E402
import bench_tasks as tasks                                # noqa: E402


# ─── configuração ───────────────────────────────────────────────────────────────

SSH_KEY = os.path.expanduser(
    os.environ.get("LLM_SSH_KEY", "~/.ssh/id_ed25519_windows"))
REMOTE_HOST = os.environ.get("LLM_REMOTE_HOST", "lellis@192.168.3.51")
REMOTE_IP = REMOTE_HOST.split("@")[-1]
SERVER_URL = f"http://{REMOTE_IP}:8080/v1/chat/completions"
HEALTH_URL = f"http://{REMOTE_IP}:8080/health"

PROJECT_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_DIR = PROJECT_ROOT / "benchmark-report"

# Perfis a testar. `ctx` precisa acomodar a tarefa de contexto longo (~8.3k de
# prompt) mais a resposta, senão o teste mede o orçamento e não o modelo.
PROFILES = [
    {"profile": "qwen27b", "name": "Qwen 3.6 27B",           "ctx": 16384},
    {"profile": "moe",     "name": "Qwen 3.6 35B-A3B MoE",   "ctx": 16384},
    {"profile": "deepseek","name": "DeepSeek Coder V2 Lite", "ctx": 16384},
    {"profile": "bonsai",  "name": "Bonsai 27B",             "ctx": 16384},
    {"profile": "agent",   "name": "Qwen3 8B (baseline)",    "ctx": 16384},
]

# Prompt de warmup DIFERENTE do prompt medido.
#
# A versão anterior aquecia com o mesmo prompt que ia medir, populando o prompt
# cache do llama.cpp — e depois reportava o TTFT do cache hit como prefill real.
# O log do servidor confirma o reuso: `selected slot by LCP similarity`.
WARMUP_PROMPT = "Liste três tipos primitivos de TypeScript, um por linha."
PERF_PROMPT = ("Escreva uma função de busca binária em Python com docstring "
               "e três casos de teste.")

# Prefill precisa de prompt LONGO, senão a métrica é ruído.
#
# Com o prompt curto acima (~30 tokens) o llama.cpp reportou 17-31 tok/s de
# prefill; com um prompt de 715 tokens, o MESMO servidor reportou 314 tok/s. A
# diferença é overhead fixo dividido por pouquíssimos tokens — não velocidade de
# prefill. Medir prefill com prompt curto foi um erro herdado do
# `llm-server.sh bench`, e ele torna a coluna inutilizável.
#
# Um prompt de ~1.5k tokens também é mais representativo do uso real: um agente
# manda contexto de repositório, não uma frase.
# O parâmetro `seed` varia o prompt a cada rodada, e ele entra no INÍCIO.
#
# Sem isso, medir prefill várias vezes com o mesmo prompt mede o prompt cache: a
# rodada 1 processa 3154 tokens e as seguintes processam 4, porque o llama.cpp
# reaproveita o prefixo (`selected slot by LCP similarity` no log). Foi
# exatamente o defeito do warmup antigo, reintroduzido por descuido.
#
# Variar no fim não resolveria: o cache casa por prefixo comum.
def _build_prefill_prompt(seed: int) -> str:
    bloco = (
        "def handler_{i:03d}(payload, *, retries={r}):\n"
        '    """Processa o evento {i:03d} do barramento {s}."""\n'
        "    for tentativa in range(retries):\n"
        "        resultado = dispatch(payload, timeout={t})\n"
        "        if resultado.ok:\n"
        "            return resultado\n"
        "    raise RuntimeError('handler {i:03d} esgotou as tentativas')\n\n"
    )
    corpo = "".join(
        bloco.format(i=i, r=i % 4 + 1, t=500 + i * 13 + seed * 7, s=seed)
        for i in range(40))
    return (f"Revisão {seed}. Leia o código abaixo e responda em uma única "
            f"frase o que ele faz.\n\n```python\n{corpo}```")


# ─── suíte de performance ───────────────────────────────────────────────────────

def run_performance(client: InferenceClient, monitor: RemoteHardwareMonitor,
                    rounds: int) -> Dict[str, Any]:
    print(f"\n  📊 Performance ({rounds} rodadas)")

    print("     ♨️  warmup (prompt distinto do medido, para não envenenar o cache)")
    warm = client.generate(WARMUP_PROMPT, max_tokens=64)
    if not warm.ok:
        print(f"     ⚠️  warmup falhou: {warm.error}")

    results: List[GenResult] = []
    monitor.start()
    try:
        for i in range(1, rounds + 1):
            res = client.generate(PERF_PROMPT, max_tokens=512)
            results.append(res)
            print(f"     [{i}/{rounds}] {res.summary()}")
            time.sleep(1.0)
    finally:
        hardware = monitor.stop()

    # Prefill medido à parte, com prompt longo. Ver PREFILL_PROMPT.
    print("     📥 prefill com prompt longo (~1.5k tokens)")
    prefill_runs: List[GenResult] = []
    for i in range(1, min(rounds, 3) + 1):
        pr = client.generate(_build_prefill_prompt(i), max_tokens=32)
        prefill_runs.append(pr)
        rate = f"{pr.prefill_rate:.0f}" if pr.prefill_rate else "?"
        print(f"     [{i}] {pr.prompt_tokens} tok de prompt → {rate} tok/s")
        time.sleep(1.0)

    ok = [r for r in results if r.ok]
    sources = {r.metrics_source for r in ok}

    out: Dict[str, Any] = {
        "rounds_requested": rounds,
        "rounds_ok": len(ok),
        "ttft": describe([r.ttft for r in ok if r.ttft is not None], "TTFT (s)"),
        "gen_rate": describe([r.gen_rate for r in ok if r.gen_rate is not None],
                             "geração (tok/s)"),
        # Só do prompt longo. O prefill das rodadas de geração fica fora de
        # propósito: prompt de ~30 tokens mede overhead, não prefill.
        "prefill_rate": describe(
            [r.prefill_rate for r in prefill_runs
             if r.ok and r.prefill_rate is not None],
            "prefill (tok/s, prompt longo)"),
        "prefill_prompt_tokens": next(
            (r.prompt_tokens for r in prefill_runs if r.prompt_tokens), None),
        "hardware": hardware,
        # Se algum número veio de estimativa do cliente, o relatório precisa
        # dizer — comparar servidor com estimativa é comparar coisas diferentes.
        "metrics_sources": sorted(sources),
        "metrics_trustworthy": sources == {"server"},
        "rounds": [result_to_dict(r) for r in results],
    }

    gen_med = out["gen_rate"].get("median")
    power = hardware.get("avg_power_w") or 0
    out["tokens_per_watt"] = round(gen_med / power, 3) if gen_med and power else None

    if not out["metrics_trustworthy"]:
        print(f"     ⚠️  métricas não são todas do servidor: {sorted(sources)}")
    return out


# ─── suíte de qualidade ─────────────────────────────────────────────────────────

def run_quality(client: InferenceClient, repeats: int,
                artifact_dir: Path) -> Dict[str, Any]:
    print(f"\n  🎯 Qualidade — {len(tasks.ALL_TASKS)} tarefas × {repeats} "
          f"repetição(ões)")
    artifact_dir.mkdir(parents=True, exist_ok=True)

    per_task: Dict[str, Any] = {}

    for task in tasks.ALL_TASKS:
        attempts: List[Dict[str, Any]] = []
        print(f"     • {task.key} ({task.axis})")

        for attempt in range(1, repeats + 1):
            res = client.generate(task.prompt, max_tokens=task.max_tokens,
                                  extra_body=task.extra_body or None)

            if not res.ok:
                grade = tasks.Grade(False, f"requisição falhou: {res.error}")
            elif task.axis == "tool_call":
                # Tool call precisa do objeto estruturado, não do texto.
                grade = tasks.grade_tool_call_structured(res.tool_calls)
                if not grade.passed and res.content:
                    fallback = task.grader(res.content)
                    grade = tasks.Grade(False,
                                        f"{grade.reason}; {fallback.reason}",
                                        fallback.detail)
            else:
                grade = task.grader(res.content)

            # Truncagem é diagnóstico, não veredito: uma tarefa pode passar mesmo
            # truncada, e reprovar sem truncagem. Registrar as duas coisas
            # separadas evita confundir "modelo ruim" com "orçamento curto".
            attempts.append({
                "attempt": attempt,
                "passed": grade.passed,
                "reason": grade.reason,
                "detail": grade.detail[:600],
                "truncated": res.truncated,
                "finish_reason": res.finish_reason,
                "reasoning_share": round(
                    res.reasoning_chars / (res.reasoning_chars + len(res.content)), 3
                ) if (res.reasoning_chars + len(res.content)) else 0.0,
                "gen_tokens": res.gen_tokens,
                "total_time": round(res.total_time, 1),
            })

            mark = "✓ PASS" if grade.passed else "✗ FAIL"
            flag = "  [truncado]" if res.truncated else ""
            print(f"       {attempt}/{repeats} {mark} — {grade.reason}{flag}")

            # Guardar a resposta bruta. Sem isso, um FAIL é inauditável.
            raw = artifact_dir / f"{task.key}_try{attempt}.txt"
            raw.write_text(
                f"=== finish_reason={res.finish_reason} truncated={res.truncated} "
                f"gen_tokens={res.gen_tokens} ===\n\n"
                f"--- reasoning ({res.reasoning_chars} chars) ---\n{res.reasoning}\n\n"
                f"--- content ---\n{res.content}\n",
                encoding="utf-8",
            )

        passes = sum(1 for a in attempts if a["passed"])
        per_task[task.key] = {
            "axis": task.axis,
            "attempts": repeats,
            "passes": passes,
            "pass_rate": round(passes / repeats, 3),
            "pass_at_1": attempts[0]["passed"],
            "pass_at_k": passes > 0,
            "runs": attempts,
        }

    # Agrega por eixo. Sem score único: os eixos não são comparáveis entre si e
    # a média de vereditos binários esconde exatamente o que interessa.
    by_axis: Dict[str, Any] = {}
    for axis in tasks.AXES:
        keys = [k for k, v in per_task.items() if v["axis"] == axis]
        if not keys:
            continue
        total_att = sum(per_task[k]["attempts"] for k in keys)
        total_pass = sum(per_task[k]["passes"] for k in keys)
        by_axis[axis] = {
            "tasks": len(keys),
            "pass_rate": round(total_pass / total_att, 3) if total_att else 0.0,
            "all_passed_once": all(per_task[k]["pass_at_k"] for k in keys),
        }

    truncated_any = sum(
        1 for v in per_task.values() for r in v["runs"] if r["truncated"])

    return {
        "tasks": per_task,
        "by_axis": by_axis,
        "truncated_runs": truncated_any,
        "artifacts": str(artifact_dir.relative_to(PROJECT_ROOT)),
    }


# ─── relatório ──────────────────────────────────────────────────────────────────

def write_reports(payload: Dict[str, Any]) -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    json_path = OUTPUT_DIR / "benchmark_summary.json"
    json_path.write_text(json.dumps(payload, indent=2, ensure_ascii=False),
                         encoding="utf-8")
    print(f"\n💾 JSON: {json_path.relative_to(PROJECT_ROOT)}")

    env = payload["environment"]
    lines: List[str] = [
        "# Benchmark — Local LLM Lab",
        "",
        f"Execução: {payload['started_at']}",
        "",
        "## Ambiente",
        "",
        f"- GPU: {env.get('gpu', '?')}",
        f"- Backend ggml: `{' '.join(env.get('ggml_backends', []))}`",
        f"- CUDA: **{'sim' if env.get('has_cuda') else 'NÃO'}**"
        f" · Vulkan: {'sim' if env.get('has_vulkan') else 'não'}",
        "",
    ]

    if not env.get("has_cuda"):
        lines += [
            "> ⚠️ **Rodando sem CUDA.** No backend Vulkan esta máquina mediu "
            "2.7 tok/s de geração e 1-9 tok/s de prefill, com a GPU a 18% de uso. "
            "Números de performance obtidos assim não representam o hardware. "
            "Ver `docs/diagnostico-linux-benchmark.md`.",
            "",
        ]

    # ─ tabela de qualidade: é a que responde "serve para programar?"
    lines += ["## Qualidade (taxa de acerto por eixo)", "",
              "| Modelo | bugfix | patch | tool call | ctx longo | instrução | truncadas |",
              "|---|---|---|---|---|---|---|"]
    for r in payload["results"]:
        if r["status"] != "ok":
            lines.append(f"| {r['name']} | — | — | — | — | — | falhou |")
            continue
        ax = r["quality"]["by_axis"]

        def cell(axis: str) -> str:
            if axis not in ax:
                return "—"
            return f"{ax[axis]['pass_rate'] * 100:.0f}%"

        lines.append(
            f"| {r['name']} | {cell('bugfix')} | {cell('patch_format')} | "
            f"{cell('tool_call')} | {cell('long_context')} | "
            f"{cell('instruction')} | {r['quality']['truncated_runs']} |")

    # ─ tabela de performance
    lines += ["", "## Performance", "",
              "| Modelo | TTFT med | Geração med | Prefill med | VRAM pico | "
              "RAM pico | Swap pico | Confiável |", "|---|---|---|---|---|---|---|---|"]
    for r in payload["results"]:
        if r["status"] != "ok" or not r.get("performance"):
            lines.append(f"| {r['name']} | — | — | — | — | — | — | — |")
            continue
        p = r["performance"]
        hw = p["hardware"]
        lines.append(
            f"| {r['name']} "
            f"| {p['ttft'].get('median', '—')} s "
            f"| {p['gen_rate'].get('median', '—')} tok/s "
            f"| {p['prefill_rate'].get('median', '—')} tok/s "
            f"| {hw.get('peak_vram_gb', '—')} GB "
            f"| {hw.get('peak_ram_used_gb', '—')} GB "
            f"| {hw.get('peak_swap_used_gb', '—')} GB "
            f"| {'sim' if p['metrics_trustworthy'] else 'ESTIMADO'} |")

    # ─ falhas: explícitas, nunca silenciosas
    failed = [r for r in payload["results"] if r["status"] != "ok"]
    if failed:
        lines += ["", "## Falhas", ""]
        for r in failed:
            lines += [f"### {r['name']} (`{r['profile']}`)", "",
                      f"**{r['status']}**: {r.get('error', '?')}", ""]
            if r.get("server_log"):
                lines += ["```", r["server_log"][-1500:], "```", ""]

    lines += ["", "## Notas de método", "",
              "- Sem score agregado único: os eixos medem capacidades distintas "
              "e a média de vereditos binários esconde o que interessa.",
              "- `pass_rate` é acerto sobre todas as tentativas; o JSON também "
              "traz `pass_at_1` e `pass_at_k` por tarefa.",
              "- Percentil só é reportado com n ≥ 20 amostras.",
              "- Truncagem é diagnóstico, não veredito: pode passar truncado ou "
              "reprovar sem truncar. Se a coluna `truncadas` estiver alta, o "
              "`max_tokens` está curto para o gasto de reasoning do modelo.",
              ""]

    md_path = OUTPUT_DIR / "BENCHMARK.md"
    md_path.write_text("\n".join(lines), encoding="utf-8")
    print(f"📄 Markdown: {md_path.relative_to(PROJECT_ROOT)}")


# ─── orquestração ───────────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("profiles", nargs="*", help="perfis a testar (padrão: todos)")
    ap.add_argument("--perf-rounds", type=int, default=5)
    ap.add_argument("--repeats", type=int, default=1,
                    help="repetições por tarefa de qualidade (pass@k)")
    ap.add_argument("--skip-perf", action="store_true")
    ap.add_argument("--skip-pull", action="store_true")
    args = ap.parse_args()

    selected = PROFILES
    if args.profiles:
        wanted = set(args.profiles)
        selected = [p for p in PROFILES if p["profile"] in wanted]
        unknown = wanted - {p["profile"] for p in PROFILES}
        if unknown:
            print(f"perfis desconhecidos: {sorted(unknown)}", file=sys.stderr)
            return 2

    server = RemoteServer(ssh_key=SSH_KEY, host=REMOTE_HOST, health_url=HEALTH_URL)
    monitor = RemoteHardwareMonitor(REMOTE_HOST, SSH_KEY)

    print("=" * 62)
    print("  Local LLM Lab — pipeline de benchmark")
    print("=" * 62)

    env = server.backend_info()
    print(f"\nGPU:     {env['gpu']}")
    print(f"Backend: {' '.join(env['ggml_backends'])}")
    if not env["has_cuda"]:
        print("\n⚠️  SEM CUDA. Números de performance não representarão o hardware.")
        print("   Rode: ./linux/llm-server.sh setup   (ver TODO.md fase 1)\n")

    payload: Dict[str, Any] = {
        "started_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "environment": env,
        "config": {"perf_rounds": args.perf_rounds, "repeats": args.repeats,
                   "skip_perf": args.skip_perf},
        "results": [],
    }

    for spec in selected:
        profile, name = spec["profile"], spec["name"]
        print(f"\n{'─' * 62}\n🎬 {name}  (perfil `{profile}`)\n{'─' * 62}")

        entry: Dict[str, Any] = {"name": name, "profile": profile,
                                 "ctx": spec["ctx"], "status": "ok"}

        # try/except por modelo. A versão anterior não tinha, e o Bonsai falhou
        # deixando um diretório vazio e nenhuma linha no relatório.
        try:
            if not args.skip_pull:
                server.pull(profile)
            server.start_profile(profile, ctx=spec["ctx"])
            entry["effective_cmdline"] = server.effective_config()

            client = InferenceClient(SERVER_URL, idle_timeout=240.0,
                                     read_timeout=2400.0)

            if not args.skip_perf:
                entry["performance"] = run_performance(
                    client, monitor, args.perf_rounds)

            entry["quality"] = run_quality(
                client, args.repeats,
                OUTPUT_DIR / "responses" / profile)

        except ServerError as exc:
            entry["status"] = "erro_de_servidor"
            entry["error"] = str(exc)
            entry["server_log"] = server.tail_log(40)
            print(f"\n  ❌ falha de servidor: {exc}")
        except KeyboardInterrupt:
            entry["status"] = "interrompido"
            payload["results"].append(entry)
            print("\n⏹  interrompido pelo usuário; gravando o que foi medido.")
            break
        except Exception as exc:                            # noqa: BLE001
            entry["status"] = "erro_inesperado"
            entry["error"] = f"{type(exc).__name__}: {exc}"
            entry["traceback"] = traceback.format_exc()[-2000:]
            print(f"\n  ❌ erro inesperado: {exc}")

        payload["results"].append(entry)

    payload["finished_at"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    write_reports(payload)

    ok = sum(1 for r in payload["results"] if r["status"] == "ok")
    print(f"\n{'=' * 62}")
    print(f"  {ok}/{len(payload['results'])} perfis completaram")
    print("=" * 62)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
