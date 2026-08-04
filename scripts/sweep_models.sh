#!/usr/bin/env bash
#
# Roda as tarefas agênticas em vários perfis e monta uma tabela comparativa.
#
# É o primeiro teste capaz de ORDENAR modelos. As suítes anteriores davam 100%
# para todos, então não separavam nada.
#
# Uso:
#   scripts/sweep_models.sh                          # perfis default
#   scripts/sweep_models.sh agent deepseek           # só estes
#   REPEATS=1 TASKS="timeline_midnight" scripts/sweep_models.sh bonsai
#
# Cada perfil é carregado uma vez e roda todas as tarefas, porque trocar de
# modelo custa minutos — o inverso (tarefa por fora, modelo por dentro) pagaria
# a carga N vezes.

set -uo pipefail   # sem -e: falha de um perfil não pode abortar a varredura

cd "$(dirname "$0")/.." || exit 1

: "${LLM_HOST:=192.168.3.51}"
: "${LLM_SSH_KEY:=$HOME/.ssh/id_ed25519_windows}"
: "${LLM_REMOTE:=lellis@$LLM_HOST}"
: "${REPEATS:=2}"
: "${TEMPERATURE:=0.6}"
: "${CTX:=32768}"
: "${TASKS:=timeline_midnight product_unavailable booking_horizon pwa_ios_starturl}"
export LLM_HOST

PERFIS=("$@")
if [[ ${#PERFIS[@]} -eq 0 ]]; then
  # qwen27b fora: 3.1 tok/s, uma varredura completa passaria de horas para um
  # resultado já conhecido. moe primeiro para servir de referência.
  # bonsai fora: o quant Q1_0_g128 exige o fork da PrismML do llama.cpp, entao
  # ele nao carrega aqui de jeito nenhum. Ver TODO 6.1.
  PERFIS=(moe agent deepseek)
fi

SAIDA="benchmark-report/sweep-modelos.md"
mkdir -p benchmark-report
: > /tmp/sweep_raw.tsv

ssh_run() { ssh -o ConnectTimeout=10 -i "$LLM_SSH_KEY" "$LLM_REMOTE" "$@"; }

echo "═══ varredura: ${#PERFIS[@]} perfis × $(echo $TASKS | wc -w | tr -d ' ') tarefas × $REPEATS repetições"
echo

for perfil in "${PERFIS[@]}"; do
  echo "████████ $perfil"

  # Carga do modelo. Falha aqui é resultado, não erro do script: o `bonsai`
  # nunca subiu com sucesso em nenhuma bateria anterior, e saber ISSO importa.
  if ! ssh_run "cd ~/local-llm-lab && LLM_CTX=$CTX ./linux/llm-server.sh restart $perfil --lan" \
       > /tmp/sweep_load_$perfil.log 2>&1; then
    echo "  ❌ NAO CARREGOU. Ultimas linhas do log:"
    ssh_run "tail -8 ~/.local/share/llm-server/run/server.log" | sd '^' '     '
    for t in $TASKS; do printf '%s\t%s\tNAO_CARREGOU\t-\t-\n' "$perfil" "$t" >> /tmp/sweep_raw.tsv; done
    echo
    continue
  fi

  # Registra o que o servidor DE FATO decidiu, e a arquitetura real do modelo.
  # O nome do arquivo mente às vezes: "Bonsai-27B" pesa 6.79 GB em bf16, o que
  # dá ~3.4 B de parâmetros e não 27 B.
  cmdline=$(ssh_run "ps -eo args | grep '[l]lama-server'" | grep -oE '\-(ngl|c|ctk) [^ ]+|--n-cpu-moe [0-9]+' | tr '\n' ' ')
  arq=$(ssh_run "grep -aiE 'n_params|n_expert|block_count|arch ' ~/.local/share/llm-server/run/server.log | head -4" | sd '^\s*' '')
  echo "  cmdline: $cmdline"
  [[ -n "$arq" ]] && echo "$arq" | sd '^' '  meta: '

  # tok/s de referência, para cruzar velocidade com acerto.
  #
  # ATENÇÃO na extração: o `bench` imprime "Geração:" TAMBÉM em cada linha de
  # rodada, e nessa linha o primeiro decimal é o Prefill:
  #
  #   [Rodada 1/3] Prefill: 9.3 tok/s | Geração: 2.7 tok/s | Tempo: 192.81s
  #
  # Pegar "o primeiro numero depois de Geração:" devolvia o prefill — o `agent`
  # apareceu com 276 tok/s de "geração" quando o real é 73. A linha do resumo é
  # a unica que começa com espaços + "Geração:", sem prefixo de rodada.
  ssh_run "cd ~/local-llm-lab && ./linux/llm-server.sh bench 3" > /tmp/sweep_bench_$perfil.log 2>&1
  tps=$(rg -o '^\s+Geração:\s+([0-9.]+)' -r '$1' /tmp/sweep_bench_$perfil.log | tail -1)
  pfl=$(rg -o '^\s+Prefill:\s+([0-9.]+)' -r '$1' /tmp/sweep_bench_$perfil.log | tail -1)
  echo "  geração: ${tps:-?} tok/s | prefill: ${pfl:-?} tok/s"

  for tarefa in $TASKS; do
    printf '  %-22s ' "$tarefa"
    log=/tmp/sweep_${perfil}_${tarefa}.log
    if ! python3 -u scripts/bench_agentic.py "$tarefa" --modelo "$perfil" \
         --temperature "$TEMPERATURE" --repeats "$REPEATS" -q > "$log" 2>&1; then
      : # exit != 0 só quer dizer "nenhum acerto"; o placar abaixo é a medida
    fi
    taxa=$(rg -o 'pass@k = (\d+/\d+)' -r '$1' "$log" 2>/dev/null | tail -1)
    [[ -z "$taxa" ]] && taxa=$(rg -o 'taxa = (\d+/\d+)' -r '$1' "$log" 2>/dev/null | tail -1)
    placar=$(rg -o 'testes: (\S+ . \S+)' -r '$1' "$log" 2>/dev/null | tail -1)
    toks=$(rg -o 'tokens (\d+)' -r '$1' "$log" 2>/dev/null | sort -n | tail -1)
    if [[ -z "$taxa" ]]; then
      motivo=$(rg -o 'REPROVADO — (.{0,45})' -r '$1' "$log" 2>/dev/null | head -1)
      echo "sem medida  ${motivo:-ver $log}"
      printf '%s\t%s\tSEM_MEDIDA\t%s\t-\n' "$perfil" "$tarefa" "${motivo:-?}" >> /tmp/sweep_raw.tsv
    else
      echo "$taxa   ($placar, até $toks tokens)"
      printf '%s\t%s\t%s\t%s\t%s\n' "$perfil" "$tarefa" "$taxa" "${placar:--}" "${toks:--}" >> /tmp/sweep_raw.tsv
    fi
  done
  printf '%s\tTPS\t%s\t-\t-\n' "$perfil" "${tps:-?}" >> /tmp/sweep_raw.tsv
  echo
done

# ─── tabela ─────────────────────────────────────────────────────────────────────
{
  echo "# Varredura de modelos nas tarefas agênticas"
  echo
  echo "Tarefas construídas a partir de bugfixes reais do Beahub. Critério é o teste"
  echo "automatizado do próprio commit — verde ou vermelho, sem juiz."
  echo
  echo "\`--temperature $TEMPERATURE --repeats $REPEATS\`, ctx $CTX."
  echo
  printf '| perfil | tok/s |'
  for t in $TASKS; do printf ' %s |' "$t"; done; echo
  printf '|---|---|'
  for t in $TASKS; do printf '---|'; done; echo
  for p in "${PERFIS[@]}"; do
    tps=$(rg "^$p\tTPS\t" /tmp/sweep_raw.tsv | cut -f3 | tail -1)
    printf '| `%s` | %s |' "$p" "${tps:-—}"
    for t in $TASKS; do
      v=$(rg "^$p\t$t\t" /tmp/sweep_raw.tsv | cut -f3 | tail -1)
      printf ' %s |' "${v:-—}"
    done
    echo
  done
  echo
  echo "Detalhe por execução em \`/tmp/sweep_<perfil>_<tarefa>.log\`."
} > "$SAIDA"

echo "═══ tabela em $SAIDA"
cat "$SAIDA"
