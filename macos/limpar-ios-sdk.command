#!/usr/bin/env bash
#
# limpar-ios-sdk — remove o runtime do simulador iOS que ficou órfão depois de
# desinstalar o Xcode. Recupera ~11 GB.
#
# Roda em dois passos: primeiro mostra o que vai apagar, depois pede confirmação
# e sudo. Nada é removido sem você digitar "sim".
#
# NÃO toca em:
#   /Library/Developer/CommandLineTools  — de onde vem o seu git/clang. Essencial.
#   ~/Library/Android, ~/.gradle         — SDK Android, fora do escopo.

set -uo pipefail

if [[ -t 1 ]]; then
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
  RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'
else
  B=""; DIM=""; R=""; RED=""; GRN=""; YLW=""
fi
say()   { printf '%s\n' "$*"; }
ok()    { printf '%s✓%s %s\n' "$GRN" "$R" "$*"; }
warn()  { printf '%s!%s %s\n' "$YLW" "$R" "$*"; }
die()   { printf '%s✗%s %s\n' "$RED" "$R" "$*" >&2; exit 1; }
head_() { printf '\n%s%s%s\n' "$B" "$*" "$R"; }

ASSET_ROOT="/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime"
SIM_ROOT="/Library/Developer/CoreSimulator"
free_gb() { df -g / | awk 'NR==2 {print $4}'; }

head_ "Estado atual"
printf '  disco livre: %s GB\n' "$(free_gb)"

# ─── 1. o que existe ────────────────────────────────────────────────────────────
head_ "O que será removido"

RUNTIME_MOUNT=""
if mount | grep -q "$SIM_ROOT/Volumes"; then
  RUNTIME_MOUNT="$(mount | grep "$SIM_ROOT/Volumes" | awk '{print $3}' | head -1)"
  printf '  %s runtime montado:%s %s\n' "$DIM" "$R" "$RUNTIME_MOUNT"
fi

ASSET_SIZE=""
if [[ -d "$ASSET_ROOT" ]]; then
  ASSET_SIZE="$(du -sh "$ASSET_ROOT" 2>/dev/null | awk '{print $1}')"
  printf '  %-42s %s\n' "runtime iOS (imagem em disco)" "${ASSET_SIZE:-?}"
fi

DYLD_SIZE=""
if [[ -d "$SIM_ROOT/Caches/dyld" ]]; then
  DYLD_SIZE="$(du -sh "$SIM_ROOT/Caches/dyld" 2>/dev/null | awk '{print $1}')"
  printf '  %-42s %s\n' "cache dyld dos simuladores" "${DYLD_SIZE:-?}"
fi

if [[ -z "$ASSET_SIZE" && -z "$DYLD_SIZE" ]]; then
  ok "Nada a remover — já está limpo."
  exit 0
fi

head_ "Preservado de propósito"
printf '  %-42s %s %s\n' "/Library/Developer/CommandLineTools" \
  "$(du -sh /Library/Developer/CommandLineTools 2>/dev/null | awk '{print $1}')" \
  "${DIM}← seu git vem daqui${R}"

# ─── 2. confirmação ─────────────────────────────────────────────────────────────
head_ "Confirmação"
warn "Isto é irreversível. Para usar simuladores iOS de novo você terá de"
warn "reinstalar o Xcode e baixar o runtime outra vez (vários GB)."

# Sem TTY (rodando por pipe, por hook, ou pelo `!` do Claude Code) o read recebe
# EOF na hora e cancelaria em silêncio, parecendo que o script não funciona.
# Nesse caso exigimos a intenção explícita via --yes.
if [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]]; then
  say "\n${DIM}--yes recebido: prosseguindo sem perguntar.${R}"
elif [[ ! -t 0 ]]; then
  printf '\n'
  warn "Sem terminal interativo — não consigo ler sua confirmação aqui."
  say  "Escolha um dos dois:"
  say  "  ${B}1.${R} Abra o Terminal e rode:  ${B}~/Desktop/limpar-ios-sdk.command${R}"
  say  "  ${B}2.${R} Ou confirme direto:      ${B}~/Desktop/limpar-ios-sdk.command --yes${R}"
  printf '\nNada foi removido.\n'
  exit 0
else
  printf '\n%sDigite %ssim%s para prosseguir: %s' "$B" "$GRN" "$R$B" "$R"
  read -r answer
  [[ "$answer" == "sim" ]] || { printf '\nCancelado. Nada foi removido.\n'; exit 0; }
fi

# O sudo também precisa de terminal para pedir a senha. Se não houver TTY e a
# credencial não estiver em cache, ele falharia no meio da remoção — pior que
# não começar. Checa antes.
if ! sudo -n true 2>/dev/null && [[ ! -t 0 ]]; then
  printf '\n'
  warn "O sudo precisa da sua senha e não há terminal para digitá-la."
  say  "Rode no Terminal:  ${B}~/Desktop/limpar-ios-sdk.command${R}"
  say  "${DIM}(ou autentique antes com 'sudo -v' e rode de novo com --yes)${R}"
  printf '\nNada foi removido.\n'
  exit 0
fi

head_ "Removendo (vai pedir sua senha)"

# ─── 3. desmontar o runtime ─────────────────────────────────────────────────────
if [[ -n "$RUNTIME_MOUNT" ]]; then
  printf 'Desmontando %s\n' "$RUNTIME_MOUNT"
  sudo diskutil unmount force "$RUNTIME_MOUNT" >/dev/null 2>&1 \
    && ok "desmontado" || warn "não desmontou — segue mesmo assim"
  # A imagem fica atachada como disco sintetizado; solta para liberar o arquivo.
  for d in $(hdiutil info 2>/dev/null | awk '/^\/dev\/disk/ {print $1}'); do
    hdiutil detach "$d" -force >/dev/null 2>&1 || true
  done
fi

# ─── 4. remover o asset ─────────────────────────────────────────────────────────
if [[ -d "$ASSET_ROOT" ]]; then
  printf 'Removendo runtime iOS (%s)\n' "${ASSET_SIZE:-?}"
  sudo rm -rf "$ASSET_ROOT" && ok "runtime removido" || warn "falhou — veja SIP"
fi

# ─── 5. remover o cache dyld ────────────────────────────────────────────────────
if [[ -d "$SIM_ROOT/Caches/dyld" ]]; then
  printf 'Removendo cache dyld (%s)\n' "${DYLD_SIZE:-?}"
  sudo rm -rf "$SIM_ROOT/Caches/dyld" && ok "cache removido" || warn "falhou"
fi

# Restos vazios da árvore de simuladores.
sudo rm -rf "$SIM_ROOT/Volumes"/* "$SIM_ROOT/Images"/* 2>/dev/null || true

head_ "Resultado"
printf '  disco livre agora: %s GB\n' "$(free_gb)"
ok "Pronto."
printf '\n%sSe um dia precisar de simuladores iOS: reinstale o Xcode pela App Store.%s\n' "$DIM" "$R"
