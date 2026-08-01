#!/usr/bin/env python3
"""Testa se um modelo servido ENTREGA uma feature, não só se chama ferramenta.

O test-tools.py responde "o modelo sabe pedir uma ferramenta e usar o retorno?".
Este responde a pergunta seguinte, que é a que decide se vale trabalhar com ele:
"o modelo consegue ler código existente, editá-lo e fazer a suíte passar?"

A diferença importa porque as duas medidas discordam. Medido nesta bancada: o
Qwen3-8B passa no test-tools.py, gera 3x mais rápido que o Qwen3-Coder-30B-A3B
e MESMO ASSIM não termina a tarefa — reescreve o arquivo seis vezes sem ver o
próprio bug. Velocidade de token não é velocidade de trabalho.

O critério de sucesso não é opinião nem heurística de texto: é o pytest.

A tarefa: um `Cache` aceita `ttl` em set() e `default_ttl` no construtor, mas
ignora os dois. Seis testes cobrem a expiração e falham. O modelo tem de
implementar o TTL. É pequena de propósito — cabe no contexto de 16k que os
perfis locais usam — mas exige o que uma feature real exige: ler o que existe,
entender o contrato pelos testes, editar e verificar.

`test_cache.py` é somente leitura no harness. Sem isso o caminho mais curto
para o verde é apagar os testes, e já vimos modelo tentar.

Uso: test-feature.py <modelo> [--host IP] [--port 8080] [--max-turnos N]

  LLM_HOST     host do servidor (padrão 127.0.0.1)
  LLM_API_KEY  chave enviada em Authorization (padrão 'local'; vazio omite)

Exemplos:
  test-feature.py moe --host 192.168.3.51
  LLM_HOST=192.168.3.51 scripts/test-feature.py agent

Requer pytest no MESMO interpretador que roda este script (ele chama
sys.executable -m pytest). Sem pytest:  uv run --with pytest scripts/test-feature.py ...
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

# ── o projeto semente ────────────────────────────────────────────────────────
# Embutido em vez de guardado em fixtures/: o harness inteiro cabe num arquivo,
# como o test-tools.py, e não há par de arquivos para sair de sincronia.
CACHE_PY = '''"""Cache em memória simples."""
import time


class Cache:
    """Guarda pares chave/valor em memória.

    Ainda não expira nada: um valor gravado fica para sempre.
    """

    def __init__(self, default_ttl=None):
        self._data = {}
        self.default_ttl = default_ttl

    def set(self, key, value, ttl=None):
        self._data[key] = value

    def get(self, key, default=None):
        return self._data.get(key, default)

    def delete(self, key):
        self._data.pop(key, None)

    def __len__(self):
        return len(self._data)
'''

# Os seis testes não são decorativos. Cada um pega um erro que modelos locais
# cometem de verdade nesta tarefa:
#   permanece            -> a condição invertida que apaga o que NÃO tem TTL
#   expira               -> o caso feliz
#   ttl_padrao           -> ignorar o default_ttl do construtor
#   explicito_vence      -> `ttl or self.default_ttl`, que quebra com ttl=0
#   len_nao_conta        -> esquecer o __len__
#   default_quando_expirado -> devolver None em vez do default pedido
TEST_CACHE_PY = '''import time

from cache import Cache


def test_valor_sem_ttl_permanece():
    c = Cache()
    c.set("a", 1)
    time.sleep(0.05)
    assert c.get("a") == 1


def test_valor_expira_apos_o_ttl():
    c = Cache()
    c.set("a", 1, ttl=0.05)
    assert c.get("a") == 1
    time.sleep(0.08)
    assert c.get("a") is None


def test_ttl_padrao_do_construtor_vale_para_todos():
    c = Cache(default_ttl=0.05)
    c.set("a", 1)
    time.sleep(0.08)
    assert c.get("a") is None


def test_ttl_explicito_vence_o_padrao():
    c = Cache(default_ttl=0.01)
    c.set("a", 1, ttl=5)
    time.sleep(0.05)
    assert c.get("a") == 1


def test_len_nao_conta_expirados():
    c = Cache()
    c.set("a", 1, ttl=0.05)
    c.set("b", 2)
    time.sleep(0.08)
    assert len(c) == 1


def test_get_devolve_o_default_quando_expirado():
    c = Cache()
    c.set("a", 1, ttl=0.05)
    time.sleep(0.08)
    assert c.get("a", "vazio") == "vazio"
'''

TAREFA = """Neste diretório há `cache.py` e `test_cache.py`.

A suíte `test_cache.py` está falhando: o `Cache` aceita um parâmetro `ttl` em
`set()` e um `default_ttl` no construtor, mas ignora os dois — nada expira.

Implemente a expiração por TTL em `cache.py` para que TODOS os testes passem.
Não altere `test_cache.py`.

Trabalhe assim: leia os dois arquivos, escreva o `cache.py` corrigido, e rode
os testes para conferir. Se falharem, corrija e rode de novo."""

TOOLS = [
    {"type": "function", "function": {
        "name": "list_files",
        "description": "Lista os arquivos do diretório de trabalho.",
        "parameters": {"type": "object", "properties": {}}}},
    {"type": "function", "function": {
        "name": "read_file",
        "description": "Lê um arquivo e devolve o conteúdo.",
        "parameters": {"type": "object",
                       "properties": {"path": {"type": "string"}},
                       "required": ["path"]}}},
    {"type": "function", "function": {
        "name": "write_file",
        "description": "Grava conteúdo num arquivo, substituindo o que havia.",
        "parameters": {"type": "object",
                       "properties": {"path": {"type": "string"},
                                      "content": {"type": "string"}},
                       "required": ["path", "content"]}}},
    {"type": "function", "function": {
        "name": "run_tests",
        "description": "Roda a suíte de testes e devolve a saída do pytest.",
        "parameters": {"type": "object", "properties": {}}}},
]


def rodar_pytest(wd):
    p = subprocess.run([sys.executable, "-m", "pytest", "-q", "--no-header", "-x"],
                       cwd=wd, capture_output=True, text=True, timeout=120)
    return p.returncode == 0, (p.stdout + p.stderr)[-1800:]


def executar(nome, args, wd):
    """Executa a ferramenta pedida. Nunca levanta: o erro volta como texto para
    o modelo, que é o que um harness de agente de verdade faz — modelo local
    precisa poder se recuperar de um caminho errado sem derrubar a sessão."""
    try:
        if nome == "list_files":
            return "\n".join(sorted(os.listdir(wd)))
        if nome == "read_file":
            # basename() prende tudo ao diretório de trabalho: o modelo não sai
            # daqui nem por engano nem por criatividade.
            with open(os.path.join(wd, os.path.basename(args["path"]))) as f:
                return f.read()
        if nome == "write_file":
            alvo = os.path.basename(args["path"])
            if alvo == "test_cache.py":
                return "ERRO: test_cache.py é somente leitura."
            with open(os.path.join(wd, alvo), "w") as f:
                f.write(args["content"])
            return f"gravado: {alvo} ({len(args['content'])} bytes)"
        if nome == "run_tests":
            ok, saida = rodar_pytest(wd)
            return ("TODOS OS TESTES PASSARAM\n" if ok else "AINDA FALHANDO\n") + saida
        return f"ferramenta desconhecida: {nome}"
    except Exception as e:
        return f"ERRO: {type(e).__name__}: {e}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("modelo", help="alias do perfil (single-model mode) ou repo")
    ap.add_argument("--host", default=os.environ.get("LLM_HOST") or "127.0.0.1")
    ap.add_argument("--port", default="8080")
    # 14 turnos é generoso: quem entrega resolve em 2 ou 3. O teto existe para
    # o teste terminar quando o modelo entra em laço de reescrita — que é um
    # resultado, não um travamento.
    ap.add_argument("--max-turnos", type=int, default=14)
    ap.add_argument("--manter", action="store_true",
                    help="não apaga o diretório de trabalho ao final")
    a = ap.parse_args()

    api_key = os.environ.get("LLM_API_KEY", "local")
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    url = f"http://{a.host}:{a.port}/v1/chat/completions"

    wd = tempfile.mkdtemp(prefix=f"feature-{a.modelo.replace('/', '_')}-")
    with open(os.path.join(wd, "cache.py"), "w") as f:
        f.write(CACHE_PY)
    with open(os.path.join(wd, "test_cache.py"), "w") as f:
        f.write(TEST_CACHE_PY)

    print(f"\n=== {a.modelo} ({a.host}:{a.port}) ===")
    ok_inicial, _ = rodar_pytest(wd)
    if ok_inicial:
        # Semente passando significa harness quebrado, não modelo genial.
        print("ERRO: a semente já passa. O teste não mede nada assim.")
        sys.exit(1)
    print("semente falhando, como esperado\n")

    msgs = [{"role": "user", "content": TAREFA}]
    t0 = time.time()
    chamadas = {}
    tokens = 0
    turno = 0

    for turno in range(1, a.max_turnos + 1):
        body = json.dumps({"model": a.modelo, "messages": msgs, "tools": TOOLS,
                           "max_tokens": 2000, "temperature": 0}).encode()
        req = urllib.request.Request(url, data=body, headers=headers)
        ti = time.time()
        try:
            with urllib.request.urlopen(req, timeout=3600) as r:
                d = json.load(r)
        except urllib.error.HTTPError as e:
            print(f"[{turno}] HTTP {e.code}: {e.read().decode()[:300]}")
            break
        except Exception as e:
            print(f"[{turno}] ERRO: {type(e).__name__}: {e}")
            break
        dt = time.time() - ti
        tokens += d.get("usage", {}).get("completion_tokens", 0)

        m = d["choices"][0]["message"]
        msgs.append(m)
        tc = m.get("tool_calls") or []

        if not tc:
            txt = (m.get("content") or "").strip()
            print(f"[{turno}] {dt:6.1f}s  parou sem chamar ferramenta")
            if txt:
                print(f"          {txt[:200]}")
            else:
                # content vazio + tool_calls nulo é a assinatura do raciocínio
                # comendo a cota de max_tokens. Veja docs/06-troubleshooting.md.
                print("          content vazio — faltou --reasoning off?")
            break

        for c in tc:
            fn = c["function"]["name"]
            chamadas[fn] = chamadas.get(fn, 0) + 1
            try:
                fargs = json.loads(c["function"]["arguments"] or "{}")
            except json.JSONDecodeError:
                print(f"[{turno}] {dt:6.1f}s  {fn}  <- ARGUMENTS NÃO É JSON")
                msgs.append({"role": "tool", "tool_call_id": c["id"],
                             "content": "ERRO: arguments não é JSON válido"})
                continue
            res = executar(fn, fargs, wd)
            marca = ""
            if fn == "run_tests":
                marca = "  VERDE" if res.startswith("TODOS") else "  vermelho"
            print(f"[{turno}] {dt:6.1f}s  {fn}{marca}")
            msgs.append({"role": "tool", "tool_call_id": c["id"], "content": res})

        if any(c["function"]["name"] == "run_tests" for c in tc):
            ok, _ = rodar_pytest(wd)
            if ok:
                break

    elapsed = time.time() - t0
    ok_final, saida = rodar_pytest(wd)

    print(f"\n{'APROVADO — entregou a feature' if ok_final else 'REPROVADO — nao entregou'}")
    print(f"  tempo {elapsed:.0f}s · turnos {turno} · tokens gerados {tokens}")
    print(f"  chamadas: {chamadas}")
    if not ok_final:
        print("\n--- pytest ---")
        print(saida[-700:])

    if a.manter:
        print(f"\ndiretorio mantido: {wd}")
    else:
        shutil.rmtree(wd, ignore_errors=True)

    sys.exit(0 if ok_final else 1)


if __name__ == "__main__":
    main()
