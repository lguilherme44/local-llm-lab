#!/usr/bin/env python3
"""
Controle do servidor remoto: pull, troca de perfil, health check.

Separado do pipeline porque a versão anterior misturava orquestração de SSH com
medição no mesmo arquivo, e o resultado é que uma falha de `pull` passava em
silêncio (o código de retorno de `run_ssh` era ignorado) e o modelo aparecia
como "não testado" sem nenhum diagnóstico.
"""

from __future__ import annotations

import subprocess
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Optional, Tuple


class ServerError(RuntimeError):
    """Falha de infraestrutura — distinta de falha do modelo em uma tarefa."""


@dataclass
class RemoteServer:
    ssh_key: str
    host: str
    health_url: str
    remote_script: str = "~/local-llm-lab/linux/llm-server.sh"
    api_key: str = "local"

    # ─── SSH ────────────────────────────────────────────────────────────────────

    def ssh(self, cmd: str, timeout: Optional[int] = None) -> Tuple[str, str, int]:
        proc = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", "-i", self.ssh_key, self.host, cmd],
            capture_output=True, text=True, timeout=timeout,
        )
        return proc.stdout.strip(), proc.stderr.strip(), proc.returncode

    def ssh_checked(self, cmd: str, timeout: Optional[int] = None) -> str:
        """Igual a ssh(), mas levanta em vez de engolir o erro.

        A versão anterior fazia `run_ssh(f"... pull {m['pull']}")` e descartava o
        retorno. Quando o download falhava, o pipeline seguia como se tudo
        estivesse bem e o modelo desaparecia do relatório.
        """
        out, err, code = self.ssh(cmd, timeout=timeout)
        if code != 0:
            raise ServerError(f"ssh falhou (exit {code}): {cmd}\n{err or out}")
        return out

    # ─── health ─────────────────────────────────────────────────────────────────

    def is_healthy(self, timeout: float = 5.0) -> bool:
        req = urllib.request.Request(
            self.health_url, headers={"Authorization": f"Bearer {self.api_key}"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.status == 200
        except (urllib.error.URLError, OSError):
            return False

    def wait_healthy(self, timeout: float = 600.0, interval: float = 3.0) -> bool:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.is_healthy():
                return True
            time.sleep(interval)
        return False

    # ─── ciclo de vida do modelo ────────────────────────────────────────────────

    def pull(self, profile: str, timeout: int = 7200) -> None:
        print(f"  ⬇️  Garantindo pesos do perfil '{profile}'...")
        self.ssh_checked(f"{self.remote_script} pull {profile}", timeout=timeout)

    def start_profile(self, profile: str, ctx: int,
                      timeout: int = 900,
                      env: Optional[dict] = None) -> None:
        print(f"  🚀 Carregando perfil '{profile}' (ctx {ctx})...")
        # env permite variar LLM_REASONING / LLM_NGL / LLM_CPU_MOE entre rodadas
        # sem editar a tabela de perfis — comparacao A/B no mesmo modelo.
        prefix = f"LLM_CTX={ctx}"
        for key, value in (env or {}).items():
            prefix += f" {key}={value}"
        out, err, code = self.ssh(
            f"{prefix} {self.remote_script} restart {profile} --lan",
            timeout=timeout,
        )
        if code != 0:
            tail = self.tail_log(30)
            raise ServerError(
                f"restart do perfil '{profile}' falhou (exit {code}).\n"
                f"stderr: {err[-800:]}\n--- log do servidor ---\n{tail}")

        if not self.wait_healthy(timeout=timeout):
            raise ServerError(
                f"perfil '{profile}' não respondeu ao health check.\n"
                f"--- log do servidor ---\n{self.tail_log(30)}")

        # Registrar o que o servidor DE FATO decidiu. Sem isso, um perfil que
        # silenciosamente caiu para menos camadas na GPU fica indistinguível de
        # um que rodou como planejado — e a comparação entre modelos vira ruído.
        print(f"  ✓ '{profile}' no ar. {self.effective_config()}")

    def stop(self) -> None:
        self.ssh(f"{self.remote_script} stop", timeout=120)

    # ─── observabilidade ────────────────────────────────────────────────────────

    def tail_log(self, lines: int = 40) -> str:
        out, _, _ = self.ssh(
            f"tail -n {lines} ~/.local/share/llm-server/run/server.log", timeout=30)
        return out

    def effective_config(self) -> str:
        """Lê a linha de comando real do processo, não a que pretendíamos passar."""
        out, _, _ = self.ssh(
            "ps -eo args | grep '[l]lama-server' | head -1", timeout=30)
        if not out:
            return "(não consegui ler a cmdline do processo)"
        flags = ("-ngl", "-c", "-ctk", "-fa", "--n-cpu-moe")
        parts = out.split()
        shown = []
        for i, tok in enumerate(parts):
            if tok in flags and i + 1 < len(parts):
                shown.append(f"{tok} {parts[i + 1]}")
        return " | ".join(shown) if shown else out[:120]

    def backend_info(self) -> dict:
        """Qual backend está de fato compilado. É a variável que mais importou.

        O script se descrevia como CUDA e rodava Vulkan. Gravar isso em cada
        relatório impede que a próxima comparação seja feita entre execuções com
        backends diferentes sem ninguém notar.
        """
        out, _, _ = self.ssh(
            "ls ~/.local/share/llm-server/bin/libggml-*.so 2>/dev/null "
            "| sed 's|.*/libggml-||; s|\\.so$||' | tr '\\n' ' '", timeout=30)
        gpu, _, _ = self.ssh(
            "nvidia-smi --query-gpu=name,memory.total,driver_version "
            "--format=csv,noheader", timeout=30)
        backends = out.split()
        return {
            "ggml_backends": backends,
            "has_cuda": any(b.startswith("cuda") for b in backends),
            "has_vulkan": any(b.startswith("vulkan") for b in backends),
            "gpu": gpu,
        }
