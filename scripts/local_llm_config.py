import os

def load_env_local_llm():
    """Carrega as variáveis do arquivo .env.local.llm na raiz do projeto"""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    root_dir = os.path.abspath(os.path.join(script_dir, ".."))
    env_file = os.path.join(root_dir, ".env.local.llm")

    if os.path.exists(env_file):
        with open(env_file, "r") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, val = line.split("=", 1)
                    if key not in os.environ:
                        os.environ[key] = val

def get_config():
    load_env_local_llm()
    return {
        "url": os.getenv("LOCAL_LLM_URL", "http://192.168.3.51:8080/v1/chat/completions"),
        "key": os.getenv("LOCAL_LLM_KEY", "local"),
        "model": os.getenv("LOCAL_LLM_MODEL", "moe")
    }
