#!/usr/bin/env python3
"""Testa se um modelo servido faz tool calling utilizável de verdade.

Não basta emitir uma chamada: um agente precisa do ciclo completo —
pedir a ferramenta, receber o resultado, e usar o resultado na resposta.

Serve para os dois lados do lab: mlx_lm.server (macOS) e llama-server (Windows).
Em single-model mode do llama.cpp, <modelo> é o ALIAS de -a, não o repo do HF.

Uso: test-tools.py <modelo> [porta]

  LLM_HOST     host do servidor (padrão 127.0.0.1) — use para testar outra máquina
  LLM_API_KEY  chave enviada em Authorization (padrão 'local'; vazio omite o header)

Exemplos:
  test-tools.py mlx-community/Qwen3-8B-4bit
  LLM_HOST=192.168.3.51 test-tools.py agent
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

MODEL = sys.argv[1]
PORT = sys.argv[2] if len(sys.argv) > 2 else "8080"
HOST = os.environ.get("LLM_HOST") or "127.0.0.1"
API_KEY = os.environ.get("LLM_API_KEY", "local")
URL = f"http://{HOST}:{PORT}/v1/chat/completions"

HEADERS = {"Content-Type": "application/json"}
if API_KEY:
    # O llama-server recusa sem o header quando sobe com --api-key; o
    # mlx_lm.server ignora. Mandar sempre é inofensivo e evita 401 confuso.
    HEADERS["Authorization"] = f"Bearer {API_KEY}"

TOOLS = [{
    "type": "function",
    "function": {
        "name": "read_file",
        "description": "Lê o conteúdo de um arquivo do disco.",
        "parameters": {
            "type": "object",
            "properties": {"path": {"type": "string", "description": "caminho do arquivo"}},
            "required": ["path"],
        },
    },
}]


def post(messages, tools=TOOLS, max_tokens=400):
    body = {"model": MODEL, "messages": messages, "max_tokens": max_tokens}
    if tools:
        body["tools"] = tools
    req = urllib.request.Request(URL, data=json.dumps(body).encode(),
                                 headers=HEADERS)
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=1200) as r:
            return json.load(r), time.time() - t0
    except urllib.error.HTTPError as e:
        print(f"  HTTP {e.code}: {e.read().decode()[:300]}")
        sys.exit(1)


print(f"\n=== {MODEL} ({HOST}:{PORT}) ===")

# ── Turno 1: o modelo deve PEDIR a ferramenta ────────────────────────────────
msgs = [{"role": "user", "content": "Leia o arquivo config.json e me diga o que tem nele."}]
d, dt = post(msgs)
m = d["choices"][0]["message"]
calls = m.get("tool_calls")

print(f"\n[turno 1 · {dt:.1f}s]")
if calls:
    print("  ✓ tool_calls ESTRUTURADO")
    for c in calls:
        fn = c.get("function", {})
        print(f"    -> {fn.get('name')}({fn.get('arguments')})")
        print(f"       id={c.get('id')}")
else:
    print("  ✗ tool_calls: null  (agente NÃO funciona)")
    print(f"    content: {(m.get('content') or '')[:220]!r}")
    sys.exit(2)

# ── Turno 2: devolvemos o resultado e o modelo deve USÁ-LO ───────────────────
call = calls[0]
msgs.append({"role": "assistant", "content": m.get("content") or "", "tool_calls": calls})
msgs.append({
    "role": "tool",
    "tool_call_id": call.get("id"),
    "content": '{"name": "meu-projeto", "version": "3.1.4", "license": "MIT"}',
})
d2, dt2 = post(msgs, tools=None)
answer = (d2["choices"][0]["message"].get("content") or "").strip()

print(f"\n[turno 2 · {dt2:.1f}s]")
print(f"  resposta: {answer[:300]}")

used = "3.1.4" in answer or "meu-projeto" in answer
print(f"\n  {'✓' if used else '✗'} usou o resultado da ferramenta na resposta")

u = d2.get("usage") or {}
n = u.get("completion_tokens")
if n:
    print(f"  geração: {n/dt2:.1f} tok/s")

print(f"\n{'APROVADO — serve como agente' if used else 'REPROVADO — pede a tool mas ignora o retorno'}")
sys.exit(0 if used else 3)
