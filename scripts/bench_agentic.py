#!/usr/bin/env python3
"""
Runner agêntico: o modelo recebe ferramentas, edita código e roda o teste.

Generaliza o `scripts/test-feature.py`, que já fazia o loop certo mas com uma
tarefa fixa embutida no próprio arquivo. Aqui a tarefa vem de um diretório em
`scripts/agentic_tasks/<nome>/` com um `task.json`, então adicionar tarefa é
copiar arquivos em vez de editar código.

Por que isto importa mais que a suíte single-shot
-------------------------------------------------
`run_benchmark.py` mede uma resposta e um grader. Trabalho real é multi-turno:
ler o repositório, editar, rodar o teste, ler o erro, corrigir. Um modelo pode
escrever bom código e ainda assim nunca fechar o ciclo — e o inverso também.

Regra que não pode ser afrouxada: o arquivo de teste é SOMENTE LEITURA. Sem
isso o caminho mais curto para o verde é apagar os testes, e já se viu modelo
tentar.

Uso:
    scripts/bench_agentic.py timeline_midnight --host 192.168.3.51
    scripts/bench_agentic.py timeline_midnight --repeats 3
    scripts/bench_agentic.py --listar
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional

TASKS_DIR = Path(__file__).parent / "agentic_tasks"


# ─── definição da tarefa ────────────────────────────────────────────────────────

@dataclass
class Task:
    key: str
    dir: Path
    prompt: str
    arquivo_alvo: str
    somente_leitura: List[str]
    comando_teste: List[str]
    origem: str = ""
    esperado_no_inicio: Dict[str, int] = field(default_factory=dict)
    # Regex com dois grupos (passaram, total) para extrair placar da saída do
    # teste. Sem isso o resultado é binário, e binário perde a informação que
    # mais importa: 3/5 -> 4/5 é progresso real e mensurável.
    regex_placar: str = ""

    @classmethod
    def carregar(cls, nome: str) -> "Task":
        d = TASKS_DIR / nome
        manifest = d / "task.json"
        if not manifest.exists():
            raise SystemExit(f"tarefa '{nome}' não tem task.json em {d}")
        cfg = json.loads(manifest.read_text(encoding="utf-8"))
        return cls(
            key=cfg.get("key", nome), dir=d, prompt=cfg["prompt"],
            arquivo_alvo=cfg["arquivo_alvo"],
            somente_leitura=cfg.get("somente_leitura", []),
            comando_teste=cfg["comando_teste"],
            origem=cfg.get("origem", ""),
            esperado_no_inicio=cfg.get("esperado_no_inicio", {}),
            regex_placar=cfg.get("regex_placar", ""),
        )


# ─── ferramentas expostas ao modelo ─────────────────────────────────────────────

def definir_tools() -> List[Dict[str, Any]]:
    def fn(nome: str, desc: str, props: Dict[str, Any],
           obrig: Optional[List[str]] = None) -> Dict[str, Any]:
        return {"type": "function", "function": {
            "name": nome, "description": desc,
            "parameters": {"type": "object", "properties": props,
                           "required": obrig or []}}}

    return [
        fn("list_files", "Lista os arquivos do diretório de trabalho.", {}),
        fn("read_file", "Lê o conteúdo de um arquivo.",
           {"path": {"type": "string", "description": "nome do arquivo"}}, ["path"]),
        fn("write_file", "Escreve o conteúdo completo de um arquivo.",
           {"path": {"type": "string"}, "content": {"type": "string"}},
           ["path", "content"]),
        fn("run_tests", "Roda a suíte de testes e devolve a saída.", {}),
    ]


class Workspace:
    """Diretório temporário com os arquivos da tarefa.

    Cópia por execução: uma tentativa nunca vê o que a anterior escreveu, que é
    o que torna `pass@k` uma medida honesta em vez de uma sequência dependente.
    """

    def __init__(self, task: Task):
        self.task = task
        self.dir = Path(tempfile.mkdtemp(prefix=f"agentic-{task.key}-"))
        for item in task.dir.iterdir():
            if item.is_file():
                shutil.copy2(item, self.dir / item.name)
        self.chamadas: Dict[str, int] = {}

    def limpar(self) -> None:
        shutil.rmtree(self.dir, ignore_errors=True)

    def placar(self, saida: str) -> Optional[tuple[int, int]]:
        if not self.task.regex_placar:
            return None
        m = re.search(self.task.regex_placar, saida)
        if not m:
            return None
        try:
            return int(m.group(1)), int(m.group(2))
        except (ValueError, IndexError):
            return None

    def rodar_testes(self) -> tuple[bool, str]:
        try:
            p = subprocess.run(self.task.comando_teste, cwd=self.dir,
                               capture_output=True, text=True, timeout=180)
        except subprocess.TimeoutExpired:
            return False, "TIMEOUT: a suíte não terminou em 180s"
        except FileNotFoundError as exc:
            return False, f"comando de teste não encontrado: {exc}"
        return p.returncode == 0, (p.stdout + p.stderr)[-2500:]

    def executar(self, nome: str, args: Dict[str, Any]) -> str:
        self.chamadas[nome] = self.chamadas.get(nome, 0) + 1
        try:
            if nome == "list_files":
                return "\n".join(sorted(p.name for p in self.dir.iterdir()))

            if nome == "read_file":
                alvo = self._resolver(args.get("path", ""))
                if alvo is None:
                    return "caminho fora do diretório de trabalho"
                if not alvo.exists():
                    return f"arquivo não existe: {args.get('path')}"
                return alvo.read_text(encoding="utf-8")

            if nome == "write_file":
                caminho = args.get("path", "")
                # A recusa é explícita e informativa de propósito: interessa
                # saber se o modelo TENTOU editar o teste, não só se conseguiu.
                if Path(caminho).name in self.task.somente_leitura:
                    return (f"NEGADO: '{caminho}' é somente leitura. "
                            f"Corrija {self.task.arquivo_alvo} em vez disso.")
                alvo = self._resolver(caminho)
                if alvo is None:
                    return "caminho fora do diretório de trabalho"
                conteudo = args.get("content")
                if not isinstance(conteudo, str):
                    return "parâmetro 'content' ausente ou não é string"
                alvo.write_text(conteudo, encoding="utf-8")
                return f"escrito: {caminho} ({len(conteudo)} chars)"

            if nome == "run_tests":
                ok, saida = self.rodar_testes()
                cab = "TODOS OS TESTES PASSARAM\n" if ok else "AINDA FALHANDO\n"
                return cab + saida

            return f"ferramenta desconhecida: {nome}"
        except Exception as exc:                             # noqa: BLE001
            return f"erro ao executar {nome}: {type(exc).__name__}: {exc}"

    def _resolver(self, rel: str) -> Optional[Path]:
        """Confina em self.dir. Resolve os dois lados antes de comparar.

        `startsWith` sobre string crua é a armadilha clássica (e foi um defeito
        real no harness removido): compara-se caminho resolvido com base
        resolvida, via relative_to, que não se engana com `..` nem com prefixo
        parecido (`/tmp/x` vs `/tmp/x-outro`).
        """
        try:
            alvo = (self.dir / rel).resolve()
            alvo.relative_to(self.dir.resolve())
            return alvo
        except (ValueError, OSError):
            return None


# ─── loop ───────────────────────────────────────────────────────────────────────

def uma_tentativa(task: Task, url: str, modelo: str, api_key: str,
                  max_turnos: int, verbose: bool, temperatura: float = 0.0,
                  manter: bool = False) -> Dict[str, Any]:
    ws = Workspace(task)
    inicio = time.time()
    resultado: Dict[str, Any] = {
        "passou": False, "turnos": 0, "tokens": 0, "chamadas": {},
        "tentou_editar_teste": False, "motivo": "", "verde_no_inicio": False,
        "placar_inicial": None, "placar_final": None,
    }

    try:
        # Guarda contra fixture podre: se a suíte já está verde, a tarefa não
        # mede nada e o "APROVADO" seria falso.
        ok_inicial, saida_inicial = ws.rodar_testes()
        resultado["placar_inicial"] = ws.placar(saida_inicial)
        if ok_inicial:
            resultado["verde_no_inicio"] = True
            resultado["motivo"] = ("a suíte já passa antes do modelo tocar em nada "
                                   "— fixture inválida")
            return resultado
        if "não encontrado" in saida_inicial or "TIMEOUT" in saida_inicial:
            resultado["motivo"] = f"não consegui rodar a suíte: {saida_inicial[:200]}"
            return resultado

        msgs: List[Dict[str, Any]] = [{"role": "user", "content": task.prompt}]
        tools = definir_tools()

        for turno in range(1, max_turnos + 1):
            resultado["turnos"] = turno
            corpo = json.dumps({"model": modelo, "messages": msgs, "tools": tools,
                                "tool_choice": "auto", "temperature": temperatura,
                                "max_tokens": 4096}).encode("utf-8")
            headers = {"Content-Type": "application/json"}
            if api_key:
                headers["Authorization"] = f"Bearer {api_key}"
            req = urllib.request.Request(url, data=corpo, headers=headers)

            t0 = time.time()
            try:
                with urllib.request.urlopen(req, timeout=900) as resp:
                    dados = json.loads(resp.read().decode("utf-8"))
            except (urllib.error.URLError, OSError, TimeoutError) as exc:
                resultado["motivo"] = f"falha na requisição: {exc}"
                return resultado

            resultado["tokens"] += (dados.get("usage") or {}).get("completion_tokens", 0)
            msg = (dados.get("choices") or [{}])[0].get("message") or {}
            msgs.append(msg)
            tc = msg.get("tool_calls") or []

            if not tc:
                # Sem tool call: o modelo respondeu em prosa. Só é sucesso se a
                # suíte estiver verde de fato — dizer "corrigi" não conta.
                ok, _ = ws.rodar_testes()
                resultado["passou"] = ok
                resultado["motivo"] = ("terminou sem chamar ferramenta; "
                                       f"suíte {'verde' if ok else 'vermelha'}")
                break

            for chamada in tc:
                fnome = (chamada.get("function") or {}).get("name", "")
                brutos = (chamada.get("function") or {}).get("arguments") or "{}"
                try:
                    fargs = json.loads(brutos) if isinstance(brutos, str) else brutos
                except json.JSONDecodeError:
                    fargs = {}
                saida = ws.executar(fnome, fargs if isinstance(fargs, dict) else {})
                if saida.startswith("NEGADO:"):
                    resultado["tentou_editar_teste"] = True
                if verbose:
                    print(f"  [{turno}] {time.time() - t0:5.1f}s  {fnome}"
                          f"{'  ← NEGADO' if saida.startswith('NEGADO:') else ''}")
                msgs.append({"role": "tool", "tool_call_id": chamada.get("id", ""),
                             "content": saida})

            if any((c.get("function") or {}).get("name") == "run_tests" for c in tc):
                ok, _ = ws.rodar_testes()
                if ok:
                    resultado["passou"] = True
                    resultado["motivo"] = "suíte verde"
                    break
        else:
            resultado["motivo"] = f"esgotou o teto de {max_turnos} turnos"

        resultado["chamadas"] = dict(ws.chamadas)
        resultado["tempo"] = round(time.time() - inicio, 1)
        return resultado
    finally:
        # Placar final medido SEMPRE, inclusive quando reprovou: é o que separa
        # "nao chegou perto" de "faltou uma correcao".
        try:
            _, saida_final = ws.rodar_testes()
            resultado["placar_final"] = ws.placar(saida_final)
        except Exception:                                    # noqa: BLE001
            pass
        resultado.setdefault("tempo", round(time.time() - inicio, 1))
        resultado["chamadas"] = dict(ws.chamadas)
        if manter:
            resultado["workspace"] = str(ws.dir)
        else:
            ws.limpar()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tarefa", nargs="?", help="nome do diretório em agentic_tasks/")
    ap.add_argument("--listar", action="store_true")
    ap.add_argument("--modelo", default="moe")
    ap.add_argument("--host", default=os.environ.get("LLM_HOST", "127.0.0.1"))
    ap.add_argument("--port", default="8080")
    ap.add_argument("--repeats", type=int, default=1)
    ap.add_argument("--max-turnos", type=int, default=14)
    # temperatura 0 dá reprodutibilidade de COMPORTAMENTO, que é o que se quer
    # ao comparar modelos. Mas com 0 as repeticoes saem identicas — as tres
    # primeiras execucoes desta tarefa deram 11115 tokens exatos as tres vezes.
    # pass@k exige amostragem, entao repeats > 1 com temp 0 nao mede nada novo.
    ap.add_argument("--temperature", type=float, default=0.0)
    ap.add_argument("--manter", action="store_true",
                    help="nao apaga o workspace, para inspecionar o que o modelo escreveu")
    ap.add_argument("-q", "--quiet", action="store_true")
    a = ap.parse_args()

    if a.listar or not a.tarefa:
        print("tarefas disponíveis:")
        for d in sorted(TASKS_DIR.iterdir()):
            if (d / "task.json").is_file():
                cfg = json.loads((d / "task.json").read_text(encoding="utf-8"))
                print(f"  {d.name:<24} {cfg.get('origem', '')[:70]}")
        return 0

    task = Task.carregar(a.tarefa)
    url = f"http://{a.host}:{a.port}/v1/chat/completions"
    api_key = os.environ.get("LLM_API_KEY", "local")

    print(f"=== {task.key} · {a.modelo} @ {a.host}:{a.port}")
    if task.origem:
        print(f"    origem: {task.origem}")
    print()

    if a.repeats > 1 and a.temperature == 0.0:
        print("⚠️  repeats > 1 com --temperature 0: as execucoes sairao IDENTICAS.")
        print("    Para pass@k de verdade use --temperature 0.6 ou mais.\n")

    execucoes: List[Dict[str, Any]] = []
    for i in range(1, a.repeats + 1):
        if a.repeats > 1:
            print(f"--- tentativa {i}/{a.repeats}")
        r = uma_tentativa(task, url, a.modelo, api_key, a.max_turnos,
                          verbose=not a.quiet, temperatura=a.temperature,
                          manter=a.manter)
        execucoes.append(r)
        marca = "APROVADO" if r["passou"] else "REPROVADO"
        extra = "  ⚠️ tentou editar o teste" if r["tentou_editar_teste"] else ""
        print(f"  {marca} — {r['motivo']}{extra}")
        pi, pf = r.get("placar_inicial"), r.get("placar_final")
        if pi and pf:
            seta = "→" if pi != pf else "="
            print(f"  testes: {pi[0]}/{pi[1]} {seta} {pf[0]}/{pf[1]}"
                  f"{'   (progresso parcial)' if pf[0] > pi[0] and not r['passou'] else ''}")
        print(f"  tempo {r['tempo']}s · turnos {r['turnos']} · "
              f"tokens {r['tokens']} · chamadas {r['chamadas']}")
        print()

    if any(r["verde_no_inicio"] for r in execucoes):
        print("❌ FIXTURE INVÁLIDA: a suíte passa antes do modelo agir.")
        return 2

    passes = sum(1 for r in execucoes if r["passou"])
    rotulo = "taxa" if a.temperature == 0.0 else "pass@k"
    print(f"pass@1 = {'sim' if execucoes[0]['passou'] else 'nao'} · "
          f"{rotulo} = {passes}/{len(execucoes)} (temp {a.temperature})")
    for r in execucoes:
        if r.get("workspace"):
            print(f"    workspace mantido: {r['workspace']}")
    if any(r["tentou_editar_teste"] for r in execucoes):
        n = sum(1 for r in execucoes if r["tentou_editar_teste"])
        print(f"⚠️  tentou editar o arquivo de teste em {n}/{len(execucoes)} execuções")
    return 0 if passes else 1


if __name__ == "__main__":
    sys.exit(main())
