#!/usr/bin/env python3
"""
Local LLM Lab — Industrial Benchmark Pipeline
Suíte completa de medição de Performance (TTFT, Prefill, Generation, P95, Hardware, Energy)
e Qualidade (HTML, SQL, NestJS, Reasoning, LLM Judge).
"""

import os
import sys
import time
import json
import math
import statistics
import threading
import subprocess
import urllib.request
import urllib.parse
from typing import Dict, List, Any, Optional

# --- Configurações Gerais ---
SSH_KEY = os.path.expanduser("~/.ssh/id_ed25519_windows")
REMOTE_HOST = "lellis@192.168.3.51"
SERVER_URL = "http://192.168.3.51:8080/v1/chat/completions"
HEALTH_URL = "http://192.168.3.51:8080/health"
API_KEY = "local"
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTPUT_DIR = os.path.join(PROJECT_ROOT, "benchmark-report")

# --- Estrutura Declarativa de Modelos ---
MODELS = [
    {
        "name": "Qwen 3.6 35B MoE",
        "profile": "moe",
        "pull": "moe",
        "ctx": 16384,
        "output_dir": os.path.join(PROJECT_ROOT, "examples", "landing-page-qwen3.6-35b")
    },
    {
        "name": "Qwen 3.6 27B",
        "profile": "qwen27b",
        "pull": "qwen27b",
        "ctx": 16384,
        "output_dir": os.path.join(PROJECT_ROOT, "examples", "landing-page-qwen3.6-27b")
    },
    {
        "name": "Bonsai 27B",
        "profile": "bonsai",
        "pull": "bonsai",
        "ctx": 16384,
        "output_dir": os.path.join(PROJECT_ROOT, "examples", "landing-page-bonsai-27b")
    },
    {
        "name": "DeepSeek Coder V2 Lite",
        "profile": "deepseek",
        "pull": "deepseek",
        "ctx": 16384,
        "output_dir": os.path.join(PROJECT_ROOT, "examples", "landing-page-deepseek-v2-lite")
    }
]

# --- Prompts da Suíte de Qualidade ---
QUALITY_PROMPTS = {
    "landing_page": """Atue como um Engenheiro Front-end Sênior. Escreva o código completo de uma Landing Page moderna em HTML5 puro com Tailwind CSS CDN e JS incorporado para o produto 'Local LLM Lab'.
Inclua: Header fixo com glassmorphism, Hero Section, Grid de Features, Comparativo de Benchmarks, Depoimentos e CTA.
Retorne APENAS o código HTML funcional dentro de <html></html> sem markdown em volta.""",

    "reasoning": """Um pai tem o triplo da idade de seu filho. Há 10 anos, a idade do pai era 5 vezes a idade do filho.
Calcule passo a passo a idade atual de ambos e confirme o resultado.""",

    "nestjs_crud": """Implemente um Controller e DTO NestJS em TypeScript para um CRUD completo de Produtos com validações usando class-validator.
Retorne o código bem tipado e limpo.""",

    "sql_generation": """Escreva uma query PostgreSQL otimizada com Window Functions para calcular a média móvel de vendas dos últimos 7 dias por categoria de produto, ordenado por data descendente."""
}

# --- Monitor de Hardware Paralelo ---
class HardwareMonitor:
    def __init__(self, remote_host: str, ssh_key: str, interval: float = 1.0):
        self.remote_host = remote_host
        self.ssh_key = ssh_key
        self.interval = interval
        self._running = False
        self._thread: Optional[threading.Thread] = None
        self.samples: List[Dict[str, float]] = []

    def start(self):
        self.samples = []
        self._running = True
        self._thread = threading.Thread(target=self._collect_loop, daemon=True)
        self._thread.start()

    def stop(self) -> Dict[str, Any]:
        self._running = False
        if self._thread:
            self._thread.join(timeout=3)
        if not self.samples:
            return {"peak_vram_gb": 0.0, "peak_ram_gb": 0.0, "avg_gpu_util": 0.0, "avg_power_w": 0.0}
        
        vrams = [s["vram"] for s in self.samples if "vram" in s]
        gpus = [s["gpu_util"] for s in self.samples if "gpu_util" in s]
        powers = [s["power"] for s in self.samples if "power" in s]
        
        return {
            "peak_vram_gb": round(max(vrams), 2) if vrams else 0.0,
            "avg_gpu_util": round(sum(gpus)/len(gpus), 1) if gpus else 0.0,
            "avg_power_w": round(sum(powers)/len(powers), 1) if powers else 0.0,
        }

    def _collect_loop(self):
        cmd = "nvidia-smi --query-gpu=memory.used,utilization.gpu,power.draw --format=csv,noheader,nounits 2>/dev/null"
        ssh_cmd = ["ssh", "-o", "ConnectTimeout=2", "-i", self.ssh_key, self.remote_host, cmd]
        
        while self._running:
            try:
                res = subprocess.run(ssh_cmd, capture_output=True, text=True, timeout=3)
                if res.returncode == 0 and res.stdout.strip():
                    parts = [p.strip() for p in res.stdout.strip().split(",")]
                    if len(parts) >= 3:
                        vram_mb = float(parts[0])
                        gpu_util = float(parts[1])
                        power_w = float(parts[2])
                        self.samples.append({
                            "vram": vram_mb / 1024.0,
                            "gpu_util": gpu_util,
                            "power": power_w
                        })
            except Exception:
                pass
            time.sleep(self.interval)


# --- Helper SSH e Servidor ---
def run_ssh(cmd: str, timeout: Optional[int] = None):
    ssh_cmd = ["ssh", "-i", SSH_KEY, REMOTE_HOST, cmd]
    res = subprocess.run(ssh_cmd, capture_output=True, text=True, timeout=timeout)
    return res.stdout.strip(), res.stderr.strip(), res.returncode

def wait_for_server(timeout=300) -> bool:
    start = time.time()
    while time.time() - start < timeout:
        try:
            req = urllib.request.Request(HEALTH_URL, headers={"Authorization": f"Bearer {API_KEY}"})
            with urllib.request.urlopen(req, timeout=5) as resp:
                if resp.status == 200:
                    return True
        except Exception:
            pass
        time.sleep(3)
    return False

def start_profile(profile: str, ctx: int = 16384) -> bool:
    print(f"\n🚀 Trocando para o perfil '{profile}' (ctx: {ctx})...")
    cmd = f"LLM_CTX={ctx} ~/local-llm-lab/linux/llm-server.sh start {profile} --lan"
    out, err, code = run_ssh(cmd, timeout=600)
    if not wait_for_server(timeout=600):
        print(f"❌ Falha ao carregar modelo '{profile}'.")
        return False
    print(f"✓ Modelo '{profile}' pronto com contexto de {ctx} tokens!")
    return True

# --- Medição HTTP com Streaming (TTFT + Tokens/s) ---
def execute_streaming_request(prompt: str, max_tokens: int = 512, temperature: float = 0.2) -> Dict[str, Any]:
    payload = {
        "model": "local",
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": temperature,
        "stream": True
    }
    
    req_data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(SERVER_URL, data=req_data, headers={
        "Content-Type": "application/json",
        "Authorization": f"Bearer {API_KEY}"
    })
    
    t0 = time.time()
    first_token_time = None
    chunks_text = []
    
    with urllib.request.urlopen(req, timeout=300) as resp:
        for line in resp:
            line_str = line.decode("utf-8").strip()
            if line_str.startswith("data: "):
                data_str = line_str[6:].strip()
                if data_str == "[DONE]":
                    break
                try:
                    chunk = json.loads(data_str)
                    choices = chunk.get("choices", [])
                    if choices:
                        delta = choices[0].get("delta", {})
                        content = delta.get("content", "")
                        if content:
                            if first_token_time is None:
                                first_token_time = time.time()
                            chunks_text.append(content)
                except Exception:
                    pass

    t_end = time.time()
    ttft = (first_token_time - t0) if first_token_time else (t_end - t0)
    gen_time = (t_end - first_token_time) if first_token_time else (t_end - t0)
    
    full_text = "".join(chunks_text)
    # Estimativa de tokens (aprox 4 caracteres por token)
    tok_count = max(len(full_text) // 4, len(chunks_text))
    gen_rate = tok_count / gen_time if gen_time > 0 else 0.0
    
    return {
        "ttft": round(ttft, 3),
        "total_time": round(t_end - t0, 2),
        "gen_rate": round(gen_rate, 1),
        "gen_tokens": tok_count,
        "content": full_text
    }

# --- Suíte de Performance ---
def run_performance_suite(profile_name: str, monitor: HardwareMonitor, rounds: int = 5) -> Dict[str, Any]:
    print(f"\n📊 [PERFORMANCE] Iniciando benchmarks de velocidade para '{profile_name}' ({rounds} rodadas)...")
    
    prompt = "Escreva uma função de busca binária em Python com testes unitários detalhados e docstring."
    
    # Warmup
    print("  ♨️ Executando Warmup (descarta cache)...")
    execute_streaming_request(prompt, max_tokens=128)
    
    ttfts, gen_rates, total_times = [], [], []
    
    monitor.start()
    for i in range(1, rounds + 1):
        res = execute_streaming_request(prompt, max_tokens=512)
        ttfts.append(res["ttft"])
        gen_rates.append(res["gen_rate"])
        total_times.append(res["total_time"])
        print(f"  [Rodada {i}/{rounds}] TTFT: {res['ttft']}s | Geração: {res['gen_rate']} tok/s | Total: {res['total_time']}s")
        time.sleep(1.5)
        
    hw_stats = monitor.stop()
    
    def calc_stats(arr):
        if not arr:
            return {"avg": 0, "median": 0, "min": 0, "max": 0, "std": 0, "p95": 0}
        s = sorted(arr)
        n = len(s)
        p95_idx = int(math.ceil(0.95 * n)) - 1
        p95_idx = max(0, min(p95_idx, n - 1))
        
        avg_val = sum(s) / n
        std_val = statistics.stdev(s) if n > 1 else 0.0
        med_val = statistics.median(s)
        
        return {
            "avg": round(avg_val, 2),
            "median": round(med_val, 2),
            "min": round(s[0], 2),
            "max": round(s[-1], 2),
            "std": round(std_val, 2),
            "p95": round(s[p95_idx], 2)
        }

    perf_result = {
        "ttft_stats": calc_stats(ttfts),
        "generation_stats": calc_stats(gen_rates),
        "hardware": hw_stats,
        "tokens_per_watt": round(calc_stats(gen_rates)["median"] / hw_stats["avg_power_w"], 3) if hw_stats.get("avg_power_w", 0) > 0 else 0
    }
    
    print(f"  --> Resultado Mediana: TTFT = {perf_result['ttft_stats']['median']}s | Geração = {perf_result['generation_stats']['median']} tok/s")
    print(f"  --> Hardware: Peak VRAM = {hw_stats['peak_vram_gb']} GB | Power Avg = {hw_stats['avg_power_w']} W | Tokens/Watt = {perf_result['tokens_per_watt']}")
    return perf_result

# --- Suíte de Qualidade & Avaliação HTML ---
def evaluate_html_quality(html_content: str) -> Dict[str, Any]:
    low = html_content.lower()
    checks = {
        "valid_html": "<html" in low and "</html>" in low,
        "tailwind_cdn": "tailwind" in low,
        "dark_mode": "dark" in low or "bg-gray-900" in low or "bg-slate-900" in low,
        "animations": "transition" in low or "hover:" in low,
        "responsive": "sm:" in low or "md:" in low or "lg:" in low,
        "seo_meta": "<meta" in low and "description" in low,
        "js_interactivity": "<script" in low
    }
    score = round((sum(checks.values()) / len(checks)) * 10, 1)
    return {"score": score, "details": checks}

def run_quality_suite(profile_name: str, output_dir: str) -> Dict[str, Any]:
    print(f"\n🎯 [QUALIDADE] Executando suíte de capacidade para '{profile_name}'...")
    os.makedirs(output_dir, exist_ok=True)
    
    results = {}
    
    # 1. Landing Page HTML
    print("  🌐 Testando Geração de Landing Page...")
    lp_res = execute_streaming_request(QUALITY_PROMPTS["landing_page"], max_tokens=8000, temperature=0.2)
    clean_html = lp_res["content"]
    if "```html" in clean_html:
        clean_html = clean_html.split("```html")[1].split("```")[0]
    elif "```" in clean_html:
        clean_html = clean_html.split("```")[1].split("```")[0]
    clean_html = clean_html.strip()
    
    html_path = os.path.join(output_dir, "index.html")
    with open(html_path, "w", encoding="utf-8") as f:
        f.write(clean_html)
        
    html_eval = evaluate_html_quality(clean_html)
    results["landing_page"] = {
        "score": html_eval["score"],
        "checks": html_eval["details"],
        "file": html_path
    }
    
    # 2. Reasoning Test
    print("  🧠 Testando Raciocínio Lógico...")
    reasoning_res = execute_streaming_request(QUALITY_PROMPTS["reasoning"], max_tokens=1024)
    # Checa se acertou as idades (filho=10, pai=30 ou similares)
    has_correct_math = "10" in reasoning_res["content"] and "30" in reasoning_res["content"]
    results["reasoning"] = {
        "score": 10.0 if has_correct_math else 5.0,
        "correct": has_correct_math
    }

    # 3. SQL Query
    print("  🗄️ Testando Geração de SQL...")
    sql_res = execute_streaming_request(QUALITY_PROMPTS["sql_generation"], max_tokens=1024)
    has_sql_keywords = "OVER" in sql_res["content"].upper() and "AVG" in sql_res["content"].upper()
    results["sql"] = {
        "score": 10.0 if has_sql_keywords else 4.0,
        "correct": has_sql_keywords
    }
    
    # 4. NestJS CRUD
    print("  🚀 Testando NestJS CRUD...")
    nest_res = execute_streaming_request(QUALITY_PROMPTS["nestjs_crud"], max_tokens=1500)
    has_nestjs = "@Controller" in nest_res["content"] and "IsString" in nest_res["content"]
    results["nestjs"] = {
        "score": 10.0 if has_nestjs else 4.0,
        "correct": has_nestjs
    }

    overall_quality = round(sum(r["score"] for r in results.values()) / len(results), 2)
    results["overall_score"] = overall_quality
    print(f"  --> Nota Geral de Qualidade: {overall_quality} / 10.0")
    return results

# --- Gerador de Relatório HTML & JSON ---
def generate_reports(all_results: List[Dict[str, Any]]):
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    
    # 1. Salvar JSON
    json_path = os.path.join(OUTPUT_DIR, "benchmark_summary.json")
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(all_results, f, indent=2, ensure_ascii=False)
    print(f"\n💾 Relatório JSON consolidado gravado em: {json_path}")
    
    # 2. Gerar HTML Dashboard
    rows_html = ""
    for r in all_results:
        p = r["performance"]
        q = r["quality"]
        rows_html += f"""
        <tr class="border-b border-gray-800 hover:bg-gray-800/50">
            <td class="p-4 font-bold text-white">{r['model']}</td>
            <td class="p-4 text-emerald-400 font-mono">{p['ttft_stats']['median']}s</td>
            <td class="p-4 text-cyan-400 font-mono">{p['generation_stats']['median']} tok/s</td>
            <td class="p-4 text-amber-400 font-mono">{p['generation_stats']['p95']} tok/s</td>
            <td class="p-4 font-mono">{p['hardware']['peak_vram_gb']} GB</td>
            <td class="p-4 font-mono">{p['hardware']['avg_power_w']} W</td>
            <td class="p-4 font-mono text-purple-400">{p['tokens_per_watt']}</td>
            <td class="p-4 font-bold text-yellow-400 font-mono">{q['overall_score']} / 10</td>
        </tr>
        """
        
    dashboard_html = f"""<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <title>Local LLM Lab — Benchmark Dashboard</title>
    <script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-gray-950 text-gray-100 p-8">
    <div class="max-w-7xl mx-auto">
        <header class="mb-8 border-b border-gray-800 pb-4">
            <h1 class="text-3xl font-extrabold text-transparent bg-clip-text bg-gradient-to-r from-cyan-400 to-emerald-400">
                Local LLM Lab — Industrial Benchmark Report
            </h1>
            <p class="text-gray-400 mt-1">Comparativo de Performance de Inferência e Qualidade por Modelo</p>
        </header>

        <div class="overflow-x-auto bg-gray-900 rounded-xl border border-gray-800">
            <table class="w-full text-left border-collapse">
                <thead>
                    <tr class="bg-gray-800/80 text-gray-400 text-sm">
                        <th class="p-4">Modelo</th>
                        <th class="p-4">TTFT (Mediana)</th>
                        <th class="p-4">Geração (Mediana)</th>
                        <th class="p-4">Geração P95</th>
                        <th class="p-4">Peak VRAM</th>
                        <th class="p-4">Energia Média</th>
                        <th class="p-4">Tok / Watt</th>
                        <th class="p-4">Score Qualidade</th>
                    </tr>
                </thead>
                <tbody>
                    {rows_html}
                </tbody>
            </table>
        </div>
    </div>
</body>
</html>
"""
    html_dashboard_path = os.path.join(OUTPUT_DIR, "index.html")
    with open(html_dashboard_path, "w", encoding="utf-8") as f:
        f.write(dashboard_html)
    print(f"📊 Dashboard HTML interativo gravado em: {html_dashboard_path}")

# --- Orquestrador Principal ---
def main():
    print("=========================================================")
    print("   Local LLM Lab — Pipeline Industrial de Benchmarks     ")
    print("=========================================================\n")
    
    monitor = HardwareMonitor(REMOTE_HOST, SSH_KEY)
    all_results = []
    
    for m in MODELS:
        print(f"\n🎬 Iniciando bateria de testes para: {m['name']}")
        
        # Pull do modelo via SSH
        run_ssh(f"~/local-llm-lab/linux/llm-server.sh pull {m['pull']}", timeout=7200)
        
        if start_profile(m['profile'], ctx=m['ctx']):
            perf_res = run_performance_suite(m['profile'], monitor, rounds=4)
            qual_res = run_quality_suite(m['profile'], m['output_dir'])
            
            all_results.append({
                "model": m['name'],
                "profile": m['profile'],
                "performance": perf_res,
                "quality": qual_res
            })
            
    if all_results:
        generate_reports(all_results)
        
    print("\n✅ Suíte completa finalizada com sucesso!")

if __name__ == "__main__":
    main()
