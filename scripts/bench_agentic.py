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

    # ─ modo worktree ─
    # Vendorizar (copiar arquivos para agentic_tasks/<nome>/) só é barato quando
    # o bug cabe num arquivo puro sem imports. Dos 300 commits varridos do
    # Beahub, 20 tinham teste no proprio commit e só UM era assim.
    #
    # No modo worktree a tarefa aponta para o repo real: cria-se um git worktree
    # em <commit>^ (estado bugado), restaura-se o spec da versao pos-fix, e
    # roda-se o teste com o node_modules do repo linkado. Custo por tarefa cai
    # para escrever um task.json, e tarefa multi-arquivo passa a ser viavel.
    #
    # Preco: depende do repo estar presente. Assumido de proposito — sao tarefas
    # do proprio codigo do usuario, para os modelos do proprio usuario.
    repo: str = ""
    commit: str = ""
    specs: List[str] = field(default_factory=list)
    cwd: str = ""
    link_node_modules: List[str] = field(default_factory=list)

    @property
    def modo_worktree(self) -> bool:
        return bool(self.repo and self.commit)

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
            repo=os.path.expanduser(cfg.get("repo", "")),
            commit=cfg.get("commit", ""),
            specs=cfg.get("specs", []),
            cwd=cfg.get("cwd", ""),
            link_node_modules=cfg.get("link_node_modules", []),
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
        fn("list_files", "Lista arquivos. Opcionalmente de um subdiretorio.",
           {"path": {"type": "string",
                     "description": "subdiretorio relativo; omita para a raiz"}}),
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
        self.chamadas: Dict[str, int] = {}
        self._worktree: Optional[Path] = None
        if task.modo_worktree:
            self.dir = self._montar_worktree()
        else:
            self.dir = Path(tempfile.mkdtemp(prefix=f"agentic-{task.key}-"))
            for item in task.dir.iterdir():
                if item.is_file():
                    shutil.copy2(item, self.dir / item.name)

    # ─── modo worktree ──────────────────────────────────────────────────────────

    def _git(self, *args: str, cwd: Optional[Path] = None) -> str:
        p = subprocess.run(["git", *args], cwd=str(cwd or self.task.repo),
                           capture_output=True, text=True, timeout=300)
        if p.returncode != 0:
            raise RuntimeError(f"git {' '.join(args)} falhou: {p.stderr.strip()[:400]}")
        return p.stdout.strip()

    def _montar_worktree(self) -> Path:
        t = self.task
        repo = Path(t.repo)
        if not (repo / ".git").exists():
            raise RuntimeError(
                f"repo nao encontrado ou nao e git: {repo}\n"
                f"    Esta tarefa roda no modo worktree e precisa do repo local.")

        # --detach evita criar branch e nao mexe em nada que o usuario tenha
        # aberto. O destino fica em tempdir, nunca dentro do repo dele.
        base = Path(tempfile.mkdtemp(prefix=f"agentic-wt-{t.key}-"))
        alvo = base / "wt"
        self._worktree = alvo
        self._git("worktree", "add", "--detach", str(alvo), f"{t.commit}^")

        # Traz os arquivos de teste da versao POS-fix. O codigo fica no estado
        # bugado (commit^); so o teste avanca. E isso que cria o vermelho.
        if t.specs:
            self._git("checkout", t.commit, "--", *t.specs, cwd=alvo)

        # node_modules por symlink: sao centenas de MB por pacote (527 e 609 no
        # Beahub); copiar por tentativa seria inviavel. Symlink e somente-leitura
        # na pratica porque o modelo so escreve no arquivo alvo.
        for rel in t.link_node_modules:
            origem = repo / rel / "node_modules"
            destino = alvo / rel / "node_modules"
            if origem.is_dir() and not destino.exists():
                destino.parent.mkdir(parents=True, exist_ok=True)
                destino.symlink_to(origem, target_is_directory=True)

        return alvo / t.cwd if t.cwd else alvo

    def limpar(self) -> None:
        if self._worktree is not None:
            try:
                self._git("worktree", "remove", "--force", str(self._worktree))
            except Exception:                                # noqa: BLE001
                shutil.rmtree(self._worktree, ignore_errors=True)
                try:
                    self._git("worktree", "prune")
                except Exception:                            # noqa: BLE001
                    pass
            shutil.rmtree(self._worktree.parent, ignore_errors=True)
        else:
            shutil.rmtree(self.dir, ignore_errors=True)

    def _eh_somente_leitura(self, alvo: Path, bruto: str) -> bool:
        if Path(bruto).name in self.task.somente_leitura:
            return True
        raiz = self.raiz_confinamento.resolve()
        for rel in list(self.task.specs) + list(self.task.somente_leitura):
            try:
                if (raiz / rel).resolve() == alvo:
                    return True
            except OSError:
                continue
        return False

    @property
    def raiz_confinamento(self) -> Path:
        """O que o modelo pode ver e escrever.

        No modo worktree e a raiz do worktree, nao o cwd do teste: uma tarefa
        multi-arquivo precisa ler codigo fora do pacote onde o teste roda.
        """
        return self._worktree or self.dir

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
                raiz = self.raiz_confinamento
                sub = args.get("path") or "."
                alvo = self._resolver(sub)
                if alvo is None or not alvo.is_dir():
                    return f"nao e um diretorio: {sub}"
                itens = []
                for p in sorted(alvo.iterdir()):
                    if p.name in {"node_modules", ".git", "dist", ".next"}:
                        continue
                    rel = p.relative_to(raiz)
                    itens.append(f"{rel}/" if p.is_dir() else str(rel))
                return "\n".join(itens) or "(vazio)"

            if nome == "read_file":
                alvo = self._resolver(args.get("path", ""))
                if alvo is None:
                    return "caminho fora do diretório de trabalho"
                if not alvo.exists():
                    return f"arquivo não existe: {args.get('path')}"
                return alvo.read_text(encoding="utf-8")

            if nome == "write_file":
                caminho = args.get("path", "")
                alvo = self._resolver(caminho)
                if alvo is None:
                    return "caminho fora do diretório de trabalho"
                # A recusa é explícita e informativa de propósito: interessa
                # saber se o modelo TENTOU editar o teste, não só se conseguiu.
                #
                # Checa por caminho RESOLVIDO, não só por basename: no modo
                # worktree os specs são relativos ao repo, e comparar basename
                # deixaria passar `outro/dir/mesmo-nome.spec.ts`.
                if self._eh_somente_leitura(alvo, caminho):
                    return (f"NEGADO: '{caminho}' é somente leitura. "
                            f"Corrija {self.task.arquivo_alvo} em vez disso.")
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
        raiz = self.raiz_confinamento.resolve()
        try:
            alvo = (raiz / rel).resolve()
            alvo.relative_to(raiz)
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
