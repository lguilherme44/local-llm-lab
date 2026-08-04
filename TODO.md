# TODO — correção do ambiente Linux e da suíte de benchmarks

Contexto e evidência: [`docs/diagnostico-linux-benchmark.md`](docs/diagnostico-linux-benchmark.md)

A ordem importa. Refazer estatística antes de corrigir o backend é medir com régua torta em mais
casas decimais.

---

## Fase 1 — Backend (bloqueia todo o resto)

- [x] **1.1** Reescrever `cmd_setup` de `linux/llm-server.sh` para compilar com `-DGGML_CUDA=ON`.
      Não existe build CUDA precompilado para Ubuntu — só Windows. O fallback antigo compilava, mas
      só se o download falhasse, e o download do Vulkan sempre teve sucesso.
- [x] **1.2** Detectar `nvcc` ausente e falhar com instrução acionável em vez de cair no Vulkan
      silenciosamente. Vulkan só via `LLM_BACKEND=vulkan` explícito.
- [x] **1.3** Separar `-ngl` de `--n-cpu-moe`. Usar `-ngl 999` como o Windows e deixar o llama.cpp
      reduzir. O valor fixo `24` abortava o auto-fit (`common_fit_params: ... abort`).
- [x] **1.4** Adicionar `-ctk q8_0 -ctv q8_0` (corta o KV pela metade, é o que faz 16k caber em
      8 GB), `-fa on`, `--jinja` e `-a <perfil>`. Paridade com `windows/llm-server.ps1:827-846`.
- [x] **1.5** Instalar cmake e CUDA toolkit. Feito pelo usuário:
      `sudo apt install -y cmake build-essential nvidia-cuda-toolkit` → nvcc 12.0.
- [x] **1.5b** Fixar host compiler. nvcc 12.0 recusa gcc > 12 e o sistema tem gcc 13.3 como
      padrão. O setup agora lê o teto do `/usr/include/crt/host_config.h` e escolhe o gcc
      compatível mais novo que esteja instalado, em vez de passar
      `-allow-unsupported-compiler` e rezar.
- [x] **1.6** Compilado. `libggml-cuda` presente, `built with GNU 12.4.0`.
- [x] **1.6b** Remover a dependência de TLS do llama.cpp. O build ficou sem OpenSSL headers, e o
      downloader interno (`-hf`) falhava com `failed to resolve commit`, quebrando 4 perfis
      (`agent`, `fast`, `quality`, `tiny`) com uma mensagem que não menciona TLS. Agora
      `resolve_hf_file()` resolve o `.gguf` pela API do HF e todos os perfis usam `-m` local.
- [x] **1.7** Medido. **A previsão de 15-30 tok/s estava errada** — ver a tabela no topo de
      `docs/diagnostico-linux-benchmark.md`. Resultado real:

      | perfil | pesos | geração | GPU util |
      |---|---|---|---|
      | `agent` 8B (cabe na VRAM) | 5.0 GB | 73.6 tok/s | 98 % |
      | `moe` 35B-A3B (3 B ativos) | 16.8 GB | 27.2 tok/s | 21 % |
      | `qwen27b` denso | 15.2 GB | 3.1 tok/s | 17 % |

      CUDA deu só +19 % no `qwen27b` (2.7 → 3.2). O gargalo é físico: pesos densos que não
      cabem em 8 GB de VRAM são computados na CPU. MoE dá 9× o denso equivalente.

- [ ] **1.8** Revisar os campos `vram_gb` / `ram_gb` / `ngl` dos perfis com os números reais
      medidos sob CUDA. Os atuais foram herdados do Windows e nunca validados no Linux.
- [x] **1.9** Varredura `ngl`/`cpu_moe` no `moe`. **+50 %**: 25.4 → 37.7 tok/s. Perfil atualizado
      para `ngl 99 / cpu_moe 30`. A tabela completa está no comentário de `get_profiles()` e em
      `docs/diagnostico-linux-benchmark.md`. Qualidade revalidada: 6/6.
- [ ] **1.11** Rodar a mesma varredura no `deepseek` (cpu_moe 16, nunca validado no Linux) e no
      `frontier`. O método está documentado: baixar cpu_moe de 4 em 4 até dar abort, subir 2.
- [ ] **1.12** `free -m` mostra ~2.9 GB em swap de forma persistente durante o MoE, sem
      thrashing (`si`/`so` baixos). Investigar se é resíduo ou custo real — 16 GiB de RAM com
      12.5 GB de experts é aperto.
- [ ] **1.10** **Decisão de arquitetura:** o `qwen27b` denso a 3.1 tok/s não é utilizável para
      trabalho agêntico. Considerar removê-lo dos perfis ou marcá-lo como inviável nesta
      máquina, para não desperdiçar rodadas de benchmark nele.

## Fase 2 — Instrumentação honesta do pipeline

Arquivo: `scripts/run_moe_benchmark_pipeline.py`

Base pronta e validada contra o servidor real: [`scripts/bench_lib.py`](scripts/bench_lib.py).

- [x] **2.1** Ler `timings.predicted_per_second` e `predicted_n` reais do chunk final do stream em
      vez de estimar `len(text) // 4`. Requer `timings_per_token: true` no payload. O campo
      `metrics_source` marca quando caiu para estimativa, para não misturar as duas coisas numa
      comparação.
- [x] **2.2** Registrar `finish_reason` e `usage` em toda requisição. `truncated=true` quando for
      `length` **ou** quando o stream encerrar sem `[DONE]` nem `finish_reason` (conexão morta).
- [x] **2.2b** **Contabilizar `reasoning_content`.** Descoberta desta rodada: Qwen3.6 emite os tokens
      de pensamento em `delta.reasoning_content`, não em `delta.content`. Eles gastam `max_tokens`
      igual e eram invisíveis. **É a causa confirmada das páginas truncadas.** Campo novo:
      `reasoning_share`.
- [x] **2.4** Remover o "P95" de 4 amostras. `describe()` só emite `p95` com `n >= 20` e, abaixo
      disso, devolve `p95: null` mais uma nota explicando por quê.
- [x] **2.5** `RemoteHardwareMonitor` usa **uma** sessão SSH persistente com loop remoto emitindo CSV
      por segundo, em vez de uma conexão nova por amostra.
- [x] **2.6** Coletar RAM e swap: `peak_ram_used_gb`, `min_ram_avail_gb`, `peak_swap_used_gb`.
- [x] **2.8** `read_timeout` de 1800 s como teto absoluto **mais** `idle_timeout` de 180 s de
      silêncio entre tokens. É o segundo que distingue "modelo lento" de "stream morto"; um teto alto
      sozinho só faz o script travar meia hora antes de falhar.
- [ ] **2.3** Warmup com prompt **distinto** do prompt medido. Hoje ele aquece o prompt cache e
      todos os TTFT seguintes são cache hit. *(pendente: está no pipeline, não na lib)*
- [ ] **2.7** `try/except` por modelo, com a falha registrada no relatório. O Bonsai falhou e deixou
      `examples/landing-page-bonsai-27b/` vazio sem nenhuma linha de diagnóstico.
- [ ] **2.9** Checar o código de retorno de `run_ssh` no `pull` e abortar o modelo se o download
      falhou.
- [ ] **2.10** Reescrever `run_moe_benchmark_pipeline.py` em cima de `bench_lib.py`, substituindo a
      instrumentação antiga.

### Decisão pendente sobre reasoning (não é bug, é escolha)

`qwen27b`, `deepseek` e `bonsai` não têm `--reasoning off`; `moe` e `agent` têm. Medido: o `qwen27b`
gastou **100%** de 40 tokens raciocinando no prompt "Diga apenas: ok".

A correção reflexa seria adicionar `--reasoning off` em todos. **Não faça isso sem pensar:** o
objetivo é qualidade de código, não velocidade, e raciocínio geralmente *melhora* o resultado.
Desligá-lo para caber no orçamento troca a dimensão que interessa pela que não interessa.

- [x] **2.11** `--max-tokens-scale` dimensiona o orçamento por rodada, em vez de um valor fixo
      para todos.
- [x] **2.12** `reasoning_share` é campo de primeira classe no JSON e aparece no resumo de cada
      geração.
- [x] **2.13** A/B de reasoning no `moe`, três braços. **Decidido: manter `--reasoning off`.**
      18/18 sem reasoning; 8/18 com, no orçamento base (todos os FAILs truncados com 100% de
      reasoning); 9/12 com 4× de orçamento. Custo de 7-20× mais tokens, e o `patch_format`
      degenera em loop mesmo com 8192 tokens — 819 linhas de raciocínio re-copiando o mesmo
      código (`def clear(self):` 42 vezes) para uma tarefa que sem reasoning sai em 45 tokens.
      Tabela e análise em `docs/diagnostico-linux-benchmark.md`.
- [x] **2.14** `LLM_REASONING=on|off` no `llm-server.sh`, e `--reasoning` / `--label` /
      `--max-tokens-scale` no pipeline, para A/B sem editar a tabela de perfis.

- [x] **3.10** Rodar o `scripts/test-feature.py` no `moe` para saber o patamar de partida antes
      de portar. **5/5**, sempre 3 turnos, sempre 424 tokens, 16-24 s, zero reescrita
      (CUDA, `-ngl 99 / --n-cpu-moe 30`, ctx 32k, `--reasoning off`). Detalhes em
      `docs/benchmarks.md`.

- [ ] **3.11** **Os DOIS avaliadores estão no teto e não medem mais nada.** A suíte single-shot
      dá 18/18 e o teste agêntico dá 5/5 determinístico. Nenhum consegue dizer se uma mudança
      de modelo, quantização ou ferramenta melhorou — não há espaço para melhorar.

      Isto é o bloqueio principal do projeto hoje. Tudo o mais (portar suíte, comparar
      ferramentas, escolher quantização) depende de existir um avaliador com resolução.

      Tarefas onde memorização não ajuda:
      - **bug de causa não-local** — o teste falha em `A`, a causa está em `B`, e nada em `A`
        aponta para `B`
      - **invariante não declarado** — a correção óbvia passa o teste visível e quebra outra
        coisa, que só um segundo teste (que o modelo não vê) pega
      - **caso onde a resposta óbvia está errada**
      - **multi-arquivo** — bug num arquivo, teste em outro

- [ ] **3.12** **Tarefas a partir de bugs reais dos próprios repos.** É o eixo de maior valor e
      o único que ninguém mais pode construir: código que não está no corpus de treino de
      nenhum modelo, e que mede exatamente o trabalho que se quer automatizar.

      Método: pegar commits de bugfix do histórico, reconstruir o estado anterior ao fix, e
      usar o teste do próprio commit como critério. Precisa de 2-3 commits apontados pelo
      usuário para começar.

      O sinal de que o `test-feature.py` atual está saturado: **424 tokens idênticos em cinco
      execuções.** Determinismo perfeito num teste de capacidade indica memorização do padrão
      canônico ("Cache com TTL"), não raciocínio.

- [ ] **3.13** Portar o `scripts/test-feature.py` para dentro do `run_benchmark.py` como eixo
      `agentic`, com `pass@k`. Ele já faz o loop completo (4 ferramentas, pytest como critério,
      teto de 14 turnos, arquivo de teste somente-leitura) e é estritamente melhor que o
      `bugfix` single-shot, que é o que se usa de verdade. Fazer DEPOIS de 3.11/3.12 — portar
      um teste saturado só automatiza um resultado que já se conhece.
      Mede formato de edição de graça: dá para ver se o modelo reescreve o arquivo inteiro ou
      edita cirurgicamente.

## Fase 3 — Suíte de qualidade objetiva

Landing page mede geração longa de boilerplate memorizado, sem contexto de entrada e sem tool
calling. É quase o oposto de "corrigir bug em código existente". Rebaixar para smoke test e medir o
que interessa.

- [ ] **3.1** **Bug fix com teste falhando** — 10 a 15 tarefas dos próprios repos: teste vermelho +
      arquivo relevante. Métrica `pass@1` / `pass@3`. Verde ou vermelho, sem juiz. É o eixo de maior
      valor: mede exatamente o objetivo declarado.
- [ ] **3.2** **Aderência a formato de patch** — o search/replace ou diff unificado **aplica
      limpo**? É onde a maioria dos modelos locais morre como agente, e é invisível num teste de
      HTML.
- [ ] **3.3** **Tool calling em loop** — N iterações sem alucinar assinatura nem travar. Os perfis
      declaram `tools|sim` e nada valida essa afirmação.
- [ ] **3.4** **Contexto longo** — enterrar um detalhe em 8k de código real e perguntar.
- [ ] **3.5** **Instrução restritiva** — "responda APENAS o JSON". Taxa de conformidade.
- [ ] **3.6** Rebaixar a landing page a smoke test de "produz output longo sem quebrar". É a única
      coisa que ela mede bem. Tirar da média do score.
- [ ] **3.7** Substituir os checks por substring. Validar HTML com parser de verdade, não
      `"dark" in html`. Hoje um arquivo truncado que não parseia tira 8.6/10.
- [ ] **3.8** Corrigir o teste de raciocínio: `"10" in content` passa de graça porque o enunciado já
      contém "Há 10 anos".
- [ ] **3.9** Repetir cada teste `k` vezes e reportar variância. Uma amostra a `temperature=0.2` é um
      lance de dado — não distingue modelo de sorte.
- [ ] **3.10** Parar de agregar num `overall_score` único a média de notas binárias 10-ou-4.
      Reportar os eixos separados, ou pesos explícitos e declarados.

## Fase 4 — Reavaliar as escolhas de modelo com dados válidos

- [ ] **4.1** Re-rodar a matriz completa sob CUDA e refazer `BENCHMARK_REPORT.md` (o atual está
      factualmente errado: declara "None detected" para saídas truncadas).
- [ ] **4.2** Investigar por que o `bonsai` falhou — nenhum artefato, nenhum log.
- [ ] **4.3** Reavaliar `ctx=16384`. Para trabalho agêntico de verdade, 32k é o piso. Com KV em
      `q8_0` e CUDA a margem pode existir; medir antes de decidir.
- [ ] **4.4** Confirmar a hipótese de que MoE é a arquitetura correta para 8 GB de VRAM. O dado atual
      aponta nessa direção: o 35B-A3B (3 B ativos) gerou 27 KB contra 12 KB do 27B denso.
