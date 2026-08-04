# STATUS — onde o projeto está e por quê

Handoff para retomar em outra sessão sem perder contexto.
Última atualização: 2026-08-03.

Documentos vizinhos, e quando ler cada um:

| arquivo | quando |
|---|---|
| este | primeiro. Dá o estado e as decisões |
| [`TODO.md`](TODO.md) | o que fazer em seguida, em ordem |
| [`docs/diagnostico-linux-benchmark.md`](docs/diagnostico-linux-benchmark.md) | a investigação completa, com as hipóteses que caíram |
| [`docs/benchmarks.md`](docs/benchmarks.md) | todos os números e o método |

---

## 1. O objetivo

Um modelo local que sirva para **programar de verdade**: corrigir bug, entregar feature, rodar num
loop de agente. Qualidade importa, velocidade não.

Isso tem duas consequências que orientam tudo:

- métricas de velocidade (tok/s) são secundárias, e várias vezes apontaram para o modelo errado;
- landing page e "escreva uma função" não medem o objetivo. O que mede é: o teste ficou verde?

## 2. O modelo está resolvido

**Use o perfil `moe`** — Qwen3.6 35B-A3B (MoE, 3 B ativos), 16,8 GB.

```bash
./linux/llm-server.sh start moe --lan
```

Medido em CUDA na RTX 3060 Ti (8 GB VRAM, 16 GB RAM), 03/08/2026:

| perfil | pesos | geração | prefill | GPU util |
|---|---|---|---|---|
| `moe` 35B-A3B | 16,8 GB | **37,7 tok/s** | ~300 tok/s | 30 % |
| `agent` Qwen3 8B | 5,0 GB | 73,6 tok/s | ~400 tok/s | 98 % |
| `qwen27b` denso | 15,2 GB | 3,1 tok/s | — | 17 % |

Três fatos que custaram medição e não devem ser re-descobertos:

1. **MoE é a única arquitetura viável aqui.** O denso de 15,2 GB roda 12× mais lento que o MoE de
   16,8 GB, porque pesos densos que não cabem na VRAM são computados pela CPU. Não é ajuste de
   flag, é limite físico.
2. **O backend precisa ser CUDA compilado.** O release do llama.cpp não publica build CUDA para
   Linux; `./linux/llm-server.sh setup` compila. O script antigo baixava Vulkan e se descrevia
   como CUDA: 2,7 tok/s com a GPU a 18 %.
3. **O botão de afinação é `--n-cpu-moe`, não `-ngl`.** Varredura completa no comentário de
   `get_profiles()` em `linux/llm-server.sh`. `ngl 99 / cpu_moe 30` deu +50 % sobre o herdado.

Decidido e fechado: **manter `--reasoning off`.** A/B de três braços mostrou 18/18 sem reasoning
contra 8/18 com (todos os FAILs truncados) e 9/12 com 4× de orçamento. Custa 7-20× mais tokens e
degenera em loop no `patch_format`.

## 3. O que NÃO está resolvido: medir

Este é o estado do problema hoje.

| avaliador | resultado do `moe` | serve para |
|---|---|---|
| `scripts/run_benchmark.py` (6 eixos, single-shot) | 18/18 | dizer "o modelo serve" ✓ |
| `scripts/test-feature.py` (Cache com TTL) | 5/5, determinístico | idem ✓ |
| `scripts/bench_agentic.py timeline_midnight` | **0/3, `3/5 → 4/5`** | **comparar de fato** ✓ |
| `scripts/bench_agentic.py booking_horizon` | nunca rodado | — |

As duas primeiras estão **no teto** e não medem mais nada: quando o baseline acerta tudo, não dá
para saber se uma mudança melhorou. A terceira é a que tem resolução, e foi construída nesta
sessão.

### O achado mais importante: ele mente sobre ter terminado

`pass@5` com amostragem (`--temperature 0.6 --repeats 5`) na `timeline_midnight`:

| # | resultado | placar | turnos | tokens |
|---|---|---|---|---|
| 1 | REPROVADO — desistiu | 3/5 → 4/5 | 14 | 12.971 |
| 2 | REPROVADO — desistiu | 3/5 → 4/5 | 10 | 10.666 |
| 3 | **APROVADO** | **3/5 → 5/5** | 11 | **6.964** |
| 4 | REPROVADO — teto de turnos | 3/5 → 4/5 | 14 | 10.028 |
| 5 | REPROVADO — desistiu | 3/5 → 4/5 | 9 | 7.624 |

**`pass@5 = 1/5`.** Com amostragem ele resolve às vezes — não é incapacidade, é 20 % de acerto.

Dois padrões que valem mais que o número:

1. **Três das quatro falhas foram ele declarando vitória com a suíte vermelha.** O motivo
   registrado é *"terminou sem chamar ferramenta; suíte vermelha"*: parou de agir e respondeu em
   prosa como se tivesse concluído. Só uma falha foi honesta (bateu no teto).

   Consequência prática, e é dura: **numa pipeline o modelo local vai afirmar que terminou e
   estar errado em ~60 % das tentativas desta tarefa.** Teste como gate não é opcional — se você
   confiar no relato dele, recebe código quebrado com aparência de pronto. O `bench_agentic.py`
   só detecta porque roda o teste depois, ignorando o que o modelo diz.

2. **A tentativa que acertou foi a mais barata**: 6.964 tokens contra 10-13 mil das que falharam.
   Quando acha o caminho, acha rápido. Serve como sinal de escalonamento: passou de ~8k tokens
   sem ficar verde, provavelmente não vai ficar.

Isto corrige uma leitura anterior: com temperatura 0 parecia "mínimo local sempre no mesmo
ponto". Com amostragem o quadro é outro — ele **desiste cedo** em 3 de 5 amostras.

### Por que a `timeline_midnight` funciona como avaliador

Vem de um bugfix real (`beahub@69d3177`). Um corte às 23:30 termina em `"00:00"`, aparece nos cards
e desaparece da timeline: `"00:00"` era lido como 0 minutos em vez de fim-do-dia (1440).

O `moe` reprova de forma informativa: **acerta a causa** (meia-noite = 1440, aplicado em
`overlaps`, no `endMinutes` e no `minutesToTime`) e **perde a consequência** — o agendamento começa
exatamente no horário de fechamento, logo fora da grade, e é preciso crescer a janela. Nada na
mensagem de erro aponta para isso. Após a 3ª reescrita entra em mínimo local e gasta os turnos
restantes relendo os mesmos arquivos. 14 turnos, 11.115 tokens (contra 424 da tarefa do Cache).

O `3/5 → 4/5` é o ponto: crédito parcial permite comparar duas configurações que ambas reprovam.

## 4. Como rodar

```bash
# subir o modelo (--lan é obrigatório para acessar de outra máquina)
./linux/llm-server.sh start moe --lan
LLM_CTX=32768 ./linux/llm-server.sh restart moe --lan

# suíte single-shot (saturada, mas valida que nada regrediu)
python3 scripts/run_benchmark.py moe --skip-pull
python3 scripts/test_bench_tasks.py          # testa os graders

# a que mede
python3 scripts/bench_agentic.py --listar
LLM_HOST=192.168.3.51 python3 scripts/bench_agentic.py timeline_midnight
LLM_HOST=192.168.3.51 python3 scripts/bench_agentic.py timeline_midnight --temperature 0.6 --repeats 5
LLM_HOST=192.168.3.51 python3 scripts/bench_agentic.py timeline_midnight --manter   # inspecionar o que escreveu

# o teste de feature original (Cache/TTL) — precisa de pytest
LLM_HOST=192.168.3.51 uv run --with pytest --python 3.12 scripts/test-feature.py moe
```

## 5. Arquitetura do benchmark agêntico

`scripts/bench_agentic.py` dá ao modelo `list_files`, `read_file`, `write_file` e `run_tests`, e
itera até o teste ficar verde ou o teto de turnos estourar. Tarefas vivem em
`scripts/agentic_tasks/<nome>/task.json`.

**Dois modos**, e a escolha entre eles foi a decisão de arquitetura da sessão:

| | vendorizado | worktree |
|---|---|---|
| exemplo | `timeline_midnight` | `booking_horizon` |
| onde vivem os arquivos | copiados para `agentic_tasks/` | git worktree do repo real em `commit^` |
| autocontido | ✅ | ❌ precisa do repo |
| esforço por tarefa | alto (stub de dependências) | quase zero (escrever o `task.json`) |
| multi-arquivo | inviável | ✅ |

Vendorizar só é barato quando o bug cabe num arquivo puro sem imports. **Dos 300 commits varridos
do Beahub, 20 tinham teste no próprio commit e só UM era assim** — daí o modo worktree existir.

No modo worktree: cria `git worktree add --detach` em `<commit>^` (código bugado), restaura os
`specs` da versão pós-fix (é isso que produz o vermelho), e liga `node_modules` por symlink (527 MB
e 609 MB no Beahub — copiar por tentativa seria inviável). Remove o worktree no fim.

Salvaguardas que não devem ser afrouxadas:

- **arquivo de teste é somente leitura.** Sem isso o caminho mais curto para o verde é apagar os
  testes, e já se viu modelo tentar. A recusa é registrada: interessa saber se ele *tentou*.
- **workspace recriado por tentativa**, senão a taxa vira sequência dependente.
- **guarda contra fixture podre**: se a suíte já passa antes do modelo agir, aborta com
  `FIXTURE INVÁLIDA` em vez de reportar APROVADO falso.
- **confinamento por `resolve` + `relative_to`**, nunca `startsWith` em string crua.
- **crédito parcial via `regex_placar`**, medido sempre, inclusive quando reprova.

### Receita para adicionar tarefa nova (modo worktree)

1. Achar um commit de fix cujo diff inclua o arquivo de teste.
2. Confirmar o vermelho→verde antes de aceitar a fixture:
   ```bash
   git show <commit>^:<arquivo>   # estado bugado
   git show <commit>:<spec>       # teste que pega o bug
   ```
3. Escrever o `task.json` com `repo`, `commit`, `cwd`, `arquivo_alvo`, `specs`,
   `link_node_modules`, `comando_teste`, `regex_placar`.
4. Rodar e conferir que o placar inicial bate com o esperado.

Candidatos já triados no Beahub, com teste no próprio commit:

- `aeb5194` → já virou a tarefa `booking_horizon` (multi-arquivo, nunca executada)
- `d3372f6` — *impede vender produto indisponível no Caixa*. Regra de negócio API + front
- `27fe110` — *links de subdomínio dedicado*. Importa `@mantine/notifications`, spec usa `vi.mock`
- `af59d67` — *honrar flag autoPauseBot*. O util foi criado no commit, então o bug está nos call
  sites; precisa de NestJS

Atenção: `api` usa **jest**, `bflowbarber-app` usa **vitest**. O `comando_teste` é por tarefa.

## 6. Padrão de erro a vigiar

Nesta sessão eu cometi **três vezes** a versão nova de um defeito que eu tinha acabado de
criticar:

1. critiquei estimar token por `len/4` — e o gauge do harness fazia igual;
2. critiquei o warmup envenenar o prompt cache — e medi prefill com prompt repetido, com as
   rodadas 2 e 3 processando 4 tokens em vez de 3.241;
3. critiquei falta de amostragem — e chamei de `pass@k` três execuções com `temperature 0`, que
   saíram idênticas (11.115 tokens exatos).

Antes de confiar em qualquer número novo, a pergunta é: **o que neste medidor pode estar medindo o
instrumento em vez do modelo?**

## 7. Decisões fechadas (não reabrir sem motivo novo)

- **`--reasoning off`** no `moe`. Medido em três braços.
- **Harness web removido.** Era um fork do Chatbot UI que não lia arquivo nem rodava teste — as
  duas coisas que corrigir bug exige. O `scripts/test-feature.py`, com 315 linhas, já fazia o loop
  agêntico completo. Histórico preservado em `~/Desktop/harness-chatbot-ui-history.bundle` (3,4 MB,
  os 5 commits próprios nunca foram publicados; o `origin` apontava para o upstream). Contexto em
  [`archive/README.md`](archive/README.md).
- **Ferramenta de código: usar pronta** (Cline funciona) em vez de construir. O gargalo nunca foi
  o harness.
- **Landing page não é benchmark.** Fica como amostra em `examples/`. Serve de smoke test de
  "produz saída longa sem quebrar" e nada além.

## 7a. O desenho das ferramentas decide a viabilidade

Descoberto ao construir as tarefas de worktree, e vale mais que qualquer número de tok/s.

A primeira versão do runner só oferecia `write_file`, que exige o **conteúdo completo** do arquivo.
No `booking_horizon` o arquivo tem 528 linhas (~16 KB) e as três execuções morreram assim:

```
HTTP 500 — Failed to parse tool call arguments as JSON:
  parse error at column 16046: invalid string: missing closing quote
```

O modelo tentou reemitir o arquivo inteiro dentro de uma string JSON e bateu no `max_tokens` no
meio da string. O llama.cpp recebeu JSON truncado e devolveu 500.

**Não era limitação do modelo, era da ferramenta que eu dei.** Corrigido com `str_replace`
(`old_str` → `new_str`, exigindo ocorrência única), que é o que ferramentas reais usam. E joga a
favor de uma força já medida: no eixo `patch_format` o modelo emite search/replace correto 3/3.

Consequência para a pipeline: **modelo local não reescreve arquivo grande.** Se o executor só
tiver `write_file`, ele falha em qualquer arquivo real por motivo que nada tem a ver com
capacidade de programar. Edição cirúrgica não é otimização, é requisito.

A exigência de ocorrência única no `str_replace` também é deliberada: substituir a primeira de
várias é o modo clássico de aplicar patch no lugar errado, e o erro fica invisível até o teste
falhar por outro motivo.

## 7b. A pipeline "grande planeja, local executa"

Ideia em avaliação: usar modelo grande para planejar e o local para executar, cortando custo de
token. O que se sabe até agora:

**A favor.** A falha observada na `timeline_midnight` é de **insight**, não de execução: o modelo
acerta a causa raiz e perde a consequência. Insight é exatamente o que o planejador supre. E a
parte mecânica ele faz bem — `patch_format` 3/3, loop de ferramentas limpo.

**Contra, e é o risco central.** Ele declara vitória com a suíte vermelha em 3 de 5 amostras. Sem
teste como gate, a pipeline entrega código quebrado que *parece* pronto.

**Desenho que os dados sugerem**, se for adiante:
- modelo grande produz o plano
- local executa em worktree isolado
- **teste é o juiz, nunca o relato do modelo**
- escalona para o grande em ~8k tokens sem ficar verde, ou em 2 rodadas sem melhorar o placar

**Experimento em curso:** `timeline_midnight_planned` é a mesma tarefa com o plano injetado no
prompt — único elemento diferente. Se o `pass@5` subir de 1/5 para perto de 5/5, a hipótese está
validada.

**Viés a declarar:** o plano foi escrito por quem já sabia a resposta (derivado da mensagem do
commit). Um planejador real veria só o teste falhando. O resultado é o **limite superior** da
pipeline, não a expectativa. Se der verde, o próximo teste honesto é gerar o plano com um modelo
grande sem acesso ao fix, e ver se ele produz plano dessa qualidade.

**Não medido:** o custo real. Nem do modelo grande com prompt caching, nem qual fração do trabalho
cai na fatia delegável. Pode ser que a fração seja pequena o suficiente para não valer manter duas
engines.

## 8. Pendências imediatas

Em ordem de valor. Detalhe em [`TODO.md`](TODO.md).

1. **`pass@5` com amostragem** na `timeline_midnight` (`--temperature 0.6 --repeats 5`). Estava
   rodando quando esta sessão terminou. Muda a leitura de "não consegue" para "consegue às
   vezes", que é diferença prática grande.
2. **Rodar a `booking_horizon`.** Construída e validada (placar inicial 6/7 vermelho), nunca
   executada contra o modelo.
3. **Rodar as duas tarefas nos perfis `agent` e `deepseek`.** É o primeiro teste capaz de
   *ordenar* modelos em vez de dar 100 % a todos.
4. **Mais tarefas de bug real** — `d3372f6` é o próximo mais barato.
5. Varredura de `cpu_moe` no `deepseek` e no `frontier` (números herdados do Windows, nunca
   validados no Linux).

## 9. Estado do git

`main`, worktree limpo. Os commits desta sessão vão de `9caa711` a `839964d`; os últimos ainda não
tinham push quando isto foi escrito — confira com `git status -sb`.
