import subprocess
import json
import urllib.request
import urllib.error
import sys
import os

from local_llm_config import get_config

CONFIG = get_config()
LOCAL_LLM_URL = CONFIG["url"]
API_KEY = CONFIG["key"]
MODEL_NAME = CONFIG["model"]

SYSTEM_PROMPT = """Você é o Blind Judge (Juiz Adversarial de Código).
Sua missão é analisar o diff fornecido e buscar problemas de:
1. Segredos ou credenciais expostas.
2. Quebra de sintaxe ou imports inválidos.
3. Regressões de performance ou vazamento de memória.
4. Violações da regra de ouro do repositório.

Se o diff estiver seguro e correto, responda exatamente: "JUDGMENT: APPROVED".
Se encontrar problemas reais, responda "JUDGMENT: REJECTED" seguido da explicação técnica sucinta.
"""

def get_git_diff() -> str:
    try:
        diff = subprocess.check_output(["git", "diff", "HEAD"], text=True)
        if not diff.strip():
            diff = subprocess.check_output(["git", "diff", "--staged"], text=True)
        return diff.strip()
    except Exception as e:
        return f"Erro ao obter diff: {e}"

def review_with_local_llm(diff_text: str) -> str:
    if not diff_text:
        return "Nenhum diff encontrado para revisão."

    if len(diff_text) > 8000:
        diff_text = diff_text[:8000] + "\n...[diff truncado por tamanho]"

    payload = {
        "model": MODEL_NAME,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": f"Analise o seguinte diff:\n\n{diff_text}"}
        ],
        "temperature": 0.1,
        "max_tokens": 1000
    }
    
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {API_KEY}"
    }
    
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(LOCAL_LLM_URL, data=data, headers=headers, method="POST")
    
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            res_body = response.read().decode("utf-8")
            res_json = json.loads(res_body)
            return res_json["choices"][0]["message"]["content"]
    except urllib.error.HTTPError as e:
        if e.code == 401:
            return f"❌ Erro 401: O modelo local exige uma API Key válida. Configure a variável LOCAL_LLM_KEY."
        return f"❌ Erro HTTP {e.code} ao conectar com o modelo local: {e.reason}"
    except Exception as e:
        return f"❌ Erro ao conectar com o modelo local ({LOCAL_LLM_URL}): {e}"

if __name__ == "__main__":
    print(f"⚖️  Iniciando revisão via Blind Judge Local ({LOCAL_LLM_URL})...\n")
    diff = get_git_diff()
    if not diff:
        print("ℹ️ Nenhuma alteração pendente no git (diff limpo).")
    else:
        resultado = review_with_local_llm(diff)
        print("=== RESULTADO DO JUDGMENT DAY LOCAL ===")
        print(resultado)
