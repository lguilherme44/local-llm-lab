#!/usr/bin/env python3
"""
Testes dos graders. Rode com: python3 scripts/test_bench_tasks.py

Por que isto existe
-------------------
A suíte antiga pontuava qualidade por presença de substring e ninguém nunca
verificou se os checks funcionavam. Não funcionavam: um HTML truncado que não
parseava tirava 8.6/10, e o teste de raciocínio passava de graça porque o próprio
enunciado continha o número esperado.

Um avaliador não testado é tão confiável quanto os checks que ele substituiu.

Na primeira execução destes graders um deles deu FALSO NEGATIVO — marcou uma
solução correta como falha, porque `pytest` não estava instalado e o
`No module named pytest` foi contabilizado como erro do modelo. Falso negativo é
o pior defeito possível num benchmark: ele te faz descartar o modelo certo. Foi o
que motivou trocar o pytest por um runner de stdlib.

Cada grader é testado nas duas direções: aceita o que deve aceitar E rejeita o
que deve rejeitar.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import bench_tasks as T  # noqa: E402


_falhas: list[str] = []


def check(label: str, got: bool, want: bool) -> None:
    ok = got == want
    print(f"  {'✓' if ok else '✗ FALHOU'} {label}: passed={got} (esperado {want})")
    if not ok:
        _falhas.append(label)


# ─── fixtures ───────────────────────────────────────────────────────────────────

ROMAN_OK = '''```python
def to_roman(n):
    vals = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1]
    syms = ["M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I"]
    out = ""
    for v, s in zip(vals, syms):
        while n >= v:
            out += s
            n -= v
    return out
```'''

MERGE_OK = '''```python
def merge_intervals(intervals):
    if not intervals:
        return []
    intervals = sorted(intervals)
    out = [intervals[0]]
    for s, e in intervals[1:]:
        ls, le = out[-1]
        if s <= le:
            out[-1] = (ls, max(le, e))
        else:
            out.append((s, e))
    return out
```'''

PATCH_OK = '''<<<<<<< SEARCH
    def clear(self):
        self.store = {}
=======
    def clear(self):
        self.store = {}

    def size(self):
        return len(self.store)
>>>>>>> REPLACE'''

JSON_OK = '{"nome":"parser.py","linguagem":"Python","linhas":4,"tem_testes":false}'


# ─── casos ──────────────────────────────────────────────────────────────────────

def test_bugfix_roman() -> None:
    print("--- bugfix_roman")
    g = T.BUGFIX_ROMAN.grader
    check("solução correta", g(ROMAN_OK).passed, True)
    check("bug intacto", g("```python\n" + T.BUGGY_ROMAN + "```").passed, False)
    check("prosa sem código", g("O bug está no break").passed, False)
    check("syntax error", g("```python\ndef to_roman(n)\n  return\n```").passed, False)
    check("loop infinito",
          g("```python\ndef to_roman(n):\n    while True: pass\n```").passed, False)
    # Regressão do falso negativo: uma solução correta JAMAIS pode falhar por
    # dependência ausente do harness.
    assert g(ROMAN_OK).reason == "todos os testes passaram", \
        f"regressão do falso negativo: {g(ROMAN_OK).reason} / {g(ROMAN_OK).detail}"


def test_bugfix_merge() -> None:
    print("--- bugfix_merge")
    g = T.BUGFIX_MERGE.grader
    check("solução correta", g(MERGE_OK).passed, True)
    check("bug intacto", g("```python\n" + T.BUGGY_MERGE + "```").passed, False)
    check("nome de função errado",
          g("```python\ndef merge(x): return x\n```").passed, False)


def test_patch_format() -> None:
    print("--- patch_format")
    g = T.PATCH_FORMAT.grader
    check("patch válido", g(PATCH_OK).passed, True)
    check("SEARCH não bate",
          g(PATCH_OK.replace("self.store = {}", "self.cache = {}", 1)).passed, False)
    check("sem bloco de edição", g("basta adicionar def size").passed, False)
    check("bloco vazio", g("<<<<<<< SEARCH\n=======\n>>>>>>> REPLACE").passed, False)
    # Código solto em vez de patch é FAIL: um agente não consegue aplicar.
    check("devolveu arquivo inteiro",
          g("```python\n" + T.PATCH_TARGET +
            "\n    def size(self):\n        return len(self.store)\n```").passed, False)


def test_instruction() -> None:
    print("--- instruction_json")
    g = T.INSTRUCTION.grader
    check("JSON puro", g(JSON_OK).passed, True)
    check("JSON em markdown", g("Claro!\n```json\n" + JSON_OK + "\n```").passed, False)
    check("prosa antes", g("Aqui está: " + JSON_OK).passed, False)
    check("linhas como string",
          g('{"nome":"p","linguagem":"Python","linhas":"4","tem_testes":false}').passed, False)
    check("tem_testes como string",
          g('{"nome":"p","linguagem":"Python","linhas":4,"tem_testes":"no"}').passed, False)
    check("falta chave", g('{"nome":"p","linguagem":"Python","linhas":4}').passed, False)
    check("não é JSON", g("não sei responder").passed, False)


def test_long_context() -> None:
    print("--- long_context")
    g = T.LONG_CONTEXT.grader
    check("achou o valor", g("47300").passed, True)
    check("achou com pontuação", g("O valor é 47.300 ms").passed, True)
    check("valor errado", g("O valor é 1000").passed, False)
    check("não achou", g("não encontrei essa constante").passed, False)
    # O prompt precisa ser longo de verdade, senão não testa contexto longo.
    aprox = len(T.LONG_CONTEXT.prompt) // 4
    assert aprox > 5000, f"prompt de contexto longo tem só ~{aprox} tokens"
    print(f"  ✓ prompt tem ~{aprox} tokens")


def test_tool_call() -> None:
    print("--- tool_call")
    g = T.grade_tool_call_structured
    check("call válida",
          g([{"function": {"name": "run_sql",
                           "arguments": '{"query":"SELECT count(*) FROM pedidos"}'}}]).passed, True)
    check("arguments como dict",
          g([{"function": {"name": "run_sql",
                           "arguments": {"query": "SELECT 1"}}}]).passed, True)
    check("função inexistente",
          g([{"function": {"name": "query_db", "arguments": "{}"}}]).passed, False)
    check("arguments não-JSON",
          g([{"function": {"name": "run_sql", "arguments": "nope"}}]).passed, False)
    check("falta query",
          g([{"function": {"name": "run_sql", "arguments": '{"limit":10}'}}]).passed, False)
    check("query não é SQL",
          g([{"function": {"name": "run_sql", "arguments": '{"query":"ontem"}'}}]).passed, False)
    check("lista vazia", g([]).passed, False)
    check("None", g(None).passed, False)
    # Tool call em texto livre é FAIL — agente não consome.
    check("mencionou em prosa",
          T.TOOL_CALL.grader("Vou usar run_sql para consultar").passed, False)


def main() -> int:
    for fn in (test_bugfix_roman, test_bugfix_merge, test_patch_format,
               test_instruction, test_long_context, test_tool_call):
        fn()
    print()
    if _falhas:
        print(f"❌ {len(_falhas)} grader(s) com comportamento errado: {_falhas}")
        return 1
    print("✅ todos os graders se comportam como especificado")
    return 0


if __name__ == "__main__":
    sys.exit(main())
