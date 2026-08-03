#!/usr/bin/env bash
#
# llm-server — LLM local servido em HTTP (API compatível com OpenAI) no Linux via llama.cpp com CUDA.
#
# Uso: ./linux/llm-server.sh <comando> [perfil] [--lan]
#
#   setup    baixa e instala o llama.cpp com suporte a CUDA em ~/.local/share/llm-server
#   start    sobe o servidor (padrão: agent)
#   stop     derruba o servidor e libera a VRAM
#   restart  troca de modelo
#   status   mostra se está no ar, VRAM em uso, modelo carregado
#   logs     acompanha o log ao vivo
#   ask "..." manda uma pergunta e imprime a resposta com tok/s
#   models   lista os perfis e os que já foram baixados
#   pull     só baixa os pesos do modelo
#   bench    mede tokens/s reais nesta máquina
#   vram     mostra o orçamento de VRAM por perfil
#
# Hardware alvo: PC Linux (Pop!_OS / Ubuntu), RTX 3060 Ti (8 GB VRAM), 16 GB RAM.

set -euo pipefail

# ─── diretórios e arquivos ──────────────────────────────────────────────────────
ROOT_DIR="$HOME/.local/share/llm-server"
BIN_DIR="$ROOT_DIR/bin"
LLAMA_SERVER="$BIN_DIR/llama-server"
MODEL_DIR="$ROOT_DIR/models"
RUN_DIR="$ROOT_DIR/run"
PID_FILE="$RUN_DIR/server.pid"
LOG_FILE="$RUN_DIR/server.log"
PROF_FILE="$RUN_DIR/current-profile"

mkdir -p "$BIN_DIR" "$MODEL_DIR" "$RUN_DIR"

INHIBIT=""
if command -v systemd-inhibit &>/dev/null; then
  INHIBIT="systemd-inhibit --what=idle:sleep:handle-lid-switch --who=llm-server --why=LLM-Server-Running"
fi

PORT="${LLM_PORT:-8080}"
DEFAULT_PROFILE="agent"
API_KEY="local"

# ─── tratamento de argumentos e flag --lan ─────────────────────────────────────
COMMAND="${1:-start}"
shift || true

LAN=false
CUSTOM_CTX="${LLM_CTX:-}"
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lan)
      LAN=true
      shift
      ;;
    --ctx|-c)
      CUSTOM_CTX="$2"
      shift 2
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"

# ─── IP de escuta ───────────────────────────────────────────────────────────────
get_lan_ip() {
  local ip
  ip=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n1 | xargs -I{} ip -4 addr show {} | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || true)
  if [[ -z "$ip" ]]; then
    ip=$(hostname -I | awk '{print $1}')
  fi
  echo "$ip"
}

if $LAN; then
  BIND_HOST="$(get_lan_ip)"
elif [[ -n "${LLM_HOST:-}" ]]; then
  BIND_HOST="$LLM_HOST"
else
  BIND_HOST="127.0.0.1"
fi

PROBE_HOST="$BIND_HOST"
if [[ "$BIND_HOST" == "0.0.0.0" ]]; then
  PROBE_HOST="127.0.0.1"
fi

# ─── cores ──────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
  RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLU=$'\033[34m'; CYA=$'\033[36m'
else
  B=""; DIM=""; R=""; RED=""; GRN=""; YLW=""; BLU=""; CYA=""
fi

# ─── perfis ─────────────────────────────────────────────────────────────────────
#  perfil | repo | weights_gb | ctx | vram_gb | ram_gb | cpu_moe | tools | file | extra_args | desc
get_profiles() {
  cat <<'EOF'
agent|Qwen/Qwen3-8B-GGUF|Q4_K_M|5.03|16384|6.24|0.5|0|sim||--reasoning off|Qwen3 8B. Tool calling validado (ciclo completo). ~73 tok/s de geracao nesta 3060 Ti. Padrao.
fast|Qwen/Qwen2.5-Coder-7B-Instruct-GGUF|Q4_K_M|4.30|16384|5.40|0.5|0|nao|||Qwen2.5 Coder 7B. Especialista em código puro, ~80 tok/s. Não serve como agente.
moe|HauhauCS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive|IQ4_NL|18.42|16384|6.17|12.5|36|sim|Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-IQ4_NL.gguf|--reasoning off|Qwen3.6 35B MoE (3B ativos). 36 camadas de expert na RAM, atencao na VRAM. ~26 tok/s.
deepseek|bartowski/DeepSeek-Coder-V2-Lite-Instruct-GGUF|Q8_0|15.56|16384|8.00|8.0|16|sim|DeepSeek-Coder-V2-Lite-Instruct-Q8_0.gguf||DeepSeek Coder V2 Lite 16B MoE (2.4B ativos) em Q8_0. Máxima precisão para código.
frontier|unsloth/DeepSeek-V4-Flash-0731-GGUF|UD-IQ1_S|76.87|8192|7.00|15.0|128|sim|DeepSeek-V4-Flash-0731-UD-IQ1_S-00001-of-00003.gguf||DeepSeek V4 Flash Frontier MoE (76.8 GB). Experimento de qualidade máxima via mmap/SSD.
quality|bartowski/gemma-4-12B-it-GGUF|Q4_K_M|7.30|8192|7.80|1.0|0|sim|||Gemma 4 12B. Aceita imagens e texto. Exige liberar VRAM para rodar liso.
tiny|Qwen/Qwen2.5-Coder-3B-Instruct-GGUF|Q4_K_M|2.00|16384|2.90|0.3|0|nao|||Qwen2.5 Coder 3B. Leve, ~110 tok/s. Ótimo para autocompletar e testes rápidos.
EOF
}

find_profile() {
  local target="$1"
  while IFS='|' read -r name repo quant file_gb ctx vram_gb ram_gb cpu_moe tools file extra_args desc; do
    if [[ "$name" == "$target" ]]; then
      echo "$name|$repo|$quant|$file_gb|$ctx|$vram_gb|$ram_gb|$cpu_moe|$tools|$file|$extra_args|$desc"
      return 0
    fi
  done < <(get_profiles)
  return 1
}

# ─── comando: setup ─────────────────────────────────────────────────────────────
cmd_setup() {
  echo "${B}Configurando llm-server no Linux (llama.cpp)...${R}"
  mkdir -p "$BIN_DIR" "$MODEL_DIR" "$RUN_DIR"

  if command -v nvidia-smi &>/dev/null; then
    echo "${GRN}✓ GPU NVIDIA e drivers detectados.${R}"
  else
    echo "${YLW}⚠️ AVISO: GPU NVIDIA não foi encontrada com nvidia-smi.${R}"
  fi

  # Baixar a versão mais recente do llama-server precompilado no GitHub
  echo "Buscando a última versão do llama.cpp no GitHub..."
  LATEST_TAG=$(curl -s https://api.github.com/repos/ggml-org/llama.cpp/releases/latest | grep '"tag_name":' | head -n1 | sed -E 's/.*"([^"]+)".*/\1/' || echo "b10235")
  
  URL="https://github.com/ggml-org/llama.cpp/releases/download/${LATEST_TAG}/llama-${LATEST_TAG}-bin-ubuntu-vulkan-x64.tar.gz"
  TMP_TAR="/tmp/llama.tar.gz"
  
  echo "Baixando ${LATEST_TAG} de ${URL}..."
  if curl -sL "$URL" -o "$TMP_TAR"; then
    echo "Extraindo para $BIN_DIR..."
    tar -xzf "$TMP_TAR" -C "$BIN_DIR" --strip-components=1 2>/dev/null || tar -xzf "$TMP_TAR" -C "$BIN_DIR"
    rm -f "$TMP_TAR"
    chmod +x "$BIN_DIR"/llama-* 2>/dev/null || true
  else
    echo "${RED}Falha no download direto do arquivo precompilado. Tentando compilar via git...${R}"
    TMP_SRC="/tmp/llama_src"
    rm -rf "$TMP_SRC"
    git clone --depth 1 https://github.com/ggerganov/llama.cpp "$TMP_SRC"
    cmake -B "$TMP_SRC/build" -S "$TMP_SRC" -DGGML_CUDA=ON
    cmake --build "$TMP_SRC/build" --config Release -j$(nproc) --target llama-server
    cp "$TMP_SRC/build/bin/llama-server" "$BIN_DIR/"
    rm -rf "$TMP_SRC"
  fi

  if [[ -x "$LLAMA_SERVER" ]]; then
    echo "${GRN}✓ llama-server instalado com sucesso em $LLAMA_SERVER${R}"
    "$LLAMA_SERVER" --version || true
  else
    echo "${RED}❌ Erro ao instalar llama-server.${R}"
    exit 1
  fi
}

# ─── status do processo ─────────────────────────────────────────────────────────
is_running() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

# ─── comando: start ─────────────────────────────────────────────────────────────
cmd_start() {
  local prof_name="${1:-$DEFAULT_PROFILE}"

  if ! [[ -x "$LLAMA_SERVER" ]]; then
    echo "${YLW}llama-server não encontrado em $LLAMA_SERVER. Executando setup...${R}"
    cmd_setup
  fi

  if is_running; then
    local curr_prof
    curr_prof=$(cat "$PROF_FILE" 2>/dev/null || echo "desconhecido")
    if [[ "$curr_prof" == "$prof_name" ]]; then
      echo "${GRN}✓ Servidor já está rodando com o perfil '$prof_name' (PID: $(cat "$PID_FILE")).${R}"
      return 0
    else
      echo "${YLW}Servidor rodando com perfil '$curr_prof'. Trocando para '$prof_name'...${R}"
      cmd_stop
    fi
  fi

  local p_data
  p_data=$(find_profile "$prof_name") || { echo "${RED}Perfil '$prof_name' não existe.${R}"; exit 1; }

  IFS='|' read -r name repo quant file_gb ctx vram_gb ram_gb cpu_moe tools file extra_args desc <<< "$p_data"
  local final_ctx="${CUSTOM_CTX:-$ctx}"

  echo "${B}Subindo llm-server [perfil: ${CYA}$prof_name${R}${B}]...${R}"
  echo "${DIM}Modelo: $repo ($quant) | Ctx: $final_ctx | Host: $BIND_HOST:$PORT${R}"

  local ARGS=(
    "--host" "$BIND_HOST"
    "--port" "$PORT"
    "-c" "$final_ctx"
    "-ngl" "${LLM_NGL:-28}"
    "--api-key" "$API_KEY"
  )

  if [[ -n "$file" ]]; then
    local model_path="$MODEL_DIR/$file"
    if [[ ! -f "$model_path" ]]; then
      echo "${YLW}Baixando peso $file...${R}"
      curl -C - -L "https://huggingface.co/$repo/resolve/main/$file" -o "$model_path"
    fi
    ARGS+=("-m" "$model_path")
  else
    ARGS+=("-hf" "$repo:$quant")
  fi

  if [[ "$cpu_moe" -gt 0 ]]; then
    ARGS+=("--n-cpu-moe" "$cpu_moe")
  fi

  if [[ -n "$extra_args" ]]; then
    read -r -a EXTRA_ARR <<< "$extra_args"
    ARGS+=("${EXTRA_ARR[@]}")
  fi

  if [[ -n "$INHIBIT" ]]; then
    nohup $INHIBIT "$LLAMA_SERVER" "${ARGS[@]}" > "$LOG_FILE" 2>&1 &
  else
    nohup "$LLAMA_SERVER" "${ARGS[@]}" > "$LOG_FILE" 2>&1 &
  fi
  local pid=$!
  echo "$pid" > "$PID_FILE"
  echo "$prof_name" > "$PROF_FILE"

  echo -n "Aguardando o servidor subir (health check em http://$PROBE_HOST:$PORT/health)... "
  local attempts=0
  while [[ $attempts -lt 30 ]]; do
    if kill -0 "$pid" 2>/dev/null; then
      if curl -s -f -h "Authorization: Bearer $API_KEY" "http://$PROBE_HOST:$PORT/health" &>/dev/null; then
        echo "${GRN}ONLINE!${R}"
        echo "${GRN}✓ llm-server pronto no perfil '$prof_name' (PID: $pid)${R}"
        return 0
      fi
    else
      echo "${RED}FALHOU!${R}"
      echo "${RED}O processo morreu. Verifique o log em $LOG_FILE${R}"
      tail -n 20 "$LOG_FILE"
      rm -f "$PID_FILE"
      exit 1
    fi
    sleep 1
    attempts=$((attempts + 1))
  done

  echo "${YLW}Timeout aguardando health check, mas o processo ainda está rodando (PID: $pid).${R}"
}

# ─── comando: stop ──────────────────────────────────────────────────────────────
cmd_stop() {
  if is_running; then
    local pid
    pid=$(cat "$PID_FILE")
    echo "${B}Parando llm-server (PID: $pid)...${R}"
    kill "$pid" 2>/dev/null || true
    local attempts=0
    while kill -0 "$pid" 2>/dev/null && [[ $attempts -lt 10 ]]; do
      sleep 0.5
      attempts=$((attempts + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE" "$PROF_FILE"
    echo "${GRN}✓ Servidor parado e memória liberada.${R}"
  else
    echo "Servidor não está rodando."
    rm -f "$PID_FILE" "$PROF_FILE"
  fi
}

# ─── comando: status ────────────────────────────────────────────────────────────
cmd_status() {
  echo "${B}─── Estado do llm-server (Linux/CUDA) ───────────────────────────────${R}"
  if is_running; then
    local pid prof
    pid=$(cat "$PID_FILE")
    prof=$(cat "$PROF_FILE" 2>/dev/null || echo "desconhecido")
    echo "Status:   ${GRN}ONLINE${R} (PID: $pid)"
    echo "Perfil:   ${CYA}$prof${R}"
    echo "URL:      http://$PROBE_HOST:$PORT"
  else
    echo "Status:   ${RED}OFFLINE${R}"
  fi

  echo ""
  if command -v nvidia-smi &>/dev/null; then
    echo "${B}Memória da GPU (NVIDIA):${R}"
    nvidia-smi --query-gpu=name,memory.used,memory.total,temperature.gpu,utilization.gpu --format=csv,noheader
  fi
  echo ""
  echo "${B}Memória do Sistema:${R}"
  free -h | grep -E "Mem|Swap"
}

# ─── comando: logs ──────────────────────────────────────────────────────────────
cmd_logs() {
  if [[ -f "$LOG_FILE" ]]; then
    echo "${B}Acompanhando logs de $LOG_FILE (Ctrl+C para sair)...${R}"
    tail -f "$LOG_FILE"
  else
    echo "Nenhum arquivo de log em $LOG_FILE"
  fi
}

# ─── comando: ask ───────────────────────────────────────────────────────────────
cmd_ask() {
  local prompt="${1:-}"
  if [[ -z "$prompt" ]]; then
    echo "${RED}Erro: Digite a pergunta. Exemplo: ./llm-server.sh ask 'O que é um closure em Rust?'${R}"
    exit 1
  fi

  if ! is_running; then
    echo "${YLW}Servidor offline. Subindo perfil padrão ($DEFAULT_PROFILE)...${R}"
    cmd_start "$DEFAULT_PROFILE"
  fi

  echo "${B}Pergunta:${R} $prompt"
  echo "${B}Resposta:${R}"
  
  local payload
  payload=$(python3 -c "import json, sys; print(json.dumps({'model': 'local', 'messages': [{'role': 'user', 'content': sys.argv[1]}], 'temperature': 0.2}))" "$prompt")

  curl -s -X POST "http://$PROBE_HOST:$PORT/v1/chat/completions" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data['choices'][0]['message']['content'])
    if 'usage' in data:
        u = data['usage']
        print(f'\n--- {u.get(\"completion_tokens\", 0)} tokens gerados ---')
except Exception as e:
    print('Erro ao parsear resposta:', e)
"
}

# ─── comando: bench ─────────────────────────────────────────────────────────────
cmd_bench() {
  local rounds="${1:-4}"
  if ! is_running; then
    echo "${RED}Servidor parado. Suba com: ./linux/llm-server.sh start [perfil]${R}"
    exit 1
  fi
  local prof
  prof=$(cat "$PROF_FILE" 2>/dev/null || echo "$DEFAULT_PROFILE")
  echo "${B}Medindo benchmark nesta máquina (perfil: ${CYA}$prof${R}${B}, $rounds rodadas, 1ª descartada)...${R}"

  python3 -c "
import urllib.request, json, time, sys

host = '$PROBE_HOST'
port = '$PORT'
api_key = '$API_KEY'
rounds = $rounds

url = f'http://{host}:{port}/v1/chat/completions'
headers = {'Content-Type': 'application/json', 'Authorization': f'Bearer {api_key}'}
payload = {
    'model': 'local',
    'messages': [{'role': 'user', 'content': 'Escreva um script genérico de ordenação merge sort em Python com comentários explicativos e testes unitários.'}],
    'max_tokens': 512,
    'temperature': 0.2
}

prefill_rates = []
gen_rates = []

for i in range(1, rounds + 1):
    t0 = time.time()
    req = urllib.request.Request(url, data=json.dumps(payload).encode('utf-8'), headers=headers)
    try:
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read().decode('utf-8'))
            elapsed = time.time() - t0
            timings = data.get('timings', {})
            p_tok = timings.get('prompt_n', data.get('usage', {}).get('prompt_tokens', 0))
            g_tok = timings.get('predicted_n', data.get('usage', {}).get('completion_tokens', 0))
            p_rate = timings.get('prompt_per_second', 0)
            g_rate = timings.get('predicted_per_second', g_tok / elapsed if elapsed > 0 else 0)
            
            if i > 1:
                prefill_rates.append(p_rate)
                gen_rates.append(g_rate)
            
            print(f'  [Rodada {i}/{rounds}] Prefill: {p_rate:.1f} tok/s ({p_tok} tok) | Geração: {g_rate:.1f} tok/s ({g_tok} tok) | Tempo: {elapsed:.2f}s')
    except Exception as e:
        print(f'  [Rodada {i}/{rounds}] Erro: {e}')

if gen_rates:
    gen_rates.sort()
    prefill_rates.sort()
    med_g = gen_rates[len(gen_rates)//2]
    med_p = prefill_rates[len(prefill_rates)//2] if prefill_rates else 0
    print(f'\nRESULTADO DO BENCHMARK (Mediana):')
    print(f'  Geração: {med_g:.1f} tok/s')
    print(f'  Prefill: {med_p:.1f} tok/s')
"
}

# ─── comando: pull ──────────────────────────────────────────────────────────────
cmd_pull() {
  local prof_name="${1:-$DEFAULT_PROFILE}"
  local p_data
  p_data=$(find_profile "$prof_name") || { echo "${RED}Perfil '$prof_name' não existe.${R}"; exit 1; }
  IFS='|' read -r name repo quant file_gb ctx vram_gb ram_gb cpu_moe tools file extra_args desc <<< "$p_data"

  mkdir -p "$MODEL_DIR"
  if [[ -n "$file" ]]; then
    local model_path="$MODEL_DIR/$file"
    echo "${B}Baixando/Verificando peso do perfil '$prof_name' ($file_gb GB)...${R}"
    if [[ -n "$INHIBIT" ]]; then
      $INHIBIT curl -C - -L "https://huggingface.co/$repo/resolve/main/$file" -o "$model_path"
    else
      curl -C - -L "https://huggingface.co/$repo/resolve/main/$file" -o "$model_path"
    fi
    echo "${GRN}✓ Download concluído com sucesso em $model_path!${R}"
  else
    echo "Baixando repositório HF $repo ($quant)..."
    "$LLAMA_SERVER" -hf "$repo:$quant" --version || true
  fi
}

# ─── comando: models ────────────────────────────────────────────────────────────
cmd_models() {
  echo "${B}Perfis de Modelos Disponíveis (Linux/CUDA):${R}"
  echo ""
  printf "%-10s %-42s %-8s %-12s %s\n" "PERFIL" "REPOSITÓRIO" "PESO(GB)" "TOOLS" "DESCRIÇÃO"
  echo "────────── ────────────────────────────────────────── ──────── ──────────── ──────────────────────────────────────────────────"
  
  local curr_prof=""
  if is_running; then
    curr_prof=$(cat "$PROF_FILE" 2>/dev/null || echo "")
  fi

  while IFS='|' read -r name repo quant file_gb ctx vram_gb ram_gb cpu_moe tools file extra_args desc; do
    local mark=" "
    if [[ "$name" == "$curr_prof" ]]; then mark="*"; fi
    printf "%-10s %-42s %-8s %-12s %s\n" "$mark$name" "$repo" "${file_gb}GB" "$tools" "$desc"
  done < <(get_profiles)
}

# ─── roteamento principal ───────────────────────────────────────────────────────
case "$COMMAND" in
  setup)
    cmd_setup
    ;;
  start)
    cmd_start "${1:-$DEFAULT_PROFILE}"
    ;;
  stop)
    cmd_stop
    ;;
  restart)
    cmd_stop
    cmd_start "${1:-$DEFAULT_PROFILE}"
    ;;
  status)
    cmd_status
    ;;
  logs)
    cmd_logs
    ;;
  ask)
    cmd_ask "${1:-}"
    ;;
  models)
    cmd_models
    ;;
  pull)
    cmd_pull "${1:-$DEFAULT_PROFILE}"
    ;;
  bench)
    cmd_bench "${1:-4}"
    ;;
  help|--help|-h)
    echo "Uso: ./linux/llm-server.sh {setup|start|stop|restart|status|logs|ask|models} [perfil] [--lan]"
    ;;
  *)
    cmd_start "$COMMAND"
    ;;
esac
