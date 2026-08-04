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

if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" && -e "/run/user/$(id -u)/bus" ]]; then
  export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
fi

INHIBIT=""
if command -v systemd-inhibit &>/dev/null; then
  if systemd-inhibit --what=idle:sleep --who=llm-server --why=test true &>/dev/null; then
    INHIBIT="systemd-inhibit --what=idle:sleep --who=llm-server --why=LLM-Server-Running"
  fi
fi

PORT="${LLM_PORT:-8080}"
# O default era `agent` (Qwen3 8B) — o pior dos tres medidos em trabalho
# agentico, e o unico que PIOROU codigo (quebrou 4 testes que passavam na
# fixture pwa_ios_starturl). Quem rodasse `./llm-server.sh start` sem argumento
# recebia exatamente o destrutivo.
DEFAULT_PROFILE="moe"
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
  BIND_HOST="0.0.0.0"
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
#  perfil | repo | quant | weights_gb | ctx | vram_gb | ram_gb | cpu_moe | ngl | tools | status | tps | file | extra_args | desc
#
# `status` e `tps` existem porque o veredito estava enfiado na descrição, e
# descrição longa quebra o alinhamento da tabela — a saída de `models` ficou
# ilegível. Veredito é dado estruturado, não prosa.
#
#   status: ok | ruim | inviavel | reprovado | naotestado | precisa-fork
#   tps:    tok/s de geração medidos NESTA máquina, ou `?` se não medido
#
# Sobre a coluna `ngl` — ela existe porque -ngl e --n-cpu-moe NÃO são a mesma
# coisa, e a versão anterior derivava um do outro (`default_ngl="$cpu_moe"`).
# Funcionava por coincidência.
#
#   -ngl N          quantas camadas do modelo vão para a VRAM
#   --n-cpu-moe N   de quantas camadas os tensores de expert ficam na RAM
#
# Regra descoberta na prática neste build (b10242) e não documentada de forma
# óbvia: `--n-cpu-moe` seta `tensor_buft_overrides`, o que ABORTA o auto-fit:
#
#   W common_fit_params: failed to fit params to free device memory:
#     model_params::tensor_buft_overrides already set by user, abort
#
# Consequência: perfil com cpu_moe > 0 é OBRIGADO a passar -ngl explícito. Se
# passar `auto`, o fit aborta, cai para "todas as camadas" e dá
# ErrorOutOfDeviceMemory na carga. Testado.
#
# Portanto: cpu_moe = 0  ->  ngl = auto  (deixa o llama.cpp dimensionar)
#           cpu_moe > 0  ->  ngl = 99 e o ajuste real vai no cpu_moe
#
# COMO AFINAR UM PERFIL MoE (varredura medida no perfil `moe`, CUDA, 3060 Ti):
#
#   ngl  cpu_moe   geração    VRAM        veredito
#    36    36      25.4 tok/s  4.5 GB     ponto de partida herdado do Windows
#    99    36      32.0 tok/s  4.9 GB     só subir o ngl já dá +26%
#    99    32      36.1 tok/s  6.4 GB
#    99    30      37.7 tok/s  7.1 GB     <- escolhido: +50% com folga de ~1 GB
#    99    29      38.2 tok/s  7.5 GB     fio de navalha, qualquer app derruba
#    99    28      abort (core dumped)    estourou a VRAM
#
# O botão é o cpu_moe, não o ngl: baixá-lo devolve tensores de expert para a
# VRAM. Desça de 4 em 4 até dar abort, depois suba 2 e pare — deixando ~1 GB
# para o desktop, senão abrir o navegador mata o servidor.
#
# Varre sem editar o script:
#   LLM_NGL=99 LLM_CPU_MOE=30 ./linux/llm-server.sh restart moe --lan
#
# O `deepseek` ensina que a regra "ngl 99 e deixa o llama.cpp decidir" NÃO é
# universal. Varredura medida (cpu_moe 20 fixo, ctx 32k):
#
#   ngl  resultado                        VRAM       geração
#    16  ok                               6.546 MiB  28.4 tok/s   <- escolhido
#    20  ok                               7.298 MiB  28.9 tok/s   sem folga
#    24  OOM: faltaram 3.910 MiB de KV       —          —
#    28  OOM: faltaram 4.590 MiB de KV       —          —
#
# O KV cache deste modelo pede ~4,6 GB em ctx 32k mesmo em q8_0, então subir o
# ngl rouba justamente o espaço que o KV precisa. Aqui `ngl 20` compra 0,5 tok/s
# por 750 MiB de folga: troca ruim.
#
# O `frontier` continua sem varredura, e não vai passar por uma: aponta para o
# DeepSeek-V4-Flash, 304 B de parâmetros e 82,5 GB no menor quant. Ver TODO 6.

get_profiles() {
  cat <<'EOF'
chat8b|Qwen/Qwen3-8B-GGUF|Q4_K_M|5.03|16384|6.24|0.5|0|auto|fragil|ruim|73.6||--reasoning off|Qwen3 8B. Cabe INTEIRO na VRAM (98% de GPU). NAO e agente: 1/8 nas fixtures e piorou codigo numa delas (5/8 -> 1/8). Emite tool call mas nao progride. Serve para pergunta rapida, mensagem de commit, autocomplete. Chamava-se `agent` ate 04/08.
fast|Qwen/Qwen2.5-Coder-7B-Instruct-GGUF|Q4_K_M|4.30|16384|5.40|0.5|0|auto|nao|naotestado|?|||Qwen2.5 Coder 7B. Especialista em codigo puro. Nunca testado no Linux; nao faz tool calling, entao nao serve como agente.
moe|unsloth/Qwen3.6-35B-A3B-GGUF|UD-IQ4_NL|16.80|16384|7.10|12.5|30|99|sim|ok|37.7|Qwen3.6-35B-A3B-UD-IQ4_NL.gguf|--reasoning off|Qwen3.6 35B MoE, 3B ativos. 13/14 nas fixtures de bug real do Beahub. ngl 99 + cpu_moe 30. O unico validado para trabalho agentico.
qwen27b|unsloth/Qwen3.6-27B-MTP-GGUF|IQ4_NL|15.22|16384|7.00|10.0|24|24|?|inviavel|3.1|Qwen3.6-27B-IQ4_NL.gguf||Denso de 15.22 GB: nao cabe em 8 GB de VRAM, ~9 GB rodam na CPU e a GPU fica a 17%. Peso apagado em 04/08. Fica na tabela como contraste com o MoE de tamanho parecido.
bonsai|prism-ml/Bonsai-27B-gguf|Q1_0|3.80|16384|5.00|1.0|0|auto|?|precisa-fork|?|Bonsai-27B-Q1_0.gguf||Quant Q1_0_g128 exige o fork da PrismML do llama.cpp. O arquivo que estava baixado (dspark-bf16) era o DRAFTER de 3.6B, nao o modelo. Ver TODO fase 6.
deepseek|bartowski/DeepSeek-Coder-V2-Lite-Instruct-GGUF|Q4_K_M|9.11|16384|6.55|6.0|20|16|nao|reprovado|28.4|DeepSeek-Coder-V2-Lite-Instruct-Q4_K_M.gguf||NAO faz tool calling: 0/8 nas fixtures, chamadas={} em turno 1 nas oito execucoes. Declarava tools|sim sem validacao. Peso apagado em 04/08.
frontier|unsloth/DeepSeek-V4-Flash-0731-GGUF|UD-IQ1_S|82.50|8192|7.00|15.0|128|128|?|inviavel|?|DeepSeek-V4-Flash-0731-UD-IQ1_S-00001-of-00003.gguf||304 B de parametros, 82.5 GB no menor quant, numa placa de 8 GB. Rodaria por streaming de SSD. O arquivo em disco era um stub de 4 KB.
quality|bartowski/gemma-4-12B-it-GGUF|Q4_K_M|7.30|8192|7.80|1.0|0|auto|sim|naotestado|?|||Gemma 4 12B, denso, aceita imagem. 7.3 GB de pesos em 8 GB de VRAM deixa quase nada para o KV. Este repo mediu 0.7 tok/s e tool calling NAO nesta familia (no Mac). Nome herdado, nunca validado.
tiny|Qwen/Qwen2.5-Coder-3B-Instruct-GGUF|Q4_K_M|2.00|16384|2.90|0.3|0|auto|nao|naotestado|?|||Qwen2.5 Coder 3B. Leve, otimo para autocompletar. Nao faz tool calling.
EOF
}

# ⚠️ NÃO edite as URLs abaixo com `sd`. No `sd`, `$repo` na string de
# substituição é referência a GRUPO DE CAPTURA, não variável de shell — e como
# não existe grupo com esse nome, expande para vazio. Foi assim que a URL virou
# `https://huggingface.co//resolve/main/` e todo download de perfil sem `file`
# explícito quebrou com 404. Ficou latente do commit 7d29e6f até 04/08, porque
# os pesos que interessavam já estavam em disco. Use `python3` para editar
# qualquer coisa com `$` na substituição.
#
# Resolve `repo` + `quant` num nome de arquivo .gguf concreto, via API do HF.
#
# Por que não usar o `-hf` do llama.cpp: o build local pode não ter TLS
# funcionando, e aí o downloader interno falha com
#
#   W get_repo_files: failed to resolve commit for Qwen/Qwen3-8B-GGUF
#   E llama_model_load_from_file_impl: exactly one out metadata, path_model,
#     and file must be defined
#
# — mensagem que não menciona TLS e manda o diagnóstico para o lado errado.
# Resolver aqui com curl elimina a dependência e trata todos os perfis igual.
resolve_hf_file() {
  local repo="$1" quant="$2"
  curl -sf "https://huggingface.co/api/models/$repo" 2>/dev/null | python3 -c "
import json, sys
quant = sys.argv[1].lower()
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
ggufs = [s['rfilename'] for s in data.get('siblings', [])
         if s['rfilename'].lower().endswith('.gguf')]
# Preferir correspondência exata do quant; nunca pegar parte de um split.
exatos = [f for f in ggufs if quant in f.lower() and '-of-' not in f.lower()]
alvo = exatos or [f for f in ggufs if quant in f.lower()]
if not alvo:
    sys.exit(1)
print(sorted(alvo, key=len)[0])
" "$quant" 2>/dev/null || true
}

find_profile() {
  local target="$1"
  while IFS='|' read -r name repo quant file_gb ctx vram_gb ram_gb cpu_moe ngl tools status tps file extra_args desc; do
    if [[ "$name" == "$target" ]]; then
      echo "$name|$repo|$quant|$file_gb|$ctx|$vram_gb|$ram_gb|$cpu_moe|$ngl|$tools|$status|$tps|$file|$extra_args|$desc"
      return 0
    fi
  done < <(get_profiles)
  return 1
}

# ─── comando: setup ─────────────────────────────────────────────────────────────
#
# ATENÇÃO — por que aqui se compila em vez de baixar binário pronto:
#
# O release do llama.cpp NÃO publica build CUDA para Linux. Em b10242 os únicos
# assets CUDA são `bin-win-cuda-12.4-x64.zip` e `-13.3-x64.zip`. Para Linux há
# vulkan, rocm, sycl, openvino e CPU puro — nada de CUDA.
#
# A versão anterior deste script baixava `bin-ubuntu-vulkan-x64.tar.gz` e se
# descrevia como "com CUDA". O Vulkan na 3060 Ti mediu 2.69 tok/s de geração e
# 1-9 tok/s de prefill, com a GPU a 18% de uso. Não é uma diferença de ajuste
# fino: é a diferença entre usável e inutilizável.
#
# Havia um fallback que compilava, mas só se o download falhasse. O download do
# Vulkan sempre teve sucesso, então o caminho de compilação nunca executou.
#
# Detalhes: docs/diagnostico-linux-benchmark.md
#
cmd_setup() {
  local backend="${LLM_BACKEND:-cuda}"
  echo "${B}Configurando llm-server no Linux (llama.cpp, backend: ${CYA}$backend${R}${B})...${R}"
  mkdir -p "$BIN_DIR" "$MODEL_DIR" "$RUN_DIR"

  if command -v nvidia-smi &>/dev/null; then
    echo "${GRN}✓ GPU NVIDIA e drivers detectados.${R}"
    nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
  else
    echo "${YLW}⚠️ AVISO: GPU NVIDIA não foi encontrada com nvidia-smi.${R}"
  fi

  if [[ "$backend" == "vulkan" ]]; then
    setup_prebuilt_vulkan
  else
    setup_build_cuda
  fi

  if [[ -x "$LLAMA_SERVER" ]]; then
    echo "${GRN}✓ llama-server instalado em $LLAMA_SERVER${R}"
    "$LLAMA_SERVER" --version 2>&1 | head -3 || true
    echo ""
    echo "${B}Backends compilados:${R}"
    ls "$BIN_DIR"/libggml-*.so 2>/dev/null | sed 's|.*/libggml-||; s|\.so$||' | tr '\n' ' '
    echo ""
    if ls "$BIN_DIR"/libggml-cuda* &>/dev/null; then
      echo "${GRN}✓ CUDA presente.${R}"
    elif [[ "$backend" == "cuda" ]]; then
      echo "${RED}❌ Compilou, mas sem libggml-cuda. Verifique se o nvcc foi encontrado pelo cmake.${R}"
      exit 1
    fi
  else
    echo "${RED}❌ Erro ao instalar llama-server.${R}"
    exit 1
  fi
}

# Compila com CUDA. Único caminho que entrega aceleração real nesta máquina.
setup_build_cuda() {
  local missing=()
  command -v nvcc  &>/dev/null || missing+=("nvidia-cuda-toolkit (nvcc)")
  command -v cmake &>/dev/null || missing+=("cmake")
  command -v g++   &>/dev/null || missing+=("build-essential (g++)")
  command -v git   &>/dev/null || missing+=("git")

  # Falhar alto e com instrução acionável. Cair no Vulkan em silêncio foi
  # exatamente o defeito que produziu 2.69 tok/s sem ninguém perceber.
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo ""
    echo "${RED}❌ Faltam dependências para compilar com CUDA:${R}"
    printf '   • %s\n' "${missing[@]}"
    echo ""
    echo "${B}Instale (precisa de sudo):${R}"
    echo "   ${CYA}sudo apt update${R}"
    echo "   ${CYA}sudo apt install -y cmake build-essential nvidia-cuda-toolkit${R}"
    echo ""
    echo "Depois rode de novo: ${CYA}./linux/llm-server.sh setup${R}"
    echo ""
    echo "${DIM}Se realmente quiser o build Vulkan precompilado (muito mais lento,${R}"
    echo "${DIM}medido em 2.69 tok/s nesta 3060 Ti): LLM_BACKEND=vulkan ./linux/llm-server.sh setup${R}"
    exit 1
  fi

  local src_dir="$ROOT_DIR/src"
  echo "${B}Compilando llama.cpp com CUDA (10-25 min em $(nproc) cores)...${R}"

  if [[ -d "$src_dir/.git" ]]; then
    echo "Atualizando fonte em $src_dir..."
    git -C "$src_dir" fetch --depth 1 origin master
    git -C "$src_dir" reset --hard origin/master
  else
    rm -rf "$src_dir"
    echo "Clonando llama.cpp..."
    git clone --depth 1 https://github.com/ggml-org/llama.cpp "$src_dir"
  fi

  # CMAKE_CUDA_ARCHITECTURES=86 = Ampere (RTX 30xx). Compilar só a arquitetura
  # alvo corta bastante do tempo de build.
  local cuda_arch="${LLM_CUDA_ARCH:-86}"

  # O nvcc recusa host compiler mais novo do que ele suporta, e o padrão do
  # sistema costuma ser mais novo. No Pop!_OS 24.04: nvcc 12.0 + gcc 13.3 dá
  #
  #   #error -- unsupported GNU version! gcc versions later than 12 are not
  #   supported!
  #
  # Em vez de passar `-allow-unsupported-compiler` e rezar, procura-se o gcc
  # compatível mais novo que esteja instalado. `nvcc` diz o teto na própria
  # mensagem de erro do host_config.h, então lê-se de lá.
  local host_cc="" host_cxx=""
  local max_gnu
  max_gnu=$(grep -oP 'gcc versions later than \K[0-9]+' \
            /usr/include/crt/host_config.h 2>/dev/null | head -1 || true)
  if [[ -n "$max_gnu" ]]; then
    local v
    for ((v = max_gnu; v >= 9; v--)); do
      if command -v "gcc-$v" &>/dev/null && command -v "g++-$v" &>/dev/null; then
        host_cc="$(command -v "gcc-$v")"
        host_cxx="$(command -v "g++-$v")"
        echo "${DIM}nvcc aceita gcc até $max_gnu; usando gcc-$v como host compiler${R}"
        break
      fi
    done
    if [[ -z "$host_cc" ]]; then
      echo "${RED}❌ nvcc aceita no máximo gcc-$max_gnu, e nenhum gcc-<=$max_gnu está instalado.${R}"
      echo "   Instale com: ${CYA}sudo apt install -y gcc-$max_gnu g++-$max_gnu${R}"
      exit 1
    fi
  fi

  local cmake_args=(
    -B "$src_dir/build" -S "$src_dir"
    -DGGML_CUDA=ON
    -DCMAKE_CUDA_ARCHITECTURES="$cuda_arch"
    -DCMAKE_BUILD_TYPE=Release
    -DLLAMA_BUILD_TESTS=OFF
    -DLLAMA_BUILD_EXAMPLES=OFF
    -DLLAMA_CURL=ON
  )
  if [[ -n "$host_cc" ]]; then
    cmake_args+=(
      -DCMAKE_CUDA_HOST_COMPILER="$host_cxx"
      -DCMAKE_C_COMPILER="$host_cc"
      -DCMAKE_CXX_COMPILER="$host_cxx"
    )
  fi

  cmake "${cmake_args[@]}"

  cmake --build "$src_dir/build" --config Release -j"$(nproc)" --target llama-server llama-bench

  # O build espalha binário e .so por bin/ — copiar os dois, senão o
  # llama-server sobe sem encontrar o backend CUDA.
  cp -f "$src_dir/build/bin/llama-server" "$BIN_DIR/"
  cp -f "$src_dir/build/bin/llama-bench" "$BIN_DIR/" 2>/dev/null || true
  cp -f "$src_dir"/build/bin/*.so* "$BIN_DIR/" 2>/dev/null || true
  chmod +x "$BIN_DIR"/llama-* 2>/dev/null || true
}

# Fallback explícito, só via LLM_BACKEND=vulkan. Não é o caminho padrão.
setup_prebuilt_vulkan() {
  echo "${YLW}⚠️ Backend Vulkan: mediu 2.69 tok/s de geração e 1-9 tok/s de prefill${R}"
  echo "${YLW}   nesta RTX 3060 Ti. Use CUDA a menos que tenha um motivo concreto.${R}"

  echo "Buscando a última versão do llama.cpp no GitHub..."
  local tag
  tag=$(curl -s https://api.github.com/repos/ggml-org/llama.cpp/releases/latest \
        | grep '"tag_name":' | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')
  [[ -n "$tag" ]] || { echo "${RED}Não consegui descobrir a última tag.${R}"; exit 1; }

  local url="https://github.com/ggml-org/llama.cpp/releases/download/${tag}/llama-${tag}-bin-ubuntu-vulkan-x64.tar.gz"
  local tmp_tar="/tmp/llama-${tag}.tar.gz"

  echo "Baixando ${tag}..."
  curl -fL "$url" -o "$tmp_tar" || { echo "${RED}Falha no download de $url${R}"; exit 1; }
  tar -xzf "$tmp_tar" -C "$BIN_DIR" --strip-components=1 2>/dev/null || tar -xzf "$tmp_tar" -C "$BIN_DIR"
  rm -f "$tmp_tar"
  chmod +x "$BIN_DIR"/llama-* 2>/dev/null || true
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

  IFS='|' read -r name repo quant file_gb ctx vram_gb ram_gb cpu_moe ngl tools status tps file extra_args desc <<< "$p_data"
  local final_ctx="${CUSTOM_CTX:-$ctx}"

  echo "${B}Subindo llm-server [perfil: ${CYA}$prof_name${R}${B}]...${R}"
  echo "${DIM}Modelo: $repo ($quant) | Ctx: $final_ctx | Host: $BIND_HOST:$PORT${R}"
  echo "${DIM}ngl: ${LLM_NGL:-${ngl:-auto}} | KV: ${LLM_KV_TYPE:-q8_0} | cpu_moe: ${LLM_CPU_MOE:-$cpu_moe}${R}"

  # -ngl e --n-cpu-moe são grandezas DIFERENTES e a versão anterior as confundia:
  #
  #   -ngl N          quantas camadas do modelo vão para a VRAM
  #   --n-cpu-moe N   de quantas camadas os tensores de expert ficam na RAM
  #
  # O código antigo fazia `default_ngl="$cpu_moe"`, então o perfil qwen27b
  # (cpu_moe=24) subia com `-ngl 24 --n-cpu-moe 24`. Efeito no log do servidor:
  #
  #   W common_fit_params: failed to fit params to free device memory:
  #     n_gpu_layers already set by user to 24, abort
  #
  # O valor vem da coluna `ngl` do perfil — ver o comentário em get_profiles
  # para a regra (cpu_moe > 0 exige número explícito; senão, `auto`).
  #
  # Não use 999 como faz o windows/llm-server.ps1: neste build QUALQUER valor
  # explícito desliga o common_fit_params, então 999 não é "reduza se não
  # couber", é "aloque tudo". Testado no qwen27b: ErrorOutOfDeviceMemory.
  local final_ngl="${LLM_NGL:-${ngl:-auto}}"
  local ARGS=(
    "--host" "$BIND_HOST"
    "--port" "$PORT"
    "-c" "$final_ctx"
    "-ngl" "$final_ngl"
    "-np" "1"
    # -ctk/-ctv q8_0 corta o cache KV pela metade — é o que faz 16k de contexto
    # caber em 8 GB de VRAM. Sem isso o KV vai a f16 e o modelo transborda para
    # a RAM, que já está no limite, e daí para o swap (medido: si/so != 0).
    "-ctk" "${LLM_KV_TYPE:-q8_0}"
    "-ctv" "${LLM_KV_TYPE:-q8_0}"
    # flash attention: menos memória e mais velocidade em Ampere.
    "-fa" "on"
    # usa o chat template do próprio modelo (é o default, mas explícito evita
    # regressão silenciosa se o default mudar).
    "--jinja"
    "-a" "$prof_name"
    "--api-key" "$API_KEY"
  )

  # Todo perfil passa por `-m` com caminho local, inclusive os que não declaram
  # `file` — nesses, o nome é resolvido via API do HF. Ver resolve_hf_file().
  local resolved="$file"
  if [[ -z "$resolved" ]]; then
    echo "${DIM}resolvendo arquivo .gguf de $repo ($quant) na API do HF...${R}"
    resolved=$(resolve_hf_file "$repo" "$quant")
    if [[ -z "$resolved" ]]; then
      echo "${RED}❌ Não achei um .gguf com quant '$quant' em $repo.${R}"
      echo "   Verifique em: ${CYA}https://huggingface.co/$repo/tree/main${R}"
      exit 1
    fi
    echo "${DIM}→ $resolved${R}"
  fi

  local model_path="$MODEL_DIR/$resolved"
  if [[ ! -f "$model_path" ]]; then
    echo "${YLW}Baixando peso $resolved...${R}"
    mkdir -p "$(dirname "$model_path")"
    curl -f -C - -L --progress-bar "https://huggingface.co/$repo/resolve/main/$resolved" \
      -o "$model_path" || {
        echo "${RED}❌ Download falhou. Removendo arquivo parcial.${R}"
        rm -f "$model_path"
        exit 1
      }
  fi
  ARGS+=("-m" "$model_path")

  # --n-cpu-moe é o botão que troca VRAM por RAM. Ajustável sem editar o script
  # porque o valor certo depende da máquina concreta e do contexto em uso.
  local final_cpu_moe="${LLM_CPU_MOE:-$cpu_moe}"
  if [[ "$final_cpu_moe" -gt 0 ]]; then
    ARGS+=("--n-cpu-moe" "$final_cpu_moe")
    echo "${DIM}experts na RAM: primeiras $final_cpu_moe camadas (ajuste com LLM_CPU_MOE)${R}"
  fi

  # LLM_REASONING=on|off sobrepõe o `--reasoning` do perfil, para comparar os
  # dois modos no MESMO modelo sem editar a tabela. Sem isso a comparacao exige
  # mexer no perfil entre as rodadas, o que convida a erro.
  case "${LLM_REASONING:-}" in
    on)
      extra_args="${extra_args//--reasoning off/}"
      echo "${DIM}reasoning: LIGADO (sobreposto via LLM_REASONING)${R}"
      ;;
    off)
      extra_args="${extra_args//--reasoning off/} --reasoning off"
      echo "${DIM}reasoning: DESLIGADO (sobreposto via LLM_REASONING)${R}"
      ;;
  esac

  if [[ -n "${extra_args// /}" ]]; then
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

  echo -n "Aguardando o modelo carregar na VRAM/RAM (health check em http://$PROBE_HOST:$PORT/health)... "
  local attempts=0
  while [[ $attempts -lt 60 ]]; do
    if kill -0 "$pid" 2>/dev/null; then
      local code
      code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $API_KEY" "http://$PROBE_HOST:$PORT/health" 2>/dev/null || echo "000")
      if [[ "$code" == "200" ]]; then
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
    sleep 2
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
    -d "$payload" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    print(data["choices"][0]["message"]["content"])
    if "usage" in data:
        u = data["usage"]
        tok = u.get("completion_tokens", 0)
        print("\n--- %s tokens gerados ---" % tok)
except Exception as e:
    print("Erro ao parsear resposta:", e)
'
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
  IFS='|' read -r name repo quant file_gb ctx vram_gb ram_gb cpu_moe ngl tools status tps file extra_args desc <<< "$p_data"

  mkdir -p "$MODEL_DIR"

  local resolved="$file"
  if [[ -z "$resolved" ]]; then
    resolved=$(resolve_hf_file "$repo" "$quant")
    if [[ -z "$resolved" ]]; then
      echo "${RED}❌ Não achei um .gguf com quant '$quant' em $repo.${R}"
      exit 1
    fi
    echo "${DIM}resolvido: $resolved${R}"
  fi

  local model_path="$MODEL_DIR/$resolved"
  if [[ -f "$model_path" ]]; then
    echo "${GRN}✓ Peso já presente: $model_path${R}"
    return 0
  fi

  echo "${B}Baixando peso do perfil '$prof_name' (~$file_gb GB)...${R}"
  # `|| { rm; exit 1 }` importa: a versão anterior deixava arquivo parcial no
  # disco e o `start` seguinte falhava com erro de GGUF corrompido, longe da
  # causa. Falhar aqui, alto, é mais barato.
  if [[ -n "$INHIBIT" ]]; then
    $INHIBIT curl -f -C - -L --progress-bar "https://huggingface.co/$repo/resolve/main/$resolved" -o "$model_path" \
      || { echo "${RED}❌ Download falhou.${R}"; rm -f "$model_path"; exit 1; }
  else
    curl -f -C - -L --progress-bar "https://huggingface.co/$repo/resolve/main/$resolved" -o "$model_path" \
      || { echo "${RED}❌ Download falhou.${R}"; rm -f "$model_path"; exit 1; }
  fi
  echo "${GRN}✓ Download concluído em $model_path${R}"
}

# ─── comando: models ────────────────────────────────────────────────────────────
cmd_models() {
  local verboso=false
  [[ "${1:-}" == "-v" || "${1:-}" == "--verbose" ]] && verboso=true

  local curr_prof=""
  is_running && curr_prof=$(cat "$PROF_FILE" 2>/dev/null || echo "")

  # Larguras fixas e descrição TRUNCADA. A versão anterior imprimia a descrição
  # inteira, e como os vereditos ficaram longos o texto quebrava a linha e
  # destruía o alinhamento — a tabela ficava ilegível. Detalhe completo vai no
  # `-v`, que imprime em blocos em vez de colunas.
  local cols=${COLUMNS:-0}
  [[ "$cols" -lt 40 ]] && cols=$(tput cols 2>/dev/null || echo 100)

  echo ""
  echo "${B}Perfis (Linux/CUDA) — RTX 3060 Ti 8 GB${R}"
  echo ""
  # Cabeçalho de coluna só faz sentido no modo tabela; no -v a saída é em blocos.
  if ! $verboso; then
    printf "${DIM}%-2s %-9s %7s %8s  %-5s %-6s %-13s%s${R}\n" \
           "" "PERFIL" "TOK/S" "PESO" "DISCO" "TOOLS" "ESTADO" "OBSERVAÇÃO"
    printf "${DIM}%s${R}\n" "$(printf '─%.0s' $(seq 1 $((cols>110?110:cols-1))))"
  fi

  # Ordem: o que funciona primeiro. Quem lê a tabela quer decidir, e decidir
  # começa pelo que dá para usar.
  local ordem="ok ruim naotestado precisa-fork reprovado inviavel"
  for filtro in $ordem; do
    while IFS='|' read -r name repo quant file_gb ctx vram_gb ram_gb cpu_moe ngl tools status tps file extra_args desc; do
      [[ "$status" != "$filtro" ]] && continue

      local mark=" "; [[ "$name" == "$curr_prof" ]] && mark="${GRN}▸${R}"

      # DISCO é medido, não declarado: é a diferença entre "existe o perfil" e
      # "existe o peso". Vários perfis aqui têm peso apagado de propósito.
      # Texto SEM cor aqui: printf conta os escapes ANSI como caracteres, então
      # colorir antes de padronizar desalinha a linha toda. Cor entra depois.
      local disco="--" dcor="$RED"
      local alvo="$MODEL_DIR/$file"
      if [[ -n "$file" && -f "$alvo" ]]; then
        disco="ok"; dcor="$GRN"
      elif [[ -z "$file" ]]; then
        disco="hf"; dcor="$DIM"
      fi

      local cor="$R"
      case "$status" in
        ok)        cor="$GRN" ;;
        ruim|naotestado) cor="$YLW" ;;
        *)         cor="$RED" ;;
      esac

      local tcor="$R"
      [[ "$tools" == "nao" || "$tools" == "fragil" ]] && tcor="$DIM"

      if $verboso; then
        printf "\n%b %-9s ${B}%s${R}\n" "$mark" "$name" "$repo ($quant)"
        printf "   %s tok/s · %s GB · ctx %s · ngl %s · cpu_moe %s · tools %s · ${cor}%s${R}\n" \
               "$tps" "$file_gb" "$ctx" "$ngl" "$cpu_moe" "$tools" "$status"
        echo "   $desc" | fold -s -w $((cols-6)) | sed '2,$s/^/   /'
      else
        # 44 colunas de observação cabem em terminal de 110 sem quebrar.
        local obs="$desc"
        local lim=$((cols-58)); [[ $lim -lt 20 ]] && lim=20
        [[ ${#obs} -gt $lim ]] && obs="${obs:0:$((lim-1))}…"
        # Cada campo é padronizado como texto puro e só então recebe cor.
        local f_disco f_tools f_status
        printf -v f_disco  "%-5s" "$disco"
        printf -v f_tools  "%-6s" "$tools"
        printf -v f_status "%-13s" "$status"
        printf "%b %-9s %7s %7sG  ${dcor}%s${R}${tcor}%s${R} ${cor}%s${R}${DIM}%s${R}\n" \
               "$mark" "$name" "$tps" "$file_gb" "$f_disco" "$f_tools" "$f_status" "$obs"
      fi
    done < <(get_profiles)
  done

  echo ""
  printf "${DIM}%s${R}\n" "ESTADO: ok=validado · ruim=nao use como agente · naotestado · reprovado · inviavel · precisa-fork"
  printf "${DIM}%s${R}\n" "DISCO:  ok=peso em disco · --=ausente · hf=baixa da HuggingFace na hora"
  printf "${DIM}%s${R}\n" "TOK/S:  geracao medida NESTA maquina. ▸ = carregado agora."
  printf "${DIM}%s${R}\n" "Detalhe completo: ./linux/llm-server.sh models -v"
  echo ""
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
    cmd_models "${1:-}"
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
