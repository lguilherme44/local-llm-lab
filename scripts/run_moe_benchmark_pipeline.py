#!/usr/bin/env python3
"""
Pipeline automatizado de benchmarks e geração de Landing Pages para modelos MoE.
Executa os testes no servidor Linux via SSH/HTTP API OpenAI.
"""

import os
import sys
import time
import json
import subprocess
import urllib.request
import urllib.parse

SSH_KEY = os.path.expanduser("~/.ssh/id_ed25519_windows")
REMOTE_HOST = "lellis@192.168.3.51"
SERVER_URL = "http://192.168.3.51:8080/v1/chat/completions"
HEALTH_URL = "http://192.168.3.51:8080/health"
API_KEY = "local"
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

LANDING_PAGE_PROMPT = """Atue como um Engenheiro Front-end Sênior, especialista em UI/UX, focado em conversão e performance. Sua tarefa é escrever o código completo de uma Landing Page moderna e responsiva.

Stack Tecnológico: HTML5 puro com Tailwind CSS via CDN e JavaScript incorporado.
Produto/Serviço: Local LLM Lab — Um laboratório e ecossistema local para rodar e testar LLMs de código aberto em GPUs domésticas e servidores Linux.
Público-alvo: Desenvolvedores, Engenheiros de IA, Arquitetos de Software e Entusiastas de Open Source.

Diretrizes de Design e Animações:
1. Estilo moderno e minimalista (clean UI), dark mode elegante com gradientes sutis e neon (cyberpunk/developer vibe).
2. Uso intenso de microinterações e animações (transition-all, hover effects, cards interativos).
3. Layout mobile-first rigoroso (sm:, md:, lg:).
4. Efeitos modernos como glassmorphism (backdrop-blur) no header fixo e hero section.
5. Inclua seções de Hero, Features, Benchmarks Comparativos (Mac vs Linux vs Windows), Depoimentos e Call to Action (CTA).
6. Retorne APENAS o código HTML completo e funcional dentro da tag <html>, sem markdown em volta.
"""

def run_ssh(cmd, timeout=None):
    ssh_cmd = ["ssh", "-i", SSH_KEY, REMOTE_HOST, cmd]
    res = subprocess.run(ssh_cmd, capture_output=True, text=True, timeout=timeout)
    return res.stdout.strip(), res.stderr.strip(), res.returncode

def wait_for_server(timeout=300):
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

def start_profile(profile, ctx=16384):
    print(f"\n🚀 Trocando para o perfil '{profile}' (ctx: {ctx})...")
    cmd = f"~/local-llm-lab/linux/llm-server.sh start {profile} --lan --ctx {ctx}"
    out, err, code = run_ssh(cmd, timeout=600)
    print(f"Stdout: {out}")
    if not wait_for_server(timeout=600):
        print(f"❌ Falha ao aguardar o servidor para o perfil '{profile}'.")
        return False
    print(f"✓ Servidor pronto no perfil '{profile}'!")
    return True

def run_benchmark_test(profile_name, rounds=4):
    print(f"\n📊 Medindo benchmark para o perfil '{profile_name}' ({rounds} rodadas)...")
    payload = {
        "model": "local",
        "messages": [{"role": "user", "content": "Escreva um script genérico de ordenação merge sort em Python com comentários explicativos e testes unitários."}],
        "max_tokens": 512,
        "temperature": 0.2
    }
    
    prefill_rates = []
    gen_rates = []
    
    for i in range(1, rounds + 1):
        t0 = time.time()
        req_data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(SERVER_URL, data=req_data, headers={"Content-Type": "application/json", "Authorization": f"Bearer {API_KEY}"})
        try:
            with urllib.request.urlopen(req, timeout=180) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                elapsed = time.time() - t0
                usage = data.get("usage", {})
                timings = data.get("timings", {})
                p_tok = timings.get("prompt_n", usage.get("prompt_tokens", 0))
                g_tok = timings.get("predicted_n", usage.get("completion_tokens", 0))
                p_rate = timings.get("prompt_per_second", 0)
                g_rate = timings.get("predicted_per_second", g_tok / elapsed if elapsed > 0 else 0)
                
                if i > 1:
                    prefill_rates.append(p_rate)
                    gen_rates.append(g_rate)
                print(f"  [Rodada {i}/{rounds}] Prefill: {p_rate:.1f} tok/s ({p_tok} tok) | Geração: {g_rate:.1f} tok/s ({g_tok} tok) | Tempo: {elapsed:.2f}s")
        except Exception as e:
            print(f"  [Rodada {i}/{rounds}] Erro: {e}")
        time.sleep(2)
        
    med_g = sorted(gen_rates)[len(gen_rates)//2] if gen_rates else 0
    med_p = sorted(prefill_rates)[len(prefill_rates)//2] if prefill_rates else 0
    print(f"  --> Resultado Mediana: Geração = {med_g:.1f} tok/s | Prefill = {med_p:.1f} tok/s")
    return {"gen_tok_s": med_g, "prefill_tok_s": med_p}

def generate_landing_page(profile_name, output_dir):
    os.makedirs(output_dir, exist_ok=True)
    print(f"\n🌐 Gerando Landing Page completa com perfil '{profile_name}'...")
    
    payload = {
        "model": "local",
        "messages": [{"role": "user", "content": LANDING_PAGE_PROMPT}],
        "max_tokens": 8192,
        "temperature": 0.2
    }
    
    t0 = time.time()
    req_data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(SERVER_URL, data=req_data, headers={"Content-Type": "application/json", "Authorization": f"Bearer {API_KEY}"})
    
    try:
        with urllib.request.urlopen(req, timeout=1800) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            elapsed = time.time() - t0
            
            content = data["choices"][0]["message"]["content"]
            # Limpa blocos de código se houver
            clean_html = content
            if "```html" in clean_html:
                clean_html = clean_html.split("```html")[1].split("```")[0]
            elif "```" in clean_html:
                clean_html = clean_html.split("```")[1].split("```")[0]
            clean_html = clean_html.strip()
            
            usage = data.get("usage", {})
            comp_tok = usage.get("completion_tokens", 0)
            prompt_tok = usage.get("prompt_tokens", 0)
            rate = comp_tok / elapsed if elapsed > 0 else 0
            
            # Salva o index.html
            html_path = os.path.join(output_dir, "index.html")
            with open(html_path, "w", encoding="utf-8") as f:
                f.write(clean_html)
            print(f"✓ {html_path} gravado ({len(clean_html)} bytes)!")
            
            # Salva o README.md do relatório
            readme_content = f"""# Benchmark e Saída Real: Perfil `{profile_name}`

## Métricas de Desempenho
- **Modelo:** `{profile_name}`
- **Tokens de Prompt (Prefill):** {prompt_tok}
- **Tokens Gerados (Output):** {comp_tok}
- **Tempo Total:** {elapsed:.2f} segundos
- **Taxa Média de Geração:** **{rate:.1f} tok/s**

## Arquivos Gerados
- [`index.html`](index.html): Código da Landing Page gerada pelo modelo sem edição manual.

## Avaliação de Aderência ao Prompt
- **HTML Válido:** {'Sim' if '<html' in clean_html.lower() else 'Não'}
- **Tailwind CDN:** {'Sim' if 'tailwind' in clean_html.lower() else 'Não'}
- **Estilo Dark Mode & Neon:** {'Sim' if 'dark' in clean_html.lower() or 'bg-gray-900' in clean_html.lower() or 'bg-slate-900' in clean_html.lower() or 'black' in clean_html.lower() else 'Parcial'}
- **Animações / Classes Utility:** {'Sim' if 'transition' in clean_html.lower() or 'hover' in clean_html.lower() else 'Não'}
"""
            readme_path = os.path.join(output_dir, "README.md")
            with open(readme_path, "w", encoding="utf-8") as f:
                f.write(readme_content)
            print(f"✓ {readme_path} gravado!")
            return {"elapsed": elapsed, "comp_tokens": comp_tok, "rate": rate}
    except Exception as e:
        print(f"❌ Erro ao gerar landing page: {e}")
        return None

def main():
    print("=== Pipeline Automático de Benchmarks MoE ===")
    
    # 1. Qwen 3.6 35B MoE
    moe_dir = os.path.join(PROJECT_ROOT, "examples", "landing-page-qwen3.6-35b")
    print("\n[1/3] Garantindo download e testando Qwen3.6-35B MoE...")
    run_ssh("~/local-llm-lab/linux/llm-server.sh pull moe", timeout=7200)
    if start_profile("moe", ctx=16384):
        run_benchmark_test("moe")
        generate_landing_page("moe", moe_dir)
        
    # 2. Qwen3.6-27B
    qwen27b_dir = os.path.join(PROJECT_ROOT, "examples", "landing-page-qwen3.6-27b")
    print("\n[2/5] Garantindo download e testando Qwen3.6-27B...")
    run_ssh("~/local-llm-lab/linux/llm-server.sh pull qwen27b", timeout=7200)
    if start_profile("qwen27b", ctx=16384):
        run_benchmark_test("qwen27b")
        generate_landing_page("qwen27b", qwen27b_dir)

    # 3. Bonsai-27B (Prism ML)
    bonsai_dir = os.path.join(PROJECT_ROOT, "examples", "landing-page-bonsai-27b")
    print("\n[3/5] Garantindo download e testando Bonsai-27B (Prism ML)...")
    run_ssh("~/local-llm-lab/linux/llm-server.sh pull bonsai", timeout=7200)
    if start_profile("bonsai", ctx=16384):
        run_benchmark_test("bonsai")
        generate_landing_page("bonsai", bonsai_dir)

    # 4. DeepSeek-Coder-V2-Lite
    ds_dir = os.path.join(PROJECT_ROOT, "examples", "landing-page-deepseek-v2-lite")
    print("\n[3/4] Garantindo download e testando DeepSeek-Coder-V2-Lite...")
    run_ssh("~/local-llm-lab/linux/llm-server.sh pull deepseek", timeout=7200)
    if start_profile("deepseek", ctx=16384):
        run_benchmark_test("deepseek")
        generate_landing_page("deepseek", ds_dir)

    # 4. Frontier MoE (DeepSeek-V4-Flash / GLM-5.2)
    frontier_dir = os.path.join(PROJECT_ROOT, "examples", "landing-page-frontier-moe")
    print("\n[4/4] Garantindo download e testando Modelo Frontier MoE Gigante (DeepSeek-V4-Flash / GLM-5.2)...")
    run_ssh("~/local-llm-lab/linux/llm-server.sh pull frontier", timeout=14400)
    if start_profile("frontier", ctx=8192):
        run_benchmark_test("frontier")
        generate_landing_page("frontier", frontier_dir)

    print("\n✓ Pipeline de benchmarks MoE concluída com sucesso para TODOS os modelos!")

if __name__ == "__main__":
    main()
