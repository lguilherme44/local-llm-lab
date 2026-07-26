#!/usr/bin/env python3
"""Testa se um modelo servido em MLX faz tool calling utilizável de verdade.

Não basta emitir uma chamada: um agente precisa do ciclo completo —
pedir a ferramenta, receber o resultado, e usar o resultado na resposta.

Uso: test-tools.py <repo-do-modelo> [porta]
"""
import json
import sys
import time
import urllib.error
import urllib.request

MODEL = sys.argv[1]
PORT = sys.argv[2] if len(sys.argv) > 2 else "8080"
URL = f"http://127.0.0.1:{PORT}/v1/chat/completions"

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
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=1200) as r:
            return json.load(r), time.time() - t0
    except urllib.error.HTTPError as e:
        print(f"  HTTP {e.code}: {e.read().decode()[:300]}")
        sys.exit(1)


print(f"\n=== {MODEL} (porta {PORT}) ===")

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
