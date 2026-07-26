#!/usr/bin/env bash
#
# clean.sh — libera espaço no macOS mostrando ANTES o que vai apagar.
#
#   ./clean.sh                  relatório: o que existe e quanto ocupa (não apaga nada)
#   ./clean.sh --apply          apaga só a categoria SEGURA (caches regeneráveis)
#   ./clean.sh --apply --projects   inclui builds e node_modules dos projetos
#   ./clean.sh --apply --all    seguro + projetos (não inclui os itens MANUAIS)
#
# Filosofia: dry-run por padrão. Um script de limpeza que apaga sem mostrar é
# uma bomba, não uma ferramenta.
#
# O QUE ESTE SCRIPT NÃO FAZ, DE PROPÓSITO:
#   - Não apaga ~/.pub-cache. Não é lixo: é o cache de dependências do Dart.
#     Apagar não libera espaço permanente, só força re-download de tudo em todos
#     os projetos. Se você realmente quiser, use 'dart pub cache clean'.
#   - Não toca em ~/Library/Application Support/* (perfis, não caches).
#   - Não toca em Docker, SDK Android nem versões do fvm: são decisões suas.
#     Eles aparecem na seção MANUAL com o comando pronto.

set -uo pipefail

# Onde ficam seus repositórios. Só é usado na varredura de builds/node_modules.
# Ajuste com a variável de ambiente ou o argumento --projects-dir.
PROJECTS_DIR="${PROJECTS_DIR:-$HOME/code}"

APPLY=0; DO_PROJECTS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)         APPLY=1 ;;
    --projects)      DO_PROJECTS=1 ;;
    --all)           DO_PROJECTS=1 ;;
    --projects-dir)  shift; PROJECTS_DIR="${1:-$PROJECTS_DIR}" ;;
    -h|--help)       sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'Argumento desconhecido: %s\n' "$1" >&2; exit 1 ;;
  esac
  shift
done

# Se o diretório configurado não existe, tenta os nomes mais comuns antes de
# desistir — melhor que varrer o $HOME inteiro, que demora e acha lixo demais.
if [[ ! -d "$PROJECTS_DIR" ]]; then
  for d in "$HOME/code" "$HOME/dev" "$HOME/projects" "$HOME/src" "$HOME/work" "$HOME/wk" "$HOME/Developer"; do
    [[ -d "$d" ]] && { PROJECTS_DIR="$d"; break; }
  done
fi

if [[ -t 1 ]]; then
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
  RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; CYA=$'\033[36m'
else
  B=""; DIM=""; R=""; RED=""; GRN=""; YLW=""; CYA=""
fi
say()   { printf '%s\n' "$*"; }
ok()    { printf '%s✓%s %s\n' "$GRN" "$R" "$*"; }
warn()  { printf '%s!%s %s\n' "$YLW" "$R" "$*"; }
head_() { printf '\n%s%s%s\n' "$B" "$*" "$R"; }

TOTAL_KB=0        # soma do que É elegível nesta execução
FREED_KB=0        # soma do que foi realmente apagado

free_gb()  { df -g / | awk 'NR==2 {print $4}'; }
size_kb()  { du -sk "$1" 2>/dev/null | cut -f1; }
human()    { awk -v k="${1:-0}" 'BEGIN{ if (k>1048576) printf "%.1f GB",k/1048576; else if (k>1024) printf "%.0f MB",k/1024; else printf "%d KB",k }'; }

# Relata um alvo e, se --apply e categoria habilitada, remove.
#   $1 rótulo · $2 caminho · $3 categoria(safe|project) · $4 comando-oficial (opcional)
target() {
  local label="$1" path="$2" cat="$3" official="${4:-}" kb
  [[ -e "$path" ]] || return 0
  kb="$(size_kb "$path")"; kb="${kb:-0}"
  [[ "$kb" -lt 1024 ]] && return 0     # ignora ninharia (<1 MB)

  local eligible=0
  case "$cat" in
    safe)    eligible=1 ;;
    project) [[ "$DO_PROJECTS" -eq 1 ]] && eligible=1 ;;
  esac

  if [[ "$eligible" -eq 1 ]]; then
    TOTAL_KB=$((TOTAL_KB + kb))
    printf '  %s%-9s%s %-42s %s\n' "$CYA" "$(human "$kb")" "$R" "$label" "${DIM}${path/#$HOME/~}${R}"
    if [[ "$APPLY" -eq 1 ]]; then
      if [[ -n "$official" ]] && eval "$official" >/dev/null 2>&1; then
        : # comando oficial cuidou (mais seguro que rm -rf)
      else
        rm -rf "$path" 2>/dev/null
      fi
      local after; after="$(size_kb "$path")"; after="${after:-0}"
      FREED_KB=$((FREED_KB + kb - after))
    fi
  else
    printf '  %s%-9s %-42s %s(use --projects)%s\n' "$DIM" "$(human "$kb")" "$label" "$DIM" "$R"
  fi
}

# ─── cabeçalho ──────────────────────────────────────────────────────────────────
if [[ "$APPLY" -eq 1 ]]; then
  head_ "LIMPANDO  ${DIM}(disco livre agora: $(free_gb) GB)${R}"
else
  head_ "RELATÓRIO — nada será apagado  ${DIM}(disco livre: $(free_gb) GB)${R}"
  say "${DIM}Para executar: ./clean.sh --apply${R}"
fi

# ─── 1. caches de gerenciadores de pacote ──────────────────────────────────────
head_ "Caches de gerenciadores  ${DIM}(regeneram sozinhos)${R}"
target "cache do uv (Python)"      "$HOME/.cache/uv"                        safe "uv cache clean"
target "cache do npm"              "$HOME/.npm"                             safe "npm cache clean --force"
target "store do pnpm"             "$HOME/Library/pnpm/store"               safe "pnpm store prune"
target "cache do Homebrew"         "$HOME/Library/Caches/Homebrew"          safe "brew cleanup -s"
target "cache do Gradle"           "$HOME/.gradle/caches"                   safe
target "cache do node-gyp"         "$HOME/Library/Caches/node-gyp"          safe
target "cache do pip"              "$HOME/Library/Caches/pip"               safe "pip3 cache purge"
target "cache do CocoaPods"        "$HOME/Library/Caches/CocoaPods"         safe

# ─── 2. caches de aplicativos ──────────────────────────────────────────────────
head_ "Caches de aplicativos  ${DIM}(o app rebaixa o que precisar)${R}"
target "cache do Chrome"           "$HOME/Library/Caches/Google"            safe
target "instaladores antigos VSCode" "$HOME/Library/Caches/com.microsoft.VSCode.ShipIt" safe
target "browsers do Playwright"    "$HOME/Library/Caches/ms-playwright"     safe
target "updater do RedisInsight"   "$HOME/Library/Caches/redisinsight-updater" safe
target "cache do WebKit"           "$HOME/Library/WebKit"                   safe

# ─── 3. restos de Xcode ────────────────────────────────────────────────────────
head_ "Restos de Xcode"
target "DerivedData"               "$HOME/Library/Developer/Xcode/DerivedData" safe
target "Archives"                  "$HOME/Library/Developer/Xcode/Archives" safe
target "cache do Xcode"            "$HOME/Library/Caches/com.apple.dt.Xcode" safe
target "simuladores (devices)"     "$HOME/Library/Developer/CoreSimulator/Devices" safe
if command -v xcrun >/dev/null && xcrun simctl help >/dev/null 2>&1; then
  [[ "$APPLY" -eq 1 ]] && xcrun simctl delete unavailable >/dev/null 2>&1
else
  say "  ${DIM}simctl indisponível (Xcode desinstalado) — nada a fazer aqui${R}"
fi

# ─── 4. logs e diagnósticos ────────────────────────────────────────────────────
head_ "Logs e diagnósticos"
target "relatórios de diagnóstico" "$HOME/Library/Logs/DiagnosticReports"   safe
target "logs de usuário"           "$HOME/Library/Logs/JetBrains"           safe

# ─── 5. builds dos projetos ────────────────────────────────────────────────────
head_ "Builds dos projetos  ${DIM}(regeneram, mas custam um rebuild)${R}"
# Descoberta dinâmica: paths fixos apodrecem quando você renomeia ou cria projeto.
#
# -I (--no-ignore) é ESSENCIAL: sem ele o fd respeita o .gitignore, e justamente
# os maiores alvos (.dart_tool, node_modules, build, Pods) estão ignorados no git.
# Sem essa flag o script relata quase nada e parece que não há o que limpar.
if command -v fd >/dev/null; then
  scan() {  # $1 = regex do diretório · $2 = rótulo · $3 = profundidade
    while IFS= read -r d; do
      target "$2: $(basename "$(dirname "$d")")" "$d" project
    done < <(fd -t d -H -I "$1" "$PROJECTS_DIR" --max-depth "${3:-3}" 2>/dev/null)
  }
  scan '^\.dart_tool$'  ".dart_tool" 3    # derivado do Flutter — o maior de todos
  scan '^build$'        "build"      3
  scan '^node_modules$' "node_modules" 3
  scan '^Pods$'         "Pods"       4
  scan '^\.next$'       ".next"      3
else
  warn "fd não instalado (brew install fd) — pulando descoberta de builds"
fi
[[ "$DO_PROJECTS" -eq 0 ]] && say "  ${DIM}Some com --projects. Depois: flutter pub get / npm install para restaurar.${R}"

# ─── 6. decisões suas (nunca automático) ───────────────────────────────────────
head_ "${YLW}MANUAL${R} ${DIM}— o script não mexe nisso; decida você${R}"
manual() {  # $1 rótulo · $2 caminho · $3 como resolver
  [[ -e "$2" ]] || return 0
  local kb; kb="$(size_kb "$2")"
  printf '  %s%-9s%s %-30s %s\n' "$YLW" "$(human "${kb:-0}")" "$R" "$1" "${DIM}${2/#$HOME/~}${R}"
  printf '            %s→ %s%s\n' "$DIM" "$3" "$R"
}
manual "Docker Desktop"  "$HOME/Library/Containers/com.docker.docker" \
       "se não usa Docker, desinstale pelo app; senão: docker system prune -a"
manual "SDK Android"     "$HOME/Library/Android" \
       "necessário se compila Flutter/Android; remova SDKs de versões velhas pelo Android Studio"
manual "versões do fvm"  "$HOME/fvm/versions" \
       "fvm list, e 'fvm remove <versão>' nas que não usa"
manual "perfil do Chrome" "$HOME/Library/Application Support/Google" \
       "é perfil (histórico, extensões), NÃO cache — limpe pelo próprio Chrome"
manual "runtime iOS"     "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime" \
       "~/Desktop/limpar-ios-sdk.command (precisa de sudo)"

# ─── fecho ─────────────────────────────────────────────────────────────────────
if [[ "$APPLY" -eq 1 ]]; then
  head_ "Resultado"
  ok "liberado: ${B}$(human "$FREED_KB")${R}"
  say "  disco livre: ${B}$(free_gb) GB${R}"
  [[ "$DO_PROJECTS" -eq 1 ]] && warn "Builds removidos: rode 'flutter pub get' / 'npm install' nos projetos."
else
  head_ "Total elegível"
  say "  ${B}$(human "$TOTAL_KB")${R} nesta seleção"
  printf '\n  %s./clean.sh --apply%s             limpa os caches seguros\n' "$B" "$R"
  printf '  %s./clean.sh --apply --projects%s  inclui builds, .dart_tool e node_modules\n' "$B" "$R"
fi
say ""
