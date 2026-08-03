#!/usr/bin/env python3
"""
Suíte de tarefas objetivas para avaliar modelo local como assistente de código.

Por que a suíte anterior não servia
-----------------------------------
O objetivo declarado é "programar, entregar features e corrigir bugs, qualidade
importa mais que velocidade". A suíte antiga media geração de landing page com
notas por presença de substring:

    "dark_mode": "dark" in low or "bg-gray-900" in low
    has_correct_math = "10" in content and "30" in content   # o prompt já dizia "10 anos"

Um HTML truncado que não parseia tirava 8.6/10. E landing page mede geração
longa de boilerplate memorizado, sem contexto de entrada e sem tool calling —
quase o oposto de "corrigir bug em código existente".

O que esta suíte mede
---------------------
Cinco eixos, todos com veredito binário verificável por máquina. Nenhum juiz
subjetivo, nenhuma contagem de palavra-chave:

  bugfix       o patch faz o teste que estava vermelho passar? (roda pytest)
  patch_format o diff/search-replace APLICA limpo? (é onde agentes locais morrem)
  tool_call    emite tool call válida, com nome certo e argumentos parseáveis?
  long_context acha um fato enterrado em ~7k tokens de código real?
  instruction  respeita "responda APENAS o JSON com este schema"?

Cada tarefa devolve PASS/FAIL mais o motivo. Score é taxa de acerto, não média
de notas inventadas.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional


# ─── contrato ───────────────────────────────────────────────────────────────────

@dataclass
class Grade:
    passed: bool
    reason: str
    detail: str = ""


@dataclass
class Task:
    key: str
    axis: str                       # bugfix | patch_format | tool_call | long_context | instruction
    prompt: str
    grader: Callable[[str], Grade]
    max_tokens: int = 2048
    # Reasoning models gastam a cota pensando. Tarefas que exigem saída longa
    # precisam de folga, senão o `finish_reason=length` mede o orçamento em vez
    # de medir o modelo. Ver docs/diagnostico-linux-benchmark.md 1.5.
    extra_body: Dict[str, Any] = field(default_factory=dict)


# ─── utilitários de extração ────────────────────────────────────────────────────

def extract_code_block(text: str, lang: Optional[str] = None) -> str:
    """Pega o conteúdo do primeiro bloco cercado. Tolerante, mas não criativo.

    Se o modelo não usar bloco algum, devolve o texto inteiro — deixar o grader
    falhar honestamente é melhor que adivinhar.
    """
    if lang:
        m = re.search(rf"```{lang}\s*\n(.*?)```", text, re.DOTALL | re.IGNORECASE)
        if m:
            return m.group(1)
    m = re.search(r"```[a-zA-Z0-9_+-]*\s*\n(.*?)```", text, re.DOTALL)
    return m.group(1) if m else text


def extract_json(text: str) -> Optional[Any]:
    """Tenta JSON puro; depois bloco cercado; depois o primeiro objeto balanceado."""
    for candidate in (text.strip(), extract_code_block(text, "json").strip()):
        try:
            return json.loads(candidate)
        except (json.JSONDecodeError, ValueError):
            pass
    start = text.find("{")
    if start == -1:
        return None
    depth, in_str, esc = 0, False, False
    for i in range(start, len(text)):
        ch = text[i]
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                try:
                    return json.loads(text[start:i + 1])
                except (json.JSONDecodeError, ValueError):
                    return None
    return None


def run_python(files: Dict[str, str], command: List[str],
               timeout: int = 60) -> subprocess.CompletedProcess:
    """Escreve os arquivos num diretório temporário e roda o comando lá.

    Código gerado por modelo é executado aqui. Contido num tempdir descartável e
    com timeout, porque um modelo pequeno gerando loop infinito é ocorrência
    normal, não excepcional.
    """
    with tempfile.TemporaryDirectory(prefix="llmbench-") as tmp:
        root = Path(tmp)
        for name, content in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        return subprocess.run(
            command, cwd=root, capture_output=True, text=True,
            timeout=timeout, env={"PATH": "/usr/bin:/bin", "HOME": tmp},
        )


# Runner em stdlib puro, sem pytest.
#
# Não é preciosismo: um harness de benchmark que depende de pacote externo falha
# na próxima máquina, e o modo de falha é indistinguível de "o modelo errou".
# Aconteceu na primeira execução destes graders — `No module named pytest` foi
# contabilizado como resposta errada do modelo. Falso negativo é o pior defeito
# possível num avaliador.
TEST_RUNNER = '''\
import sys, traceback
import test_solution as t

falhas = []
for nome in sorted(n for n in dir(t) if n.startswith("test_")):
    try:
        getattr(t, nome)()
    except Exception:
        falhas.append(f"{nome}:\\n{traceback.format_exc()}")

if falhas:
    print("\\n".join(falhas))
    sys.exit(1)
print(f"OK - todos os testes passaram")
'''


def run_asserts(solution: str, tests: str, timeout: int = 60) -> Grade:
    """Roda `tests` contra `solution` e devolve o veredito.

    Distingue três coisas que a suíte antiga confundia num único FAIL:
    erro de import/sintaxe, asserção falhando, e timeout.
    """
    try:
        proc = run_python(
            {"solution.py": solution,
             "test_solution.py": tests,
             "_runner.py": TEST_RUNNER},
            [sys.executable, "_runner.py"], timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return Grade(False, f"estourou o timeout de {timeout}s "
                            "(provável loop infinito)")
    if proc.returncode == 0:
        return Grade(True, "todos os testes passaram")
    saida = (proc.stdout + proc.stderr).strip()
    if "SyntaxError" in saida:
        return Grade(False, "código não compila (SyntaxError)", detail=saida[-600:])
    if "ImportError" in saida or "ModuleNotFoundError" in saida:
        return Grade(False, "erro de import", detail=saida[-600:])
    return Grade(False, "asserções falharam", detail=saida[-800:])


# ─── eixo 1: bug fix com teste falhando ─────────────────────────────────────────
#
# O eixo de maior valor: mede exatamente o objetivo declarado. O teste está
# vermelho, o modelo devolve a função corrigida, a gente roda o teste. Verde ou
# vermelho — sem juiz.

BUGGY_ROMAN = '''\
def to_roman(n):
    """Converte inteiro (1..3999) em numeral romano."""
    vals = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1]
    syms = ["M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I"]
    out = ""
    for v, s in zip(vals, syms):
        while n >= v:
            out += s
            n -= v
        break          # <-- bug: aborta na primeira iteração
    return out
'''

TEST_ROMAN = '''\
from solution import to_roman

def test_basico():
    assert to_roman(1) == "I"
    assert to_roman(4) == "IV"
    assert to_roman(9) == "IX"

def test_composto():
    assert to_roman(1994) == "MCMXCIV"
    assert to_roman(2024) == "MMXXIV"
    assert to_roman(3999) == "MMMCMXCIX"

def test_limites():
    assert to_roman(40) == "XL"
    assert to_roman(3888) == "MMMDCCCLXXXVIII"
'''


def _grade_bugfix_roman(response: str) -> Grade:
    code = extract_code_block(response, "python")
    if "def to_roman" not in code:
        return Grade(False, "resposta não contém `def to_roman`",
                     detail=response[:400])
    return run_asserts(code, TEST_ROMAN)


BUGFIX_ROMAN = Task(
    key="bugfix_roman",
    axis="bugfix",
    max_tokens=3072,
    prompt=f"""O teste abaixo está falhando. Corrija a função em `solution.py`.

```python
# solution.py
{BUGGY_ROMAN}```

```python
# test_solution.py
{TEST_ROMAN}```

Devolva APENAS o conteúdo corrigido de `solution.py` num único bloco ```python.
Não explique, não devolva o teste.""",
    grader=_grade_bugfix_roman,
)


BUGGY_MERGE = '''\
def merge_intervals(intervals):
    """Funde intervalos sobrepostos. Recebe lista de (inicio, fim)."""
    if not intervals:
        return []
    intervals = sorted(intervals)
    out = [intervals[0]]
    for start, end in intervals[1:]:
        last_start, last_end = out[-1]
        if start < last_end:            # <-- bug: intervalos que se tocam nao fundem
            out[-1] = (last_start, max(last_end, end))
        else:
            out.append((start, end))
    return out
'''

TEST_MERGE = '''\
from solution import merge_intervals

def test_vazio():
    assert merge_intervals([]) == []

def test_sem_sobreposicao():
    assert merge_intervals([(1, 2), (5, 6)]) == [(1, 2), (5, 6)]

def test_sobreposto():
    assert merge_intervals([(1, 4), (2, 6)]) == [(1, 6)]

def test_adjacente():
    # (1,3) e (3,5) se tocam e devem fundir em (1,5)
    assert merge_intervals([(1, 3), (3, 5)]) == [(1, 5)]

def test_desordenado_multiplo():
    assert merge_intervals([(5, 7), (1, 3), (2, 4), (8, 10), (9, 12)]) == [(1, 4), (5, 7), (8, 12)]
'''


def _grade_bugfix_merge(response: str) -> Grade:
    code = extract_code_block(response, "python")
    if "def merge_intervals" not in code:
        return Grade(False, "resposta não contém `def merge_intervals`",
                     detail=response[:400])
    return run_asserts(code, TEST_MERGE)


BUGFIX_MERGE = Task(
    key="bugfix_merge",
    axis="bugfix",
    max_tokens=3072,
    prompt=f"""O teste `test_adjacente` está falhando. Corrija `solution.py`.

```python
# solution.py
{BUGGY_MERGE}```

```python
# test_solution.py
{TEST_MERGE}```

Devolva APENAS o conteúdo corrigido de `solution.py` num único bloco ```python.""",
    grader=_grade_bugfix_merge,
)


# ─── eixo 2: aderência a formato de patch ───────────────────────────────────────
#
# É aqui que a maioria dos modelos locais morre como agente, e é invisível num
# teste de HTML. Um modelo que escreve código excelente mas não consegue emitir
# um patch aplicável é inútil dentro de um loop agêntico.

PATCH_TARGET = '''\
class Cache:
    def __init__(self, maxsize=128):
        self.maxsize = maxsize
        self.store = {}

    def get(self, key):
        return self.store.get(key)

    def put(self, key, value):
        self.store[key] = value

    def clear(self):
        self.store = {}
'''


def _grade_patch_format(response: str) -> Grade:
    """Valida que o SEARCH/REPLACE parseia E que o bloco SEARCH existe no arquivo.

    Aplicar de verdade é o teste: um patch cujo texto de busca não bate é
    exatamente o modo de falha que trava um agente na prática.
    """
    blocks = re.findall(
        r"<{5,9} SEARCH\s*\n(.*?)\n?={5,9}\s*\n(.*?)\n?>{5,9} REPLACE",
        response, re.DOTALL,
    )
    if not blocks:
        return Grade(False, "nenhum bloco SEARCH/REPLACE bem-formado encontrado",
                     detail=response[:500])

    current = PATCH_TARGET
    for i, (search, replace) in enumerate(blocks, 1):
        if search not in current:
            return Grade(False, f"bloco {i}: texto SEARCH não existe no arquivo",
                         detail=f"procurou:\n{search[:300]}")
        current = current.replace(search, replace, 1)

    # O patch aplicou. Agora: fez o que foi pedido?
    if "def size" not in current:
        return Grade(False, "patch aplicou, mas não adicionou o método `size`",
                     detail=current[:500])
    try:
        proc = run_python(
            {"solution.py": current,
             "t.py": ("from solution import Cache\n"
                      "c = Cache()\n"
                      "assert c.size() == 0\n"
                      "c.put('a', 1); c.put('b', 2)\n"
                      "assert c.size() == 2, c.size()\n"
                      "c.clear()\n"
                      "assert c.size() == 0\n"
                      "print('OK')\n")},
            [sys.executable, "t.py"], timeout=30,
        )
    except subprocess.TimeoutExpired:
        return Grade(False, "execução do arquivo patcheado estourou o timeout")
    if proc.returncode == 0:
        return Grade(True, f"{len(blocks)} bloco(s) aplicaram e `size` funciona")
    return Grade(False, "patch aplicou mas `size` não se comporta",
                 detail=(proc.stdout + proc.stderr)[-500:])


PATCH_FORMAT = Task(
    key="patch_format",
    axis="patch_format",
    max_tokens=2048,
    prompt=f"""Adicione um método `size()` à classe abaixo, que devolve a quantidade de itens no cache.

```python
# solution.py
{PATCH_TARGET}```

Responda EXCLUSIVAMENTE com um bloco de edição neste formato exato, sem nenhum texto ao redor:

<<<<<<< SEARCH
(as linhas exatas do arquivo original que serão substituídas)
=======
(as linhas novas)
>>>>>>> REPLACE

O texto entre SEARCH e ======= precisa ser idêntico, caractere a caractere, a um trecho do arquivo original.""",
    grader=_grade_patch_format,
)


# ─── eixo 3: tool calling ───────────────────────────────────────────────────────
#
# Os perfis do llm-server.sh declaram `tools|sim` e nada nunca validou essa
# afirmação. Um modelo que não emite tool call confiável não serve como agente,
# independente da qualidade do código que escreve.

TOOLS_SCHEMA = [{
    "type": "function",
    "function": {
        "name": "run_sql",
        "description": "Executa uma query SQL somente-leitura no banco de análise.",
        "parameters": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "A query SQL."},
                "limit": {"type": "integer", "description": "Máximo de linhas."},
            },
            "required": ["query"],
        },
    },
}]


def _grade_tool_call(response: str) -> Grade:
    """O grader real vive no pipeline, que tem acesso ao objeto tool_calls.

    Este fallback existe para o caso do servidor devolver a tool call embutida no
    texto — comportamento comum em modelo que não suporta tools de verdade, e que
    deve contar como FAIL: um agente não consegue consumir isso.
    """
    if "run_sql" in response:
        return Grade(False, "mencionou run_sql em texto livre, sem emitir tool_call "
                            "estruturada — inutilizável num loop agêntico",
                     detail=response[:400])
    return Grade(False, "nenhuma tool call emitida", detail=response[:400])


TOOL_CALL = Task(
    key="tool_call",
    axis="tool_call",
    max_tokens=1024,
    extra_body={"tools": TOOLS_SCHEMA, "tool_choice": "auto"},
    prompt="Quantos pedidos foram criados ontem? Use a ferramenta disponível para consultar o banco.",
    grader=_grade_tool_call,
)


def grade_tool_call_structured(tool_calls: Optional[List[Dict[str, Any]]]) -> Grade:
    """Grader de verdade: recebe o campo `tool_calls` da resposta."""
    if not tool_calls:
        return Grade(False, "campo tool_calls vazio ou ausente")
    call = tool_calls[0]
    fn = call.get("function") or {}
    name = fn.get("name")
    if name != "run_sql":
        return Grade(False, f"chamou função inexistente: {name!r}")
    raw_args = fn.get("arguments")
    try:
        args = json.loads(raw_args) if isinstance(raw_args, str) else raw_args
    except (json.JSONDecodeError, TypeError):
        return Grade(False, "arguments não é JSON válido", detail=str(raw_args)[:300])
    if not isinstance(args, dict) or not args.get("query"):
        return Grade(False, "faltou o parâmetro obrigatório `query`",
                     detail=str(args)[:300])
    if "select" not in str(args["query"]).lower():
        return Grade(False, "`query` não parece SQL", detail=str(args["query"])[:200])
    return Grade(True, f"tool call válida: run_sql({str(args['query'])[:60]}...)")


# ─── eixo 4: contexto longo ─────────────────────────────────────────────────────
#
# Com ctx 16384 e KV em f16 não havia margem para nem testar isso. Um agente que
# não lê o repo não corrige bug em código existente.

def _build_long_context() -> tuple[str, str]:
    """Gera ~6-7k tokens de código plausível com um fato único enterrado no meio."""
    secret = "RETRY_BACKOFF_CEILING_MS = 47300"
    chunks: List[str] = []
    for i in range(60):
        chunks.append(f'''\
# ─── módulo {i:02d} ─────────────────────────────────────────────
class Handler{i:02d}:
    """Processa eventos do canal {i:02d}."""

    DEFAULT_TIMEOUT_MS = {1000 + i * 37}

    def __init__(self, client, retries={i % 5 + 1}):
        self.client = client
        self.retries = retries

    def handle(self, event):
        for attempt in range(self.retries):
            try:
                return self.client.dispatch(event, timeout=self.DEFAULT_TIMEOUT_MS)
            except TimeoutError:
                continue
        raise RuntimeError("canal {i:02d} esgotou as tentativas")
''')
        if i == 33:
            chunks.append(f'''\
# ─── política de retry (config global) ────────────────────────
# Teto absoluto do backoff exponencial, em milissegundos.
{secret}
''')
    return "\n".join(chunks), secret


_LONG_CODE, _LONG_SECRET = _build_long_context()


def _grade_long_context(response: str) -> Grade:
    if "47300" in response.replace(".", "").replace(",", ""):
        return Grade(True, "achou o valor 47300")
    return Grade(False, "não achou o valor enterrado no contexto",
                 detail=response[:300])


LONG_CONTEXT = Task(
    key="long_context",
    axis="long_context",
    max_tokens=512,
    prompt=f"""Abaixo está um trecho de um código-base. Leia com atenção.

```python
{_LONG_CODE}```

Pergunta: qual é o valor de `RETRY_BACKOFF_CEILING_MS`?
Responda apenas o número, sem explicação.""",
    grader=_grade_long_context,
)


# ─── eixo 5: instrução restritiva ───────────────────────────────────────────────
#
# Se o modelo não consegue respeitar "APENAS o JSON", todo parsing na camada do
# agente vira heurística frágil. É pré-requisito de automação, não capricho.

_REQUIRED_KEYS = {"nome", "linguagem", "linhas", "tem_testes"}


def _grade_instruction(response: str) -> Grade:
    stripped = response.strip()
    # Exigência dura: a resposta INTEIRA precisa ser o JSON. Prosa em volta é
    # justamente o que quebra o parser do agente.
    strict_ok = stripped.startswith("{") and stripped.endswith("}")
    data = extract_json(response)
    if data is None:
        return Grade(False, "não foi possível extrair JSON", detail=response[:300])
    if not isinstance(data, dict):
        return Grade(False, f"JSON não é objeto, é {type(data).__name__}")
    missing = _REQUIRED_KEYS - set(data)
    if missing:
        return Grade(False, f"faltam chaves: {sorted(missing)}",
                     detail=json.dumps(data, ensure_ascii=False)[:300])
    if not isinstance(data.get("linhas"), int):
        return Grade(False, "`linhas` não é inteiro",
                     detail=repr(data.get("linhas")))
    if not isinstance(data.get("tem_testes"), bool):
        return Grade(False, "`tem_testes` não é booleano",
                     detail=repr(data.get("tem_testes")))
    if not strict_ok:
        return Grade(False, "JSON correto, mas embrulhado em texto/markdown — "
                            "viola 'APENAS o JSON'",
                     detail=stripped[:200])
    return Grade(True, "JSON puro e schema completo")


INSTRUCTION = Task(
    key="instruction_json",
    axis="instruction",
    max_tokens=1024,
    prompt="""Analise este arquivo e devolva os metadados.

```python
# parser.py — 3 funções, sem testes
def tokenize(src): ...
def parse(tokens): ...
def evaluate(ast): ...
```

Responda APENAS com um objeto JSON, sem markdown, sem crases, sem nenhuma
explicação antes ou depois. Chaves exatas:
  "nome"        string
  "linguagem"   string
  "linhas"      inteiro
  "tem_testes"  booleano""",
    grader=_grade_instruction,
)


# ─── registro ───────────────────────────────────────────────────────────────────

ALL_TASKS: List[Task] = [
    BUGFIX_ROMAN,
    BUGFIX_MERGE,
    PATCH_FORMAT,
    TOOL_CALL,
    LONG_CONTEXT,
    INSTRUCTION,
]

AXES = ["bugfix", "patch_format", "tool_call", "long_context", "instruction"]
