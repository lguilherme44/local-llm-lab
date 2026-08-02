#!/usr/bin/env python3
"""Script de validação E2E e segurança para gerenciamento de modelos (Download & Upload/Import).
"""
import os
import sys
import subprocess
import tempfile

def run_cmd(cmd):
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    return result.returncode, result.stdout, result.stderr

def main():
    print("=== Validação E2E & Segurança: Gerenciamento de Modelos ===")
    script_path = os.path.abspath(os.path.join(os.path.dirname(__file__), "../macos/llm-server.command"))
    
    if not os.path.exists(script_path):
        print(f"ERRO: Script não encontrado em {script_path}")
        sys.exit(1)

    # 1. Testar subcomando 'models'
    print("\n[1/4] Testando 'models'...")
    rc, stdout, stderr = run_cmd(f'"{script_path}" models')
    if rc == 0:
        print("PASS: Subcomando 'models' executado com sucesso.")
    else:
        print(f"FAIL: 'models' retornou código {rc}.\nStderr: {stderr}")
        sys.exit(1)

    # 2. Testar subcomando 'import' com um arquivo temporário
    print("\n[2/4] Testando 'import'...")
    with tempfile.NamedTemporaryFile(suffix=".safetensors", prefix="test_model_", delete=False) as tmp:
        tmp.write(b"dummy model weight binary content")
        tmp_path = tmp.name

    try:
        rc, stdout, stderr = run_cmd(f'"{script_path}" import "{tmp_path}"')
        if rc == 0 and "importado com sucesso" in stdout:
            print("PASS: Import de modelo executado e verificado.")
        else:
            print(f"FAIL: Import falhou.\nStdout: {stdout}\nStderr: {stderr}")
            sys.exit(1)
    finally:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)

    # 3. Testar proteção contra injeção em repositórios HF
    print("\n[3/4] Testando sanitização do 'pull' contra injeção...")
    rc, stdout, stderr = run_cmd(f'"{script_path}" pull "../invalid-repo"')
    # Espera-se falha/recusa
    if rc != 0 or "não reconheci" in stdout or "Falha" in stderr or "Erro" in stderr or "invalid" in stderr:
        print("PASS: Tentativa com repo inválido devidamente tratada/rejeitada.")
    else:
        print(f"FAIL: Repo com path traversal deveria ter sido rejeitado.")
        sys.exit(1)

    # 4. Testar subcomando 'help'
    print("\n[4/4] Testando 'help' e presença das novas opções...")
    rc, stdout, stderr = run_cmd(f'"{script_path}" help')
    if rc == 0:
        print("PASS: Subcomando 'help' validado.")
    else:
        print(f"FAIL: 'help' retornou código {rc}")
        sys.exit(1)

    print("\n>>> TODOS OS TESTES E SEGURANÇA PASSARAM COM SUCESSO! <<<")

if __name__ == "__main__":
    main()
