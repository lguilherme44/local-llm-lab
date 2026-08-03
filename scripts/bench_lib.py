#!/usr/bin/env python3
"""
Instrumentação honesta para os benchmarks de modelo local.

Este módulo existe porque a versão anterior do pipeline media coisas que não
podia medir e não media as que importavam. Os três pecados:

  1. Contava tokens com `len(text) // 4`. O llama.cpp devolve `timings` exatos
     no chunk final do stream. HTML e código ficam perto de 3 chars/token, então
     a estimativa superestimava tok/s em ~25%.

  2. Não registrava `finish_reason`. Sem isso é impossível distinguir "o modelo
     terminou" de "o stream morreu no meio", e foi o que produziu um
     BENCHMARK_REPORT.md afirmando "Issues: None detected" para um index.html
     cortado no meio de uma tag <rect>.

  3. Aquecia o prompt cache com o MESMO prompt que ia medir, e depois reportava
     o TTFT do cache hit como se fosse prefill real.

Ver docs/diagnostico-linux-benchmark.md para a análise completa.
"""

from __future__ import annotations

import json
import statistics
import subprocess
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field, asdict
from typing import Any, Dict, List, Optional


# ─── resultado de uma requisição ────────────────────────────────────────────────

@dataclass
class GenResult:
    """Uma geração, com a procedência de cada número explícita.

    `metrics_source` diz se os tok/s vieram do servidor ou de estimativa do
    cliente. Nenhum relatório deve agregar as duas coisas sem dizer qual é qual.
    """

    ok: bool
    content: str = ""

    # Modelos com reasoning (Qwen3.6, DeepSeek-R1 e afins) emitem os tokens de
    # pensamento em `delta.reasoning_content`, NÃO em `delta.content`. Eles
    # consomem max_tokens igual, mas não aparecem na resposta.
    #
    # É por isso que o qwen27b (sem `--reasoning off` no perfil) entregou um
    # index.html de 12 KB cortado, enquanto o perfil `moe` (com `--reasoning
    # off`) entregou 27 KB completos: o raciocínio comeu a cota. O pipeline
    # antigo só lia `content`, então esse gasto era invisível.
    reasoning: str = ""
    reasoning_chars: int = 0

    # Vindos de `timings` do llama.cpp. None quando o servidor não mandou.
    prompt_tokens: Optional[int] = None
    gen_tokens: Optional[int] = None
    prefill_rate: Optional[float] = None
    gen_rate: Optional[float] = None
    metrics_source: str = "none"          # "server" | "client-estimate" | "none"

    # Medidos pelo cliente — sempre válidos.
    ttft: Optional[float] = None
    total_time: float = 0.0

    # Como a geração terminou. É isso que detecta truncagem.
    finish_reason: Optional[str] = None   # "stop" | "length" | None
    truncated: bool = False
    error: Optional[str] = None

    # Tool calls estruturadas, remontadas dos deltas do stream. Os perfis do
    # llm-server.sh declaram `tools|sim` e nada nunca validou isso. Um modelo que
    # descreve a chamada em prosa em vez de emitir a estrutura é inútil dentro de
    # um loop agêntico, e só este campo distingue os dois casos.
    tool_calls: List[Dict[str, Any]] = field(default_factory=list)

    def summary(self) -> str:
        if not self.ok:
            return f"ERRO: {self.error}"
        flag = ""
        if self.truncated:
            flag = "  ⚠️ TRUNCADO"
        elif self.finish_reason is None:
            flag = "  ⚠️ stream terminou sem finish_reason"
        rate = f"{self.gen_rate:.1f}" if self.gen_rate is not None else "?"
        toks = self.gen_tokens if self.gen_tokens is not None else "?"
        ttft = f"{self.ttft:.2f}s" if self.ttft is not None else "?"
        # A fração gasta em reasoning é decisiva: explica truncagem sem que o
        # modelo tenha "falhado".
        think = ""
        if self.reasoning_chars:
            total = self.reasoning_chars + len(self.content)
            pct = 100.0 * self.reasoning_chars / total if total else 0.0
            think = f" | reasoning {pct:.0f}% da saída"
        return (f"TTFT {ttft} | {rate} tok/s | {toks} tok | "
                f"{self.total_time:.1f}s | fim={self.finish_reason}{think}{flag}")


# ─── cliente HTTP com streaming instrumentado ───────────────────────────────────

class InferenceClient:
    def __init__(self, server_url: str, api_key: str = "local",
                 read_timeout: float = 1800.0, idle_timeout: float = 180.0):
        """
        read_timeout: teto absoluto por requisição. O antigo era 300s, o que a
            2.7 tok/s não cobre nem uma geração de 800 tokens.
        idle_timeout: silêncio máximo tolerado ENTRE tokens. É esta a métrica que
            distingue "modelo lento" de "stream morto" — um teto absoluto alto
            sozinho só faz o script travar por meia hora antes de falhar.
        """
        self.server_url = server_url
        self.api_key = api_key
        self.read_timeout = read_timeout
        self.idle_timeout = idle_timeout

    def generate(self, prompt: str, max_tokens: int = 512,
                 temperature: float = 0.2,
                 extra_body: Optional[Dict[str, Any]] = None) -> GenResult:
        payload: Dict[str, Any] = {
            "model": "local",
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens,
            "temperature": temperature,
            "stream": True,
            # Faz o llama.cpp incluir `timings` no chunk final. É a diferença
            # entre medir e chutar.
            "timings_per_token": True,
            "stream_options": {"include_usage": True},
        }
        if extra_body:
            payload.update(extra_body)

        req = urllib.request.Request(
            self.server_url,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json",
                     "Authorization": f"Bearer {self.api_key}"},
        )

        res = GenResult(ok=False)
        chunks: List[str] = []
        reasoning_chunks: List[str] = []
        tool_call_parts: Dict[int, Dict[str, Any]] = {}
        t0 = time.time()
        first_token_at: Optional[float] = None
        last_chunk_at = t0
        timings: Dict[str, Any] = {}
        usage: Dict[str, Any] = {}
        saw_done = False

        try:
            with urllib.request.urlopen(req, timeout=self.read_timeout) as resp:
                for raw in resp:
                    now = time.time()
                    if now - last_chunk_at > self.idle_timeout:
                        raise TimeoutError(
                            f"stream ocioso por {now - last_chunk_at:.0f}s "
                            f"(limite {self.idle_timeout:.0f}s)")
                    last_chunk_at = now

                    line = raw.decode("utf-8", errors="replace").strip()
                    if not line.startswith("data: "):
                        continue          # linhas de ping SSE (": ping") caem aqui
                    body = line[6:].strip()
                    if body == "[DONE]":
                        saw_done = True
                        break
                    try:
                        chunk = json.loads(body)
                    except json.JSONDecodeError:
                        continue

                    # `timings` e `usage` chegam no chunk final e são a fonte de
                    # verdade dos tok/s.
                    if isinstance(chunk.get("timings"), dict):
                        timings = chunk["timings"]
                    if isinstance(chunk.get("usage"), dict):
                        usage = chunk["usage"]

                    for choice in chunk.get("choices") or []:
                        delta = choice.get("delta") or {}
                        piece = delta.get("content")
                        think = delta.get("reasoning_content")
                        # TTFT conta o primeiro token de QUALQUER tipo — o
                        # usuário espera pelo primeiro token, não pelo primeiro
                        # token de conteúdo.
                        if (piece or think) and first_token_at is None:
                            first_token_at = time.time()
                        if piece:
                            chunks.append(piece)
                        if think:
                            reasoning_chunks.append(think)
                        # Tool calls chegam fatiadas: `name` num chunk, os
                        # `arguments` acumulados em vários. Precisam ser
                        # remontadas por índice.
                        for tc in delta.get("tool_calls") or []:
                            idx = tc.get("index", 0)
                            slot = tool_call_parts.setdefault(
                                idx, {"id": None,
                                      "function": {"name": None, "arguments": ""}})
                            if tc.get("id"):
                                slot["id"] = tc["id"]
                            fn = tc.get("function") or {}
                            if fn.get("name"):
                                slot["function"]["name"] = fn["name"]
                            if fn.get("arguments"):
                                slot["function"]["arguments"] += fn["arguments"]
                        if choice.get("finish_reason"):
                            res.finish_reason = choice["finish_reason"]

            res.ok = True

        except (urllib.error.URLError, TimeoutError, OSError,
                json.JSONDecodeError) as exc:
            res.error = f"{type(exc).__name__}: {exc}"
        except Exception as exc:                       # noqa: BLE001
            res.error = f"{type(exc).__name__}: {exc}"

        t_end = time.time()
        res.content = "".join(chunks)
        res.reasoning = "".join(reasoning_chunks)
        res.reasoning_chars = len(res.reasoning)
        res.tool_calls = [tool_call_parts[k] for k in sorted(tool_call_parts)]
        res.total_time = t_end - t0
        if first_token_at is not None:
            res.ttft = first_token_at - t0

        # Preferir sempre o número do servidor. Só cair na estimativa se ele não
        # veio — e nesse caso dizer isso em voz alta no campo metrics_source.
        if timings:
            res.prompt_tokens = timings.get("prompt_n")
            res.gen_tokens = timings.get("predicted_n")
            res.prefill_rate = timings.get("prompt_per_second")
            res.gen_rate = timings.get("predicted_per_second")
            res.metrics_source = "server"
        elif usage:
            res.prompt_tokens = usage.get("prompt_tokens")
            res.gen_tokens = usage.get("completion_tokens")
            res.metrics_source = "server"
            gen_window = (t_end - first_token_at) if first_token_at else res.total_time
            if res.gen_tokens and gen_window > 0:
                res.gen_rate = res.gen_tokens / gen_window
        elif res.content or res.reasoning:
            # Último recurso. Marcado como estimativa para não contaminar
            # comparações entre modelos sem que ninguém perceba. Soma reasoning
            # porque ele também consome a cota de max_tokens.
            res.gen_tokens = max((len(res.content) + res.reasoning_chars) // 4, 1)
            res.metrics_source = "client-estimate"
            gen_window = (t_end - first_token_at) if first_token_at else res.total_time
            if gen_window > 0:
                res.gen_rate = res.gen_tokens / gen_window

        # Truncagem: `length` é o servidor batendo em max_tokens. Stream que
        # acabou sem [DONE] e sem finish_reason é conexão morta — igualmente
        # truncado, e é o caso que passava batido antes.
        if res.finish_reason == "length":
            res.truncated = True
        elif res.ok and not saw_done and res.finish_reason is None:
            res.truncated = True
            res.error = res.error or "stream encerrou sem [DONE] nem finish_reason"
        elif not res.ok:
            res.truncated = True

        return res


# ─── monitor de hardware ────────────────────────────────────────────────────────

class RemoteHardwareMonitor:
    """Amostra GPU, RAM e swap por UMA sessão SSH persistente.

    A versão anterior abria uma conexão SSH nova por segundo na máquina que
    estava sendo medida. Numa máquina com 900 MiB livres, o handshake e o fork
    competem com o que se quer medir: o instrumento contaminava a leitura.

    Aqui um único `ssh` roda um loop remoto que emite uma linha CSV por segundo.
    RAM e swap entram porque para MoE com experts na CPU elas são o limite real,
    e o relatório antigo simplesmente não as tinha.
    """

    REMOTE_LOOP = (
        'while true; do '
        '  gpu=$(nvidia-smi --query-gpu=memory.used,utilization.gpu,power.draw '
        '        --format=csv,noheader,nounits 2>/dev/null | head -1); '
        '  mem=$(free -m | awk \'/^Mem:/{print $3","$7} /^Swap:/{print $3}\' | paste -sd,); '
        '  echo "$gpu,$mem"; '
        '  sleep 1; '
        'done'
    )

    def __init__(self, remote_host: str, ssh_key: str):
        self.remote_host = remote_host
        self.ssh_key = ssh_key
        self._proc: Optional[subprocess.Popen] = None
        self._thread: Optional[threading.Thread] = None
        self._running = False
        self.samples: List[Dict[str, float]] = []
        self._lock = threading.Lock()

    def start(self) -> None:
        with self._lock:
            self.samples = []
        self._running = True
        self._proc = subprocess.Popen(
            ["ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes",
             "-i", self.ssh_key, self.remote_host, self.REMOTE_LOOP],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
        )
        self._thread = threading.Thread(target=self._read_loop, daemon=True)
        self._thread.start()

    def _read_loop(self) -> None:
        assert self._proc and self._proc.stdout
        for line in self._proc.stdout:
            if not self._running:
                break
            parts = [p.strip() for p in line.strip().split(",")]
            if len(parts) < 6:
                continue
            try:
                sample = {
                    "vram_gb": float(parts[0]) / 1024.0,
                    "gpu_util": float(parts[1]),
                    "power_w": float(parts[2]),
                    "ram_used_gb": float(parts[3]) / 1024.0,
                    "ram_avail_gb": float(parts[4]) / 1024.0,
                    "swap_used_gb": float(parts[5]) / 1024.0,
                }
            except (ValueError, IndexError):
                continue
            with self._lock:
                self.samples.append(sample)

    def stop(self) -> Dict[str, Any]:
        self._running = False
        if self._proc:
            self._proc.terminate()
            try:
                self._proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self._proc.kill()
        if self._thread:
            self._thread.join(timeout=3)

        with self._lock:
            samples = list(self.samples)

        if not samples:
            return {"samples": 0, "warning": "nenhuma amostra de hardware coletada"}

        def peak(key: str) -> float:
            return round(max(s[key] for s in samples), 2)

        def mean(key: str) -> float:
            return round(statistics.fmean(s[key] for s in samples), 1)

        return {
            "samples": len(samples),
            "peak_vram_gb": peak("vram_gb"),
            "avg_gpu_util": mean("gpu_util"),
            "avg_power_w": mean("power_w"),
            "peak_ram_used_gb": peak("ram_used_gb"),
            "min_ram_avail_gb": round(min(s["ram_avail_gb"] for s in samples), 2),
            "peak_swap_used_gb": peak("swap_used_gb"),
        }


# ─── estatística que não mente sobre o próprio n ────────────────────────────────

def describe(values: List[float], label: str = "") -> Dict[str, Any]:
    """Estatística descritiva com o `n` sempre visível.

    Não há percentil aqui de propósito. A versão anterior reportava "P95" sobre
    4 amostras — com n=4, ceil(0.95*4)-1 = 3, ou seja, o índice do máximo. A
    coluna "Geração P95" do dashboard era literalmente o máximo, rotulada como
    percentil. Percentil só entra a partir de n >= 20, e aí explicitamente.
    """
    clean = [v for v in values if v is not None]
    if not clean:
        return {"n": 0, "label": label}

    out: Dict[str, Any] = {
        "n": len(clean),
        "label": label,
        "median": round(statistics.median(clean), 2),
        "mean": round(statistics.fmean(clean), 2),
        "min": round(min(clean), 2),
        "max": round(max(clean), 2),
        "stdev": round(statistics.stdev(clean), 2) if len(clean) > 1 else 0.0,
    }
    if len(clean) >= 20:
        out["p95"] = round(statistics.quantiles(clean, n=20)[-1], 2)
    else:
        out["p95"] = None
        out["p95_note"] = f"n={len(clean)} é pouco para percentil; precisa de 20+"
    return out


def result_to_dict(res: GenResult) -> Dict[str, Any]:
    d = asdict(res)
    # Conteúdo e raciocínio vão para arquivo, não para o JSON do relatório.
    d.pop("content", None)
    d.pop("reasoning", None)
    d["content_chars"] = len(res.content)
    total = len(res.content) + res.reasoning_chars
    d["reasoning_share"] = round(res.reasoning_chars / total, 3) if total else 0.0
    return d
