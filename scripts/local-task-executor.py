import json
import urllib.request
import urllib.error
import os
import sys

from local_llm_config import get_config

CONFIG = get_config()
LOCAL_LLM_URL = CONFIG["url"]
API_KEY = CONFIG["key"]
MODEL_NAME = CONFIG["model"]

def call_local_llm(prompt: str, system_prompt: str) -> str:
    payload = {
        "model": MODEL_NAME,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": prompt}
        ],
        "temperature": 0.2,
        "max_tokens": 1200
    }
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {API_KEY}"
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(LOCAL_LLM_URL, data=data, headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=90) as response:
        res_body = response.read().decode("utf-8")
        res_json = json.loads(res_body)
        return res_json["choices"][0]["message"]["content"]

def main():
    try:
        input_data = json.load(sys.stdin)
        task_title = input_data.get("task_title", "")
        task_context = input_data.get("task_context", "")
        existing_code_or_spec = input_data.get("context", "")

        system_prompt = (
            "Você é um Coder/Worker especializado em executar 1 tarefa específica por vez. "
            "Escreva a solução/código/instruções detalhadas para cumprir estritamente essa única tarefa."
        )
        
        prompt = (
            f"=== TAREFA PARA EXECUÇÃO ===\n{task_title}\n\n"
            f"=== CONTEXTO DA TAREFA ===\n{task_context}\n\n"
            f"=== CONTEXTO DO PROJETO / CÓDIGO ===\n{existing_code_or_spec}\n\n"
            "Escreva o código ou resultado completo para esta tarefa."
        )

        output = call_local_llm(prompt, system_prompt)
        print(json.dumps({"success": True, "output": output}))
    except Exception as e:
        print(json.dumps({"success": False, "error": str(e)}))

if __name__ == "__main__":
    main()
