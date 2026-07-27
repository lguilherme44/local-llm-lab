#!/usr/bin/env bash
#
# llm-server — sobe um LLM local servido em HTTP (API compatível com OpenAI) via MLX.
#
# Duplo-clique no Finder  -> sobe o perfil padrão.
# Pelo terminal           -> ./llm-server.command <comando> [perfil]
#
#   start [perfil]   sobe o servidor (padrão: fast)
#   stop             derruba o servidor e libera a memória
#   restart [perfil] troca de modelo
#   status           mostra se está no ar, memória real, swap
#   logs             acompanha o log ao vivo
#   ask "..."        manda uma pergunta e imprime a resposta
#   chat [perfil]    conversa no terminal, sem servidor HTTP
#   models           lista os perfis e quais já estão baixados
#   pull <perfil>    só baixa os pesos
#   bench [perfil]   mede tokens/s de verdade nesta máquina
#   tune             mostra o ajuste de memória de GPU (precisa de sudo)
#
# Hardware alvo: MacBook Air M4, 16 GB de memória unificada, sem ventoinha.

set -uo pipefail

# ─── ajustes ────────────────────────────────────────────────────────────────────
PORT="${LLM_PORT:-8080}"
HOST="127.0.0.1"          # só local. mlx_vlm.server usa 0.0.0.0 por padrão —
                          # este script força localhost de propósito.
DEFAULT_PROFILE="agent"

RUN_DIR="$HOME/.local/state/llm-server"
PID_FILE="$RUN_DIR/server.pid"
LOG_FILE="$RUN_DIR/server.log"
PROFILE_FILE="$RUN_DIR/current-profile"

BIN_DIR="$HOME/.local/bin"
HF_CACHE="$HOME/.cache/huggingface/hub"

# ─── biblioteca externa (SSD removível) ─────────────────────────────────────────
# Modelos podem morar num disco externo para poupar o SSD interno. Regra de ouro:
# NADA que o sistema precise para funcionar vai para o externo — só pesos de
# modelo. Assim, desconectar o disco no meio do dia não quebra nada: no pior caso
# um perfil fica indisponível, com mensagem clara e sugestão do que usar.
#
# Defina LLM_EXT para fixar o caminho; sem isso, procura o primeiro
# /Volumes/*/llm-models existente.
#
# O caminho detectado é PERSISTIDO em ext-root. Isso é essencial: com o disco
# desconectado, /Volumes/*/llm-models não casa com nada, o script esqueceria que
# existe uma biblioteca externa e rebaixaria os pesos do zero — 8 GB por engano.
# Lembrando o caminho, ele sabe distinguir "não existe" de "está desconectado".
EXT_STATE="$RUN_DIR/ext-root"
EXT_ROOT="${LLM_EXT:-}"
if [[ -z "$EXT_ROOT" ]]; then
  for v in /Volumes/*/llm-models; do
    [[ -d "$v" ]] && { EXT_ROOT="$v"; break; }
  done
fi
if [[ -n "$EXT_ROOT" ]]; then
  mkdir -p "$RUN_DIR" 2>/dev/null
  printf '%s' "$EXT_ROOT" > "$EXT_STATE" 2>/dev/null
elif [[ -f "$EXT_STATE" ]]; then
  EXT_ROOT="$(cat "$EXT_STATE" 2>/dev/null)"   # conhecido, porém desconectado
fi
EXT_CACHE="${EXT_ROOT:+$EXT_ROOT/hf/hub}"

# ─── perfis ─────────────────────────────────────────────────────────────────────
# Em 16 GB unificados o teto prático de pesos é ~9 GB. Acima disso o macOS comprime
# e swapa, e a geração desaba.
#
# A coluna "engine" importa: mlx_lm só entende arquiteturas de texto puro.
# O Gemma 4 é gemma4_unified (multimodal) e SÓ carrega no mlx_vlm — no mlx_lm ele
# falha com "Model type gemma4_unified not supported" e o servidor fica pendurado.
#
#  perfil | repo | pesos | engine | descrição
# Os tok/s abaixo foram MEDIDOS neste Air M4 de 16 GB, com uso normal de apps.
# A queda de 'agent'/'fast' para 'quality' não é gradual: é um precipício. Quando
# os pesos não caibam na RAM livre, cada token espera disco e a taxa desaba ~28x.
#
# A coluna "tools" diz se o modelo emite tool_calls estruturado — o que decide se
# ele serve como AGENTE (pi, Cline, Aider) ou só como chat/autocomplete.
# Testado com scripts/test-tools: Qwen2.5-Coder emite a tag errada (<tools> em vez
# de <tool_call>) e o campo tool_calls volta null. O fine-tune para código
# degradou o tool calling. Qwen3-8B faz o ciclo completo.
#
#  perfil | repo | pesos | engine | tools | flags extras | descrição
profiles() {
  cat <<'EOF'
agent|mlx-community/Qwen3-8B-4bit|4.6|lm|sim|--chat-template-args {"enable_thinking":false}|Qwen3 8B. O único aqui que faz tool calling de verdade — use para pi/Cline/Aider. ~16-19 tok/s. Padrão.
fast|mlx-community/Qwen2.5-Coder-7B-Instruct-4bit|4.3|lm|nao||Qwen2.5 Coder 7B. Especialista em código, ~20 tok/s. Melhor para chat/edit no VSCode, NÃO serve como agente.
balanced|mlx-community/Qwen2.5-Coder-14B-Instruct-4bit|8.3|lm|nao||Qwen2.5 Coder 14B. Código melhor, mas só com apps fechados. Sem tool calling.
quality|mlx-community/gemma-4-12B-it-qat-OptiQ-4bit|9.0|vlm|?|--kv-bits 8|Gemma 4 12B (QAT + OptiQ), aceita imagens. Medido a 0.7 tok/s com apps abertos: exige liberar RAM de verdade.
tiny|mlx-community/mini-coder-4b-OptiQ-4bit|3.0|lm|?||Código, 4B. O mais leve — para autocomplete e para rodar junto de tudo aberto.
EOF
}

# ─── cores ──────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
  RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLU=$'\033[34m'; CYA=$'\033[36m'
else
  B=""; DIM=""; R=""; RED=""; GRN=""; YLW=""; BLU=""; CYA=""
fi
say()   { printf '%s\n' "$*"; }
ok()    { printf '%s✓%s %s\n' "$GRN" "$R" "$*"; }
warn()  { printf '%s!%s %s\n' "$YLW" "$R" "$*"; }
die()   { printf '%s✗%s %s\n' "$RED" "$R" "$*" >&2; exit 1; }
head_() { printf '\n%s%s%s\n' "$B" "$*" "$R"; }

# ─── helpers ────────────────────────────────────────────────────────────────────
# campos: 1=perfil 2=repo 3=pesos(GB) 4=engine 5=tools 6=flags-extras 7=descrição
pf() { profiles | awk -F'|' -v p="$1" -v f="$2" '$1==p {print $f}'; }

cache_dir_of() { printf '%s/models--%s' "$HF_CACHE" "${1//\//--}"; }
ext_dir_of()   { [[ -n "$EXT_CACHE" ]] && printf '%s/models--%s' "$EXT_CACHE" "${1//\//--}"; }

ext_mounted() { [[ -n "$EXT_ROOT" && -d "$EXT_ROOT" ]]; }

has_weights() {  # $1 = diretório de cache de um repo
  [[ -n "$1" && -d "$1" ]] && [[ -n "$(find "$1" -name '*.safetensors' -print -quit 2>/dev/null)" ]]
}

is_downloaded()     { has_weights "$(cache_dir_of "$1")"; }
is_downloaded_ext() { ext_mounted && has_weights "$(ext_dir_of "$1")"; }
is_available()      { is_downloaded "$1" || is_downloaded_ext "$1"; }

# Onde o modelo está: int, ext, ou vazio.
location_of() {
  is_downloaded "$1"     && { printf 'int'; return; }
  is_downloaded_ext "$1" && { printf 'ext'; return; }
  printf ''
}

# Para usar um modelo que vive no disco externo, aponte HF_HOME para o cache de
# lá e passe o repo id normalmente.
#
# NÃO passe o caminho do snapshot em --model: os SERVIDORES (mlx_lm.server e
# mlx_vlm.server) re-registram o modelo no cache padrão quando recebem um path,
# copiando os pesos de volta para o disco interno — some o ganho todo. Medido:
# 2,8 GB reapareceram no interno após um único start. (mlx_lm.generate e
# mlx_vlm.generate não fazem isso; é específico dos servers.)
hf_home_for() {
  local repo="$1"
  if ! is_downloaded "$repo" && is_downloaded_ext "$repo"; then
    printf '%s' "$EXT_ROOT/hf"
  fi
}

free_ram_gb() {
  local ps free inactive
  ps=$(sysctl -n hw.pagesize)
  free=$(vm_stat | awk '/Pages free/         {gsub(/\./,"",$3); print $3}')
  inactive=$(vm_stat | awk '/Pages inactive/ {gsub(/\./,"",$3); print $3}')
  awk -v p="$ps" -v f="${free:-0}" -v i="${inactive:-0}" 'BEGIN{printf "%.1f",(f+i)*p/1073741824}'
}

free_disk_gb() { df -g "$HOME" | awk 'NR==2 {print $4}'; }

server_pid() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid; pid="$(cat "$PID_FILE" 2>/dev/null)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && printf '%s' "$pid"
}

port_busy() { lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; }

resolve_profile() {
  local p="${1:-$DEFAULT_PROFILE}"
  [[ -n "$(pf "$p" 2)" ]] || die "Perfil desconhecido: '$p'. Rode: $(basename "$0") models"
  printf '%s' "$p"
}

engine_bin() {  # $1 = engine (lm|vlm), $2 = subcomando (server|chat)
  case "$1" in
    lm)  printf '%s/mlx_lm.%s'  "$BIN_DIR" "$2" ;;
    vlm) printf '%s/mlx_vlm.%s' "$BIN_DIR" "$2" ;;
    *)   die "engine inválido no perfil: '$1'" ;;
  esac
}

require_engine() {
  local bin; bin="$(engine_bin "$1" server)"
  [[ -x "$bin" ]] || die "Falta $(basename "$bin"). Instale: uv tool install --python 3.12 mlx-$1"
  [[ -x "$BIN_DIR/hf" ]] || die "Falta 'hf'. Instale: uv tool install --python 3.12 huggingface_hub"
}

# ─── gestão de modelos ──────────────────────────────────────────────────────────
# Tudo que mexe no cache passa pelo 'hf cache', não por rm -rf: ele entende a
# estrutura de blobs/snapshots/refs e não deixa lixo nem referência quebrada.

human_gb() { awk -v k="${1:-0}" 'BEGIN{ if (k>1048576) printf "%.1f GB",k/1048576; else printf "%.0f MB",k/1024 }'; }

cache_size_kb() {
  local d; d="$(cache_dir_of "$1")"
  [[ -d "$d" ]] || { printf '0'; return; }
  du -sk "$d" 2>/dev/null | cut -f1
}

# Todos os repos presentes no cache, um por linha.
cached_repos() {
  "$BIN_DIR/hf" cache ls --json 2>/dev/null | python3 -c "
import sys, json
try:
    for r in json.load(sys.stdin):
        if r.get('repo_type') == 'model': print(r['repo_id'])
except Exception:
    pass
"
}

repo_is_profile() {  # $1 = repo → 0 se pertence a algum perfil
  profiles | awk -F'|' -v r="$1" '$2==r {found=1} END{exit !found}'
}

profile_of_repo() { profiles | awk -F'|' -v r="$1" '$2==r {print $1; exit}'; }

# Repo atualmente carregado pelo servidor (vazio se parado).
loaded_repo() {
  server_pid >/dev/null || return 0
  local p; p="$(cat "$PROFILE_FILE" 2>/dev/null)"
  [[ -n "$p" ]] && pf "$p" 2
}

# Aceita nome de perfil OU repo completo e devolve sempre o repo.
resolve_target() {
  local t="${1:-}"
  [[ -n "$t" ]] || return 1
  local as_profile; as_profile="$(pf "$t" 2)"
  if [[ -n "$as_profile" ]]; then printf '%s' "$as_profile"; return 0; fi
  # Se não é perfil, exige forma org/repo para não apagar coisa errada por typo.
  [[ "$t" == */* ]] || return 1
  printf '%s' "$t"
}

# ─── comandos ───────────────────────────────────────────────────────────────────
cmd_models() {
  local cur total_kb=0 kb
  cur="$(loaded_repo)"

  head_ "Perfis"
  printf '%s%-9s %-8s %-6s %-6s %-11s %s%s\n' \
    "$DIM" "PERFIL" "EM DISCO" "ENGINE" "TOOLS" "ESTADO" "MODELO" "$R"
  while IFS='|' read -r name repo size engine tools extra desc; do
    local state color tcolor disk loc
    loc="$(location_of "$repo")"
    if [[ "$loc" == "int" ]]; then
      kb="$(cache_size_kb "$repo")"; total_kb=$((total_kb + kb))
      disk="$(human_gb "$kb")"
      if [[ "$repo" == "$cur" ]]; then state="EM USO"; color="$BLU"
      else state="interno"; color="$GRN"; fi
    elif [[ "$loc" == "ext" ]]; then
      kb="$(du -sk "$(ext_dir_of "$repo")" 2>/dev/null | cut -f1)"
      disk="$(human_gb "${kb:-0}")"
      if [[ "$repo" == "$cur" ]]; then state="EM USO/ext"; color="$BLU"
      else state="EXTERNO"; color="$CYA"; fi
    else
      # ASCII de propósito: printf conta BYTES, e um travessão UTF-8 ocupa 3,
      # desalinhando a coluna inteira.
      disk="-"; state="ausente"; color="$DIM"
    fi
    case "$tools" in sim) tcolor="$GRN" ;; nao) tcolor="$RED" ;; *) tcolor="$DIM" ;; esac
    printf '%s%-9s%s %-8s %-6s %s%-6s%s %s%-11s%s %s\n' \
      "$B" "$name" "$R" "$disk" "$engine" "$tcolor" "$tools" "$R" "$color" "$state" "$R" "$repo"
    printf '          %s%s%s\n' "$DIM" "$desc" "$R"
  done < <(profiles)

  # Modelos que estão no disco mas não pertencem a perfil nenhum. Sem esta seção
  # eles ocupariam espaço invisível: o 'models' antigo só conhecia os perfis.
  local extras=0
  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    repo_is_profile "$repo" && continue
    if [[ "$extras" -eq 0 ]]; then
      head_ "Outros modelos no cache  ${DIM}(fora dos perfis)${R}"
      extras=1
    fi
    kb="$(cache_size_kb "$repo")"; total_kb=$((total_kb + kb))
    printf '  %s%-8s%s %s\n' "$CYA" "$(human_gb "$kb")" "$R" "$repo"
  done < <(cached_repos)

  head_ "Disco"
  printf '  modelos no interno: %s%s%s · livre no interno: %s%s GB%s\n' \
    "$B" "$(human_gb "$total_kb")" "$R" "$B" "$(free_disk_gb)" "$R"
  if ext_mounted; then
    printf '  disco externo: %s%s%s (livre %s GB)\n' \
      "$CYA" "$EXT_ROOT" "$R" "$(df -g "$EXT_ROOT" 2>/dev/null | awk 'NR==2 {print $4}')"
  elif [[ -n "$EXT_ROOT" ]]; then
    printf '  %sdisco externo configurado mas NÃO montado: %s%s\n' "$YLW" "$EXT_ROOT" "$R"
  fi
  printf '\n%sPadrão: %s · RAM livre: %s GB%s\n' "$DIM" "$DEFAULT_PROFILE" "$(free_ram_gb)" "$R"
  printf '%sTOOLS=sim -> serve como agente (pi, Cline). TOOLS=nao -> só chat/edit.%s\n' "$DIM" "$R"
  printf '\n%sBaixar:  %s add <org/repo>%s   %sRemover: %s rm <perfil|org/repo>%s\n' \
    "$DIM" "$(basename "$0")" "$R" "$DIM" "$(basename "$0")" "$R"
}

cmd_rm() {
  local t repo kb cur
  t="${1:-}"
  [[ -n "$t" ]] || die "Uso: $(basename "$0") rm <perfil|org/repo>   (veja: $(basename "$0") models)"
  repo="$(resolve_target "$t")" || die "Não reconheci '$t'. Use um nome de perfil ou 'org/repo'."

  is_downloaded "$repo" || die "'$repo' não está no cache — nada a remover."

  # Remover o modelo que o servidor tem carregado deixaria o processo servindo
  # arquivos que já não existem. Derrube primeiro.
  cur="$(loaded_repo)"
  if [[ "$repo" == "$cur" ]]; then
    warn "'$repo' está EM USO pelo servidor (PID $(server_pid))."
    say  "Derrube antes: $(basename "$0") stop"
    exit 1
  fi

  kb="$(cache_size_kb "$repo")"
  head_ "Remover modelo"
  printf '  %s%s%s\n' "$B" "$repo" "$R"
  printf '  libera: %s%s%s\n' "$CYA" "$(human_gb "$kb")" "$R"
  local prof; prof="$(profile_of_repo "$repo")"
  [[ -n "$prof" ]] && say "  ${DIM}é o perfil '$prof' — pode rebaixar depois com: $(basename "$0") pull $prof${R}"

  if [[ "${2:-}" != "--yes" && "${2:-}" != "-y" ]]; then
    if [[ ! -t 0 ]]; then
      warn "Sem terminal interativo para confirmar. Repita com --yes."
      exit 0
    fi
    printf '\n%sConfirma remover? (s/N): %s' "$B" "$R"
    local a; read -r a
    [[ "$a" =~ ^[sSyY] ]] || { say "Cancelado."; exit 0; }
  fi

  "$BIN_DIR/hf" cache rm "model/$repo" --yes >/dev/null 2>&1 \
    || die "Falha ao remover. Tente: hf cache rm model/$repo"
  ok "Removido. Disco livre: $(free_disk_gb) GB"
}

cmd_add() {
  local repo="${1:-}"
  [[ -n "$repo" ]] || die "Uso: $(basename "$0") add <org/repo>   ex: add mlx-community/Qwen3-14B-4bit"
  [[ "$repo" == */* ]] || die "Informe no formato org/repo (ex: mlx-community/Qwen3-14B-4bit)."
  [[ -x "$BIN_DIR/hf" ]] || die "Falta 'hf'. Instale: uv tool install --python 3.12 huggingface_hub"

  is_downloaded "$repo" && { ok "'$repo' já está no cache."; return 0; }

  # Descobrir tipo e tamanho ANTES de baixar: evita puxar 20 GB para descobrir
  # que não cabe, ou que é um repo PyTorch que o MLX nem carrega.
  head_ "Verificando $repo"
  local info
  info="$(curl -fsS "https://huggingface.co/api/models/${repo}?blobs=true" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print('ERRO|repo não encontrado no Hugging Face'); raise SystemExit
sib = d.get('siblings') or []
names = [f['rfilename'] for f in sib]
total = sum((f.get('size') or 0) for f in sib)
mtype = (d.get('config') or {}).get('model_type', '?')
has_mlx = any(n.endswith('.safetensors') for n in names)
has_gguf = any(n.endswith('.gguf') for n in names)
kind = 'mlx' if has_mlx else ('gguf' if has_gguf else 'desconhecido')
print(f\"OK|{total/1073741824:.2f}|{mtype}|{kind}\")
")"
  [[ -n "$info" ]] || die "Não consegui consultar o Hugging Face (sem rede?)."
  IFS='|' read -r st a b c <<< "$info"
  [[ "$st" == "OK" ]] || die "$a"

  local size_gb="$a" mtype="$b" kind="$c"
  say "  tamanho: ${B}${size_gb} GB${R} · model_type: ${B}${mtype}${R} · formato: ${B}${kind}${R}"

  if [[ "$kind" == "gguf" ]]; then
    warn "Este repo é GGUF — formato do llama.cpp, não do MLX."
    say  "Use com: llama-server -hf $repo   (brew install llama.cpp)"
    exit 1
  fi
  [[ "$kind" == "mlx" ]] && : || die "Sem .safetensors: não é um repo que o MLX carregue."

  # Qual engine roda este model_type. mlx_lm só entende texto puro; multimodais
  # (gemma3n, gemma4_unified, qwen2_vl…) exigem mlx_vlm.
  # Os Pythons isolados que o 'uv tool' criou para cada engine.
  local UV_TOOLS="$HOME/.local/share/uv/tools"
  local engine="lm"
  if [[ -x "$UV_TOOLS/mlx-lm/bin/python" ]] && "$UV_TOOLS/mlx-lm/bin/python" -c "
import sys, pkgutil, mlx_lm.models as m
sys.exit(0 if '$mtype' in {x.name for x in pkgutil.iter_modules(m.__path__)} else 1)
" 2>/dev/null; then
    engine="lm"
  elif [[ -x "$UV_TOOLS/mlx-vlm/bin/python" ]] && "$UV_TOOLS/mlx-vlm/bin/python" -c "
import sys, pkgutil, mlx_vlm.models as m
sys.exit(0 if '$mtype' in {x.name for x in pkgutil.iter_modules(m.__path__)} else 1)
" 2>/dev/null; then
    engine="vlm"
  else
    warn "model_type '$mtype' não aparece em nenhum dos dois engines."
    warn "Pode não carregar. Baixando de todo jeito — teste com mlx_lm.server primeiro."
    engine="lm"
  fi
  say "  engine sugerido: ${B}mlx_${engine}${R}"

  local avail; avail="$(free_disk_gb)"
  awk -v n="$size_gb" -v a="$avail" 'BEGIN{exit !(a < n + 3)}' \
    && die "Disco insuficiente: precisa ~${size_gb} GB (+3 de folga), há ${avail} GB."

  head_ "Baixando"
  "$BIN_DIR/hf" download "$repo" || die "Falha no download."
  ok "Pronto. Rode direto sem editar o script:"
  say ""
  say "  ${B}mlx_${engine}.server --model $repo --host 127.0.0.1 --port $PORT${R}"
  say ""
  say "${DIM}Para virar um perfil fixo, adicione esta linha em profiles() no topo do script:${R}"
  say "${DIM}  meu-perfil|$repo|${size_gb}|$engine|?||Descrição sua.${R}"
}

# Move os pesos entre o cache interno e o disco externo.
#
# O cache do Hugging Face guarda os arquivos em blobs/ e cria SYMLINKS RELATIVOS
# em snapshots/ apontando para eles. Uma cópia que siga os symlinks duplica o
# tamanho (4,3 GB viram 8,6 GB). Por isso rsync -a, que preserva os links.
move_model() {  # $1 = repo · $2 = origem · $3 = destino · $4 = rótulo
  local repo="$1" src="$2" dst_root="$3" label="$4" kb need avail
  [[ -d "$src" ]] || die "Não achei os pesos em $src"

  kb="$(du -sk "$src" 2>/dev/null | cut -f1)"
  need=$(( kb / 1048576 + 2 ))
  avail="$(df -g "$dst_root" 2>/dev/null | awk 'NR==2 {print $4}')"
  [[ -n "$avail" ]] && [[ "$avail" -lt "$need" ]] \
    && die "Espaço insuficiente no destino: precisa ~${need} GB, há ${avail} GB."

  head_ "Movendo para $label"
  say "  $repo · $(human_gb "$kb")"
  mkdir -p "$dst_root"
  local dst="$dst_root/$(basename "$src")"

  # -a preserva symlinks; --delete garante que uma tentativa anterior parcial
  # não deixe restos que passem na verificação.
  rsync -a --delete "$src/" "$dst/" || die "Falha ao copiar."

  has_weights "$dst" || die "Cópia incompleta em $dst — origem preservada."
  rm -rf "$src"
  ok "Movido. Interno livre: $(free_disk_gb) GB"
}

cmd_archive() {
  local t repo cur
  t="${1:-}"
  [[ -n "$t" ]] || die "Uso: $(basename "$0") archive <perfil|org/repo>"
  ext_mounted || die "Disco externo não montado. Conecte-o (ou defina LLM_EXT)."
  repo="$(resolve_target "$t")" || die "Não reconheci '$t'."

  is_downloaded "$repo" || die "'$repo' não está no cache interno."
  cur="$(loaded_repo)"
  [[ "$repo" == "$cur" ]] && die "'$repo' está EM USO. Rode '$(basename "$0") stop' antes."

  mkdir -p "$EXT_CACHE"
  move_model "$repo" "$(cache_dir_of "$repo")" "$EXT_CACHE" "o disco externo"
  say "${DIM}Para usar sem o disco conectado, traga de volta: $(basename "$0") restore $t${R}"
}

cmd_restore() {
  local t repo
  t="${1:-}"
  [[ -n "$t" ]] || die "Uso: $(basename "$0") restore <perfil|org/repo>"
  ext_mounted || die "Disco externo não montado. Conecte-o primeiro."
  repo="$(resolve_target "$t")" || die "Não reconheci '$t'."

  is_downloaded "$repo" && { ok "'$repo' já está no disco interno."; return 0; }
  is_downloaded_ext "$repo" || die "'$repo' não está no disco externo."

  move_model "$repo" "$(ext_dir_of "$repo")" "$HF_CACHE" "o disco interno"
}

# Mede o disco externo e diz se vale guardar modelos nele. A conclusão depende
# só da velocidade: abaixo de ~100 MB/s o tempo de carga domina tudo.
cmd_extbench() {
  ext_mounted || die "Disco externo não montado (procuro /Volumes/*/llm-models ou \$LLM_EXT)."

  head_ "Medindo $EXT_ROOT"
  local t="$EXT_ROOT/.speedtest" w r
  say "${DIM}escrevendo 1 GB...${R}"
  w=$(dd if=/dev/zero of="$t" bs=1m count=1024 2>&1 | rg -o '[0-9]+ bytes/sec' | rg -o '^[0-9]+')

  # Limpar o cache de página exige sudo. Sem isso a leitura sai da RAM e mede
  # 20+ GB/s — número impossível para USB, que denuncia a medição inválida.
  local purged=0
  sync
  if sudo -n purge >/dev/null 2>&1; then purged=1; fi

  say "${DIM}lendo 1 GB...${R}"
  r=$(dd if="$t" of=/dev/null bs=1m 2>&1 | rg -o '[0-9]+ bytes/sec' | rg -o '^[0-9]+')
  rm -f "$t"

  local wmb rmb
  wmb=$(awk -v v="${w:-0}" 'BEGIN{printf "%.0f", v/1048576}')
  rmb=$(awk -v v="${r:-0}" 'BEGIN{printf "%.0f", v/1048576}')

  # Sanidade: nenhum barramento USB passa de ~2 GB/s. Acima disso é cache.
  local read_valid=1
  [[ "${rmb:-0}" -gt 2000 ]] && read_valid=0

  printf '  escrita: %s%s MB/s%s\n' "$B" "$wmb" "$R"
  if [[ "$read_valid" -eq 1 ]]; then
    printf '  leitura: %s%s MB/s%s\n' "$B" "$rmb" "$R"
  else
    printf '  leitura: %s%s MB/s — INVÁLIDO (veio do cache de RAM)%s\n' "$YLW" "$rmb" "$R"
    [[ "$purged" -eq 0 ]] && say "  ${DIM}para medir leitura de verdade: sudo -v && $(basename "$0") extbench${R}"
    say  "  ${DIM}usando a escrita como referência — nesses cases ela acompanha a leitura${R}"
    rmb="$wmb"
  fi

  # Estimativa de carga para um modelo de 5 GB. O carregamento real fica abaixo do
  # dd sequencial, porque ler pesos não é acesso linear (medimos ~50% do dd).
  local est
  est=$(awk -v v="${rmb:-1}" 'BEGIN{ if (v<1) v=1; printf "%.0f", 5120/(v*0.5)}')
  printf '  carga estimada de um modelo de 5 GB: ~%ss\n' "$est"

  head_ "Veredito"
  if [[ "${rmb:-0}" -lt 100 ]]; then
    warn "Abaixo de 100 MB/s: use o externo só para ARQUIVO (modelos que quase nunca sobe)."
    say  "  Modelos de trabalho devem ficar no disco interno."
    printf "\n  %sSe esperava mais: confira se o disco está atrás de um hub lento:%s\n" "$DIM" "$R"
    say  "  ${DIM}ioreg -p IOUSB -w0 | rg -i 'hub|product name'${R}"
    say  "  ${DIM}Um SSD rápido num hub USB 2.0 entrega ~40 MB/s. Ligue direto no Mac.${R}"
  else
    ok "Rápido o suficiente para guardar modelos que você usa de vez em quando."
    say "  ${DIM}Arquive os grandes: $(basename "$0") archive <perfil>${R}"
  fi
}

cmd_gc() {
  head_ "Faxina no cache"
  [[ -x "$BIN_DIR/hf" ]] || die "Falta 'hf'."

  # prune tira revisões soltas e downloads interrompidos — lixo puro, sem escolha
  # a fazer. Um .downloadInProgress de 4 GB é comum depois de um Ctrl-C.
  say "${DIM}removendo revisões detached e downloads incompletos...${R}"
  "$BIN_DIR/hf" cache prune --yes 2>/dev/null | tail -2

  local cur; cur="$(loaded_repo)"
  local found=0 total=0 kb
  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    repo_is_profile "$repo" && continue
    [[ "$repo" == "$cur" ]] && continue
    if [[ "$found" -eq 0 ]]; then
      head_ "Modelos fora dos perfis"
      found=1
    fi
    kb="$(cache_size_kb "$repo")"; total=$((total + kb))
    printf '  %s%-8s%s %s\n' "$CYA" "$(human_gb "$kb")" "$R" "$repo"
  done < <(cached_repos)

  if [[ "$found" -eq 0 ]]; then
    ok "Nada fora dos perfis. Disco livre: $(free_disk_gb) GB"
    return 0
  fi
  # say() usa printf '%s' e NÃO interpreta \n — precisa ser printf de verdade.
  printf '\n  total: %s%s%s\n' "$B" "$(human_gb "$total")" "$R"
  say "${DIM}Remova o que não quiser com: $(basename "$0") rm <org/repo>${R}"
  say "${DIM}(o gc não apaga modelos por conta própria — a escolha é sua)${R}"
}

cmd_pull() {
  local profile repo size avail
  profile="$(resolve_profile "${1:-}")" || exit 1
  repo="$(pf "$profile" 2)"; size="$(pf "$profile" 3)"

  is_downloaded "$repo" && { ok "$profile já baixado"; return 0; }

  avail="$(free_disk_gb)"
  awk -v n="$size" -v a="$avail" 'BEGIN{exit !(a < n + 3)}' \
    && die "Disco insuficiente: precisa ~${size} GB (+3 de folga), há ${avail} GB."

  head_ "Baixando $profile — ${size} GB"
  say "${DIM}$repo${R}"
  "$BIN_DIR/hf" download "$repo" || die "Falha no download."
  ok "Pesos prontos."
}

# Health check de verdade: mlx_*.server responde /v1/models ANTES de carregar
# os pesos (lazy loading). Só uma geração real prova que o modelo subiu.
# Todo o progresso vai para stderr: stdout carrega SÓ o número de segundos, porque
# quem chama captura via $(...). Misturar os dois faz o texto virar argumento de
# aritmética mais adiante.
wait_until_ready() {
  local pid="$1" repo="$2" timeout="${3:-210}" i started
  started=$SECONDS
  printf '%sCarregando pesos (a 1ª geração é a lenta)' "$DIM" >&2
  for i in $(seq 1 "$timeout"); do
    if ! kill -0 "$pid" 2>/dev/null; then
      printf '%s\n' "$R" >&2; return 2
    fi
    if grep -qE 'not supported|Traceback|ValueError|OSError' "$LOG_FILE" 2>/dev/null; then
      printf '%s\n' "$R" >&2; return 3
    fi
    # O campo "model" é obrigatório no mlx_vlm.server (ele é multi-modelo e valida
    # com Pydantic: sem ele devolve 422 para sempre). O mlx_lm.server aceita igual.
    if curl -fsS --max-time 8 "http://$HOST:$PORT/v1/chat/completions" \
         -H 'Content-Type: application/json' \
         -d "{\"model\":\"$repo\",\"messages\":[{\"role\":\"user\",\"content\":\"ok\"}],\"max_tokens\":1}" \
         >/dev/null 2>&1; then
      printf '%s\n' "$R" >&2
      printf '%s' "$(( SECONDS - started ))"
      return 0
    fi
    printf '.' >&2; sleep 2
  done
  printf '%s\n' "$R" >&2; return 1
}

cmd_start() {
  mkdir -p "$RUN_DIR"
  local profile repo size engine extra
  profile="$(resolve_profile "${1:-}")" || exit 1
  repo="$(pf "$profile" 2)"; size="$(pf "$profile" 3)"; engine="$(pf "$profile" 4)"
  extra="$(pf "$profile" 6)"
  require_engine "$engine"

  # read -ra divide por espaço SEM expansão de brace/glob — necessário porque as
  # flags extras carregam JSON literal ({"enable_thinking":false}).
  #
  # ATENÇÃO ao expandir isto adiante: o macOS traz bash 3.2, onde "${arr[@]}" de
  # um array VAZIO dispara "unbound variable" sob set -u. A forma segura é
  # "${arr[@]+"${arr[@]}"}" — sem ela, todo perfil sem flags extras quebra.
  local -a extra_args=()
  [[ -n "$extra" ]] && read -ra extra_args <<< "$extra"

  local pid
  if pid="$(server_pid)"; then
    warn "Já rodando (PID $pid · perfil $(cat "$PROFILE_FILE" 2>/dev/null || echo '?')) em http://$HOST:$PORT"
    say  "Para trocar: $(basename "$0") restart $profile"
    return 0
  fi
  port_busy && die "Porta $PORT ocupada por outro processo. Use: LLM_PORT=8081 $(basename "$0") start"

  # Se o perfil vive no disco externo e ele não está montado, avise em vez de
  # rebaixar 5 GB por engano. E diga o que está disponível agora.
  if ! is_available "$repo"; then
    if [[ -n "$EXT_ROOT" ]] && ! ext_mounted; then
      warn "O disco externo ($EXT_ROOT) não está montado."
      say  "Se '$profile' estiver arquivado nele, reconecte o disco."
      local disp
      disp="$(profiles | awk -F'|' '{print $1}' | while read -r p; do
                is_downloaded "$(pf "$p" 2)" && printf '%s ' "$p"; done)"
      [[ -n "$disp" ]] && say "Disponíveis no disco interno: ${B}${disp}${R}"
      say "Ou rebaixe para o interno: $(basename "$0") pull $profile"
      exit 1
    fi
    cmd_pull "$profile" || exit 1
  fi

  local hf_home; hf_home="$(hf_home_for "$repo")"

  local avail; avail="$(free_ram_gb)"
  if awk -v w="$size" -v a="$avail" 'BEGIN{exit !(a < w + 1.5)}'; then
    warn "RAM livre (${avail} GB) é justa para ${size} GB de pesos — vai swapar."
    warn "Feche apps, ou use um perfil menor: $(basename "$0") start tiny"
  fi

  if [[ -n "$hf_home" ]]; then
    warn "Lendo do disco EXTERNO — a subida é mais lenta que do interno."
    say  "${DIM}Para uso frequente, traga de volta: $(basename "$0") restore $profile${R}"
  fi

  head_ "Subindo $profile em http://$HOST:$PORT"
  say "${DIM}$repo · engine mlx_$engine${R}"
  : > "$LOG_FILE"

  # Otimizações para 16 GB sem ventoinha. As flags divergem entre os dois engines.
  if [[ "$engine" == "vlm" ]]; then
    #  --max-kv-size 8192  teto do cache KV, evita crescer até engolir a RAM
    #  --prefill-step-size reduz o pico de memória ao processar o prompt
    nohup env ${hf_home:+HF_HOME="$hf_home"} "$(engine_bin vlm server)" \
      --model "$repo" \
      --host "$HOST" --port "$PORT" \
      --max-tokens 4096 \
      --max-kv-size 8192 \
      --prefill-step-size 1024 \
      --log-level WARNING \
      "${extra_args[@]+"${extra_args[@]}"}" \
      >"$LOG_FILE" 2>&1 &
  else
    #  --temp 0.0            determinístico: o que se quer em código
    #  --prompt-cache-*      reaproveita o prefixo entre pedidos, com teto de 1.5 GB.
    #                        Medido: prompt repetido de 3.5k tokens cai de 20s para
    #                        0.8s. É o que torna agente local viável.
    nohup env ${hf_home:+HF_HOME="$hf_home"} "$(engine_bin lm server)" \
      --model "$repo" \
      --host "$HOST" --port "$PORT" \
      --temp 0.0 \
      --max-tokens 4096 \
      --prefill-step-size 1024 \
      --prompt-cache-size 2 \
      --prompt-cache-bytes 1500000000 \
      --log-level WARNING \
      "${extra_args[@]+"${extra_args[@]}"}" \
      >"$LOG_FILE" 2>&1 &
  fi

  pid=$!
  printf '%s' "$pid"     > "$PID_FILE"
  printf '%s' "$profile" > "$PROFILE_FILE"

  local secs rc
  secs="$(wait_until_ready "$pid" "$repo" 210)"; rc=$?
  case "$rc" in
    0) ok "No ar em ${secs}s — http://$HOST:$PORT"; cmd_usage_hint ;;
    2) say "${RED}O servidor morreu ao subir:${R}"; tail -20 "$LOG_FILE"
       rm -f "$PID_FILE" "$PROFILE_FILE"; die "Falha ao carregar $repo." ;;
    3) say "${RED}Erro fatal no log:${R}"; grep -E 'not supported|Error|Traceback' "$LOG_FILE" | tail -5
       kill -9 "$pid" 2>/dev/null; rm -f "$PID_FILE" "$PROFILE_FILE"
       die "O modelo não é compatível com o engine mlx_$engine." ;;
    *) warn "Sem resposta em 7min. Processo vivo (PID $pid). Veja: $(basename "$0") logs" ;;
  esac
}

cmd_usage_hint() {
  head_ "Como usar"
  cat <<EOF
${DIM}# pergunta rápida pelo próprio script${R}
./$(basename "$0") ask "Escreva um debounce genérico em TypeScript"

${DIM}# qualquer cliente compatível com OpenAI (Continue, Zed, Aider, SDKs)${R}
export OPENAI_BASE_URL=http://$HOST:$PORT/v1
export OPENAI_API_KEY=nao-usado

${DIM}# gerenciar${R}
./$(basename "$0") status    ./$(basename "$0") logs    ./$(basename "$0") stop
EOF
  printf '\n%sO modelo fica residente: a carga é paga uma vez, não a cada pedido.%s\n' "$DIM" "$R"
  printf '%sEste Air não tem ventoinha — em uso contínuo o clock cai por calor.%s\n' "$DIM" "$R"
}

cmd_ask() {
  local q="${1:-}" profile repo
  [[ -n "$q" ]] || die "Uso: $(basename "$0") ask \"sua pergunta\""
  server_pid >/dev/null || die "Servidor parado. Suba com: $(basename "$0") start"
  profile="$(cat "$PROFILE_FILE" 2>/dev/null || printf '%s' "$DEFAULT_PROFILE")"
  repo="$(pf "$profile" 2)"
  python3 - "$q" "$HOST" "$PORT" "$repo" <<'PY'
import json, sys, time, urllib.error, urllib.request
q, host, port, model = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
body = json.dumps({"model": model,
                   "messages": [{"role": "user", "content": q}],
                   "max_tokens": 2048}).encode()
req = urllib.request.Request(f"http://{host}:{port}/v1/chat/completions",
                             data=body, headers={"Content-Type": "application/json"})
t0 = time.time()
try:
    with urllib.request.urlopen(req, timeout=1800) as r:
        d = json.load(r)
except urllib.error.HTTPError as e:
    print(f"\033[31mHTTP {e.code}\033[0m: {e.read().decode()[:400]}", file=sys.stderr)
    sys.exit(1)
dt = time.time() - t0
txt = d["choices"][0]["message"]["content"] or ""
# Alguns modelos vazam o token de fim de turno na resposta.
for tok in ("<|im_end|>", "<end_of_turn>", "<|endoftext|>", "<eos>"):
    txt = txt.replace(tok, "")
print(txt.rstrip())
u = d.get("usage") or {}
n = u.get("completion_tokens")
extra = f" · {n/dt:.1f} tok/s" if n and dt > 0 else ""
print(f"\n\033[2m[{dt:.1f}s{extra}]\033[0m", file=sys.stderr)
PY
}

cmd_bench() {
  server_pid >/dev/null || die "Servidor parado. Suba com: $(basename "$0") start"
  head_ "Medindo nesta máquina"
  say "${DIM}perfil: $(cat "$PROFILE_FILE" 2>/dev/null || echo '?')${R}"
  cmd_ask "Implemente quicksort em Python com comentários curtos." >/dev/null
}

cmd_stop() {
  local pid i
  if pid="$(server_pid)"; then
    kill "$pid" 2>/dev/null
    for i in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    rm -f "$PID_FILE" "$PROFILE_FILE"
    ok "Derrubado (PID $pid). Memória liberada."
  else
    rm -f "$PID_FILE" "$PROFILE_FILE"
    say "Nada rodando."
    port_busy && warn "Porta $PORT ocupada por processo externo: lsof -nP -iTCP:$PORT -sTCP:LISTEN"
  fi
}

cmd_restart() { cmd_stop; sleep 1; cmd_start "${1:-}"; }

cmd_status() {
  head_ "Estado"
  local pid
  if pid="$(server_pid)"; then
    ok "No ar — PID $pid · perfil $(cat "$PROFILE_FILE" 2>/dev/null || echo '?') · http://$HOST:$PORT"
    # Atenção: o RSS NÃO mede os pesos. O MLX aloca em buffers Metal na memória
    # unificada, que não entram no RSS — um modelo de 9 GB carregado aparece aqui
    # como ~0.02 GB. Quem conta de verdade é a RAM livre e o swap abaixo.
    ps -o rss=,etime=,%cpu= -p "$pid" 2>/dev/null \
      | awk '{printf "  rss: %.2f GB %s· no ar há: %s · cpu: %s%%\n",$1/1048576,"(sem buffers Metal) ",$2,$3}'
  else
    say "  parado."
    port_busy && warn "porta $PORT ocupada por processo externo"
  fi
  printf '  RAM livre: %s GB · disco livre: %s GB\n' "$(free_ram_gb)" "$(free_disk_gb)"
  sysctl -n vm.swapusage 2>/dev/null | sed 's/^/  swap: /'
}

cmd_logs() {
  [[ -f "$LOG_FILE" ]] || die "Sem log em $LOG_FILE"
  say "${DIM}$LOG_FILE — Ctrl-C para sair${R}"
  tail -f "$LOG_FILE"
}

cmd_chat() {
  local profile repo engine
  profile="$(resolve_profile "${1:-}")" || exit 1
  repo="$(pf "$profile" 2)"; engine="$(pf "$profile" 4)"
  require_engine "$engine"
  is_downloaded "$repo" || cmd_pull "$profile" || exit 1
  warn "Chat direto recarrega os pesos a cada sessão. Para uso repetido, prefira 'start'."
  if [[ "$engine" == "lm" ]]; then
    exec "$(engine_bin lm chat)"  --model "$repo" --temp 0.0
  else
    exec "$(engine_bin vlm chat)" --model "$repo"
  fi
}

cmd_tune() {
  head_ "Ajuste de memória de GPU (opcional, precisa de sudo)"
  local cur total sugg
  cur=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)
  total=$(( $(sysctl -n hw.memsize) / 1048576 ))
  sugg=$(( total * 80 / 100 ))
  cat <<EOF
  RAM total: ${total} MB
  iogpu.wired_limit_mb atual: ${cur}  ${DIM}(0 = padrão do sistema, ~70%)${R}

  Elevar esse teto deixa o MLX manter mais peso na GPU em vez de comprimir/swapar.
  É volátil — volta ao normal ao reiniciar. Rode você, precisa de sudo:

    ${B}sudo sysctl iogpu.wired_limit_mb=${sugg}${R}

  ${YLW}Cuidado:${R} valores altos deixam pouca RAM para o macOS e podem travar o
  sistema sob pressão. Reverter sem reiniciar: sudo sysctl iogpu.wired_limit_mb=0
EOF
}

cmd_help() {
  cat <<EOF
${B}llm-server${R} — LLM local em HTTP via MLX (API compatível com OpenAI)

  ${B}start${R} [perfil]     sobe o servidor (padrão: $DEFAULT_PROFILE)
  ${B}stop${R}               derruba e libera memória
  ${B}restart${R} [perfil]   troca de modelo
  ${B}status${R}             estado, memória residente, swap
  ${B}logs${R}               acompanha o log
  ${B}ask${R} "..."          pergunta e imprime a resposta com tok/s
  ${B}chat${R} [perfil]      conversa no terminal, sem HTTP
  ${B}models${R}             perfis, o que está no disco e quanto ocupa
  ${B}pull${R} <perfil>      baixa os pesos de um perfil
  ${B}add${R} <org/repo>     baixa qualquer modelo MLX do Hugging Face
  ${B}rm${R} <perfil|repo>   remove um modelo do disco
  ${B}archive${R} <perfil>   move os pesos para o disco externo (libera o interno)
  ${B}restore${R} <perfil>   traz os pesos de volta para o interno (para viajar)
  ${B}gc${R}                 tira downloads incompletos e lista o que está fora dos perfis
  ${B}bench${R}              mede tokens/s reais aqui
  ${B}tune${R}               ajuste de memória de GPU

Porta: $PORT ${DIM}(altere com LLM_PORT=8081)${R} · escuta só em $HOST
EOF
}

# ─── entrada ────────────────────────────────────────────────────────────────────
cd "$(dirname "${BASH_SOURCE[0]}")" || true

INTERACTIVE_LAUNCH=0
if [[ $# -eq 0 ]]; then INTERACTIVE_LAUNCH=1; set -- start; fi

case "${1:-start}" in
  start)          shift || true; cmd_start   "${1:-}" ;;
  stop)           cmd_stop ;;
  restart)        shift || true; cmd_restart "${1:-}" ;;
  status)         cmd_status ;;
  logs)           cmd_logs ;;
  ask)            shift || true; cmd_ask     "${*:-}" ;;
  bench)          cmd_bench ;;
  chat)           shift || true; cmd_chat    "${1:-}" ;;
  models|list)    cmd_models ;;
  pull)           shift || true; cmd_pull    "${1:-}" ;;
  add|download)   shift || true; cmd_add     "${1:-}" ;;
  rm|remove|del)  shift || true; cmd_rm      "${1:-}" "${2:-}" ;;
  archive)        shift || true; cmd_archive "${1:-}" ;;
  restore)        shift || true; cmd_restore "${1:-}" ;;
  extbench)       cmd_extbench ;;
  gc|prune)       cmd_gc ;;
  tune)           cmd_tune ;;
  help|-h|--help) cmd_help ;;
  *)              die "Comando desconhecido: '$1'. Rode: $(basename "$0") help" ;;
esac

if [[ "$INTERACTIVE_LAUNCH" -eq 1 ]]; then
  printf '\n%sPode fechar esta janela — o servidor continua no ar.%s\n' "$DIM" "$R"
  printf '%sPara derrubar: ./%s stop%s\n' "$DIM" "$(basename "$0")" "$R"
fi
