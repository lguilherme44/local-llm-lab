# Benchmarks: números e como foram obtidos

Todo número deste repositório saiu de um comando executado. Esta página documenta **como**, para você poder reproduzir ou contestar.

---

## Hardware

**Máquina A** — MacBook Air M4
- 10 cores (4 performance + 6 efficiency)
- 16 GB de memória unificada
- SSD 228 GB
- **Sem ventoinha** (refrigeração passiva)
- macOS 26.5

**Máquina B** — Windows
- RTX 3060 Ti, 8 GB de VRAM
- 16 GB de RAM
- SSD 1 TB

Salvo onde estiver dito o contrário, os números abaixo são da **Máquina A**. Os da Máquina B estão na seção [RTX 3060 Ti](#máquina-b-rtx-3060-ti-llamacpp--cuda).

---

## Condição importante: a máquina não estava vazia

Os testes rodaram com uso normal — navegador, IDE, apps abertos. No momento das medições:

```
RAM livre:  2,5 a 7 GB (oscilando)
swap usado: 8 a 15 GB
```

Isso **não** é um laboratório limpo, e é deliberado: é a condição em que você vai usar. Um benchmark com a máquina recém-reiniciada e nada aberto produz números que você nunca vai ver.

Consequência: os números aqui são um **piso realista**, não um teto de marketing.

---

## Geração (tokens/s)

### MLX

| modelo | pesos | tok/s | observação |
|---|---|---|---|
| Qwen2.5-Coder-7B-Instruct-4bit | 4,3 GB | **19,7** | cabe confortável |
| Qwen3-8B-4bit | 4,6 GB | **16,1** | + tool calling |
| gemma-4-12B-it-qat-OptiQ-4bit | 9,0 GB | **0,7** | não cabe → swap |
| gemma-3n-E4B-it-8bit | 9,3 GB | 17,3 | ver ressalva abaixo |

**Método:** requisição única a `/v1/chat/completions`, `temperature: 0`, cronometrada de ponta a ponta; tok/s = `usage.completion_tokens / tempo_total`.

**Ressalva sobre o gemma-3n:** os 17,3 tok/s são da *geração isolada*, medidos por `mlx_vlm.generate`. O tempo de parede foi **3 min 10 s para 65 tokens**, porque cada invocação recarrega 8,7 GB do disco. É o exemplo mais claro de por que servidor residente importa: o número da geração era bom, a experiência era inútil.

### llama.cpp (mesma máquina, backend Metal)

| modelo | pesos | tok/s |
|---|---|---|
| Qwen3-4B-GGUF Q4_K_M | 2,50 GB | **33,1** |
| Qwen3-8B-GGUF Q4_K_M | 5,03 GB | **18,8** |

O 8B em GGUF (18,8) e em MLX (16,1) ficaram próximos — a diferença está dentro da variação de condição da máquina, então **não** conclua que um runtime é mais rápido a partir desses dois pontos.

O dado que importa aqui é outro: **o 4B roda ao dobro do 8B** e passa no mesmo teste de tool calling.

---

## O precipício de memória

O achado mais útil de todos.

| modelo | pesos | tok/s | cabe? |
|---|---|---|---|
| Qwen2.5-Coder-7B-4bit | 4,3 GB | 19,7 | sim |
| gemma-4-12B-4bit-QAT | 9,0 GB | 0,7 | não |

**28× de diferença.** Mesma máquina, mesmo runtime, mesma sessão.

O Gemma 4 não é 28× pior — ele não cabia. Com ~3 GB de RAM livre e 14 GB de swap em uso, cada token passou a envolver disco.

**Por que isso é uma lição e não uma anedota:** a degradação não é proporcional ao excesso. Não existe "um pouco grande demais". Ou cabe e você tem velocidade usável, ou não cabe e é inutilizável. Escolha o maior modelo que cabe **com folga**.

---

## Prefill (processamento do prompt)

**Método:** system prompt de 3.517 tokens (texto repetido), `max_tokens: 10`, medindo o tempo total. Modelo: Qwen2.5-Coder-7B-4bit.

```
3.517 tokens de prompt em 20,0 s  ≈  176 tok/s de prefill
```

Prefill e geração são gargalos independentes: ~176 tok/s de entrada, ~19 tok/s de saída.

**Por que isso decide se agente local é viável:** um agente injeta system prompt, definições de ferramentas e histórico a cada turno. Com 3.500 tokens são 20 s antes do primeiro token; com 10k, mais de um minuto — a cada passo.

---

## Máquina B: RTX 3060 Ti (llama.cpp + CUDA)

**Método:** `llm-server.ps1 bench` — 4 rodadas, a primeira descartada, mediana das outras. Os números vêm do bloco `timings` que o `llama-server` devolve, não de cronômetro do cliente: isso separa prefill de geração e mantém a latência de rede fora da conta. O prompt varia a cada rodada (sufixo `(vN)`) para o prompt cache não servir a resposta e o bench acabar medindo o cache.

Modelos em Q4_K_M, `-ngl 999` (modelo inteiro na VRAM), cache KV em q8_0, `--reasoning off`. Contexto 16k no `agent`, 32k no `tiny`.

| perfil | modelo | geração | prefill |
|---|---|---|---|
| `agent` | Qwen3-8B | **72,5 tok/s** | **393 tok/s** |
| `tiny` | Qwen3-4B | **110,4 tok/s** | **575 tok/s** |

Contra a Máquina A, no mesmo Qwen3-8B: 19 tok/s de geração e 176 de prefill. A GPU dedicada é ~3,8× em geração e ~2,2× em prefill.

O `agent` foi medido em duas implementações independentes — o `bench` do script e um cliente Python separado — que deram 72,5 e 72,9 tok/s. A dispersão entre rodadas ficou dentro de 0,4 tok/s nos dois perfis.

**A primeira rodada mede outra coisa:** o prefill dela ficou em 40 tok/s (`agent`) e 105 (`tiny`) contra ~390 e ~575 nas seguintes, com cache frio. É por isso que ela é descartada em vez de entrar na média.

**Ciclo completo de tool calling**, ambos aprovados (`LLM_HOST=<ip> scripts/test-tools.py <alias>`):

| perfil | turno 1 | turno 2 |
|---|---|---|
| `agent` | 0,7 s | 1,9 s |
| `tiny` | 0,6 s | 0,7 s |

Para comparar com a experiência na Máquina A: o `pi` ali gastava ~2 minutos por turno.

**O erro que esses números corrigiram:** as descrições dos perfis do `llm-server.ps1` diziam `~19 tok/s` e `~33 tok/s` — herdados do lado macOS, nunca medidos nesta GPU. Um número copiado de outra máquina parece um número medido, e nada no repositório denunciava a diferença.

Errado inclusive na **relação** entre os dois: a descrição do `tiny` afirmava "quase 2× o 8B", extrapolando de 33 contra 19. Medido, são **1,5×** — 110,4 contra 72,5. Vale como aviso: razão derivada de números herdados erra junto com eles, e soa mais confiável porque parece uma comparação interna. Compare hardware e flags antes de reaproveitar qualquer medida.

**Sobre `--reasoning off`:** o Qwen3 pensa por padrão. Isso não muda o tok/s de geração — muda **quantos** tokens ele gera para dizer a mesma coisa. Medido no mesmo prompt: 112 a 333 tokens com raciocínio ligado, **5** com ele desligado. Veja [troubleshooting](06-troubleshooting.md).

---

## Um MoE de 30B numa GPU de 8 GB

O perfil `moe` serve o **Qwen3-Coder-30B-A3B** (UD-Q3_K_XL, 12,9 GB) numa 3060 Ti de 8 GB. Isso contradiz a regra que o resto desta página defende — "escolha o maior modelo que cabe com folga" — e vale explicar por que a exceção é legítima em vez de sorte.

Num modelo **denso**, cada token lê todos os pesos. Estourar a VRAM significa buscar camadas na RAM a cada token, e é daí que sai o precipício de 28× medido acima.

Num **MoE** isso muda. Dos 30,5 B de parâmetros do Qwen3-Coder, ~29 B estão nos experts, e apenas 8 dos 128 experts são lidos por token. Os ~1,5 B restantes — atenção, embeddings, router — são lidos *sempre*. A divisão que segue esse fato é `--n-cpu-moe 40`: atenção e cache KV na VRAM, 40 das 48 camadas de expert na RAM do sistema.

**Método:** cliente Python contra `/v1/chat/completions`, `temperature: 0`, números do bloco `timings` do servidor. Geração: 6 rodadas, primeira descartada, mediana das outras. Prefill: 3 prompts longos e **distintos entre si** (~2.360 tokens), porque prompt idêntico é servido pelo cache e mede o cache.

| | `agent` (Qwen3-8B denso) | `moe` (Qwen3-Coder-30B-A3B) |
|---|---|---|
| geração | 72,5 tok/s | **24,4 tok/s** (23,6–24,5) |
| prefill | 393 tok/s | **595 tok/s** |
| VRAM | 6,2 GB | 5,2 GB |
| RAM do processo | ~0,5 GB | **9,7 GB** |
| contexto | 16k | 16k |
| tool calling | ✅ | ✅ |

**O resultado contraintuitivo é o prefill.** O MoE gera 3× mais devagar, mas processa prompt **1,5× mais rápido** que o 8B denso. Não é anomalia: prefill é batched e domina na atenção, que está inteira na GPU; e o modelo só ativa 3 B de parâmetros por token. Para trabalho agêntico — contexto longo reprocessado a cada turno — o prefill é a metade que mais pesa. Os 3× de perda na geração doem menos do que a tabela sugere.

**A primeira medição foi 9,9 tok/s e estava errada.** Com `mmap`, os experts são páginas de arquivo: a primeira geração falta página por página do SSD. Aquecido, são 24,4. Se você medir uma vez e publicar, publica o número do disco, não o do modelo. O `llama.cpp` inclusive avisa no log — `tensor overrides to CPU are used with mmap enabled` — e `--no-mmap` provavelmente melhora, mas não foi testado: nesta máquina não há RAM para a alocação anônima equivalente.

**Roda no limite, e isso não é figura de linguagem:**

```
VRAM     5,18 GB de 8      (livre: 2,8 GB)
RAM      9,66 GB no processo
RAM livre                  0,17 GB
```

Com 170 MB livres, qualquer aba de navegador nova empurra experts para o pagefile. E aqui o custo não é "fica mais lento": são ~1,3 GB de experts lidos por token, e puxar isso do disco derruba a geração para 1–2 tok/s. O perfil avisa antes de subir quando a RAM não dá.

**Contexto é 16k, não 32k.** O cache KV deste modelo é baratíssimo — 48 KB/token em q8_0, contra 96 KB do 8B, porque a atenção é GQA de 4 kv-heads contra 32 de query. Mesmo assim 32k não entra: o aperto não é o KV, é o total. Com 6,76 GB de VRAM livre e 8,51 de RAM, o orçamento é 15,27 GB, e `12,9 + 1,5 + 0,9 = 15,3`. Passou por 30 MB.

**Três falhas silenciosas no caminho**, todas terminando em status de saída 0 — é isso que as torna caras:

1. `pull` passava `--port 0`. O `llama-server` valida a porta **antes** do download, sai imediatamente e deixa só o diretório vazio no cache do Hugging Face.
2. `-hf repo:UD-Q3_K_XL` não resolve. O `llama.cpp` casa a tag por nomes de quant padrão (`Q4_K_M` e afins), e os dinâmicos da Unsloth não são. Em vez de falhar, ele **sobe em router mode sem modelo nenhum**: servidor no ar, HTTP respondendo, zero byte baixado. Um `bench` contra isso mede o nada. Daí o campo `File` nos perfis, que baixa com `curl` e serve com `-m`.
3. Servidor iniciado por SSH morre quando a sessão fecha — o Windows derruba o process tree. O `start` reporta sucesso, porque o health check passa antes da sessão terminar.

E um download truncado em 18,5 MB (de 12,9 GB) que carregou até `blk.47.ffn_up_exps.weight` antes de falhar. Por isso `Test-ModelDownloaded` compara **tamanho** nos perfis com `File`: "o arquivo existe" é a resposta errada para essa pergunta.

**A estimativa que precedeu a medição errou em tudo menos no sinal.** Previu 15–22 tok/s (foram 24,4), VRAM de 6,5 GB (foram 5,2) e 32k de contexto (não coube). O raciocínio — MoE tolera offload, banda de RAM é o teto — apontava a direção certa; os números, não. Vale como lembrete de que estimativa fundamentada continua sendo estimativa.

### Onde o offload de MoE para de funcionar

O `moe` cabe. A pergunta seguinte é até onde a técnica escala — e a resposta veio de testar o **Qwen3.6-35B-A3B** (MXFP4_MOE, 20,2 GB) na mesma máquina. Mesma família de arquitetura, mesmo `--n-cpu-moe`, 8k de contexto para dar a melhor chance possível.

| | `moe` — Qwen3-Coder-30B-A3B (12,9 GB) | Qwen3.6-35B-A3B (20,2 GB) |
|---|---|---|
| geração | **24,4 tok/s** | 9,7 tok/s |
| prefill | **595 tok/s** | **45,1 tok/s** |
| tool calling | ✅ | ✅ |
| page faults do processo | — | **7,7 milhões** |

Os dois funcionam e os dois passam no teste de agente. Mas **o prefill é 13× pior**, e é o prefill que decide: um prompt de 1.820 tokens leva **40 segundos** só para ser lido. Num loop agêntico, onde o contexto é reprocessado a cada turno, nenhuma vantagem de qualidade paga isso.

A causa não é o modelo, é aritmética: 20,2 GB de pesos contra 15,3 GB de orçamento. Os 7,7 milhões de page faults são a diferença batendo no SSD. **O offload de MoE compra folga, não memória infinita** — ele deixa você usar VRAM + RAM em vez de só VRAM, e acaba exatamente quando a soma das duas acaba.

Vale registrar que a geração cai menos que o prefill (2,5× contra 13×). Faz sentido: gerar toca poucos experts por vez e o cache de páginas absorve parte; o prefill processa o prompt inteiro em lote e varre experts que não estão residentes.

**Duas armadilhas encontradas ao subir este modelo:**

O primeiro teste de tool calling **reprovou por erro de método**: `tool_calls: null` com `content` vazio. Não era o modelo — era `--reasoning off` faltando na linha de comando, porque o servidor foi subido à mão em vez de por perfil. É a mesma falha silenciosa que a seção anterior documenta, encontrada de novo por quem a tinha escrito. Com a flag, aprovou.

E o caminho `snapshots\<rev>\modelo.gguf` do cache do Hugging Face é um **symlink** que o `llama.cpp` não segue no Windows — falha em 0,25 s com "failed to load model", que parece corrupção de arquivo. Só carrega apontando para `blobs\<sha>`.

---

## Prompt cache: o ganho de 25×

**Método:** a mesma requisição de 3.517 tokens enviada duas vezes seguidas, com `--prompt-cache-size 2 --prompt-cache-bytes 1500000000`.

| requisição | tempo |
|---|---|
| primeira | 20,0 s |
| segunda (prefixo idêntico) | **0,78 s** |

**25× mais rápido.** É o que torna agente local viável do segundo turno em diante.

**A ressalva honesta:** isso mede prefixo *idêntico*. Num agente real o contexto cresce a cada turno, invalidando parte do cache. O ganho é grande no trecho estável (system prompt, ferramentas) e menor num refactor longo. Não espere 25× no uso real — espere que o custo alto seja pago uma vez em vez de sempre.

---

## Tool calling

**Método:** ciclo completo, não só a primeira chamada. O script `scripts/test-tools.py`:

1. Define uma ferramenta `read_file` e pede ao modelo que a use
2. Verifica se `tool_calls` veio **estruturado** (não texto no `content`)
3. Devolve um resultado fabricado: `{"name": "meu-projeto", "version": "3.1.4", "license": "MIT"}`
4. Verifica se a resposta final **contém** aqueles valores

O passo 4 é o que separa "emite chamada" de "serve como agente". Modelo que pede a ferramenta e ignora o retorno é reprovado.

| modelo | runtime | resultado |
|---|---|---|
| Qwen3-8B-4bit | MLX | ✅ turno 1: 3,0 s · turno 2: 4,5 s · 16,1 tok/s |
| Qwen3-8B-GGUF Q4_K_M | llama.cpp | ✅ turno 1: 9,1 s · turno 2: 15,9 s · 18,8 tok/s |
| Qwen3-4B-GGUF Q4_K_M | llama.cpp | ✅ turno 1: 4,5 s · turno 2: 12,1 s · 33,1 tok/s |
| Qwen2.5-Coder-7B-4bit | mlx_lm | ❌ chamada como texto no `content` (formato variável) |
| Qwen2.5-Coder-7B-4bit | mlx_vlm | ❌ idem (confirma que é o modelo, não o servidor) |
| Qwen3-4B-Instruct-2507-4bit | MLX | ❌ `content` vazio (template separado) |

O `Qwen2.5-Coder` foi testado nos **dois** engines de propósito: com o mesmo resultado, a causa está no modelo, não no servidor.

---

## Teste de feature: quando o benchmark e a entrega discordam

Todas as medidas acima são de *capacidade*: tokens por segundo, ciclo de tool calling, memória. Nenhuma responde a pergunta que decide se vale trabalhar com o modelo — **ele termina a tarefa?**

**Método:** `scripts/test-feature.py`. Um `Cache` aceita `ttl` em `set()` e `default_ttl` no construtor mas ignora os dois; seis testes cobrem a expiração e falham. O modelo recebe quatro ferramentas (`list_files`, `read_file`, `write_file`, `run_tests`) e o pedido de fazer a suíte passar. Teto de 14 turnos. `test_cache.py` é somente leitura no harness — sem isso o caminho mais curto para o verde é apagar os testes.

O critério não é heurística de texto nem julgamento: é o `pytest`.

| perfil | modelo | resultado | tempo | turnos | reescritas |
|---|---|---|---|---|---|
| `moe` | Qwen3-Coder-30B-A3B | **APROVADO** | 46 s | 2 | 1 |
| — | Qwen3.6-35B-A3B | APROVADO | 176 s | 3 | 1 |
| `agent` | Qwen3-8B | **REPROVADO** | 31 s | 14 (teto) | 6 |

**Sobre o tempo, uma ressalva que vale mais que a coluna:** os 46 s do `moe` são com o cache de páginas quente. A mesma execução logo após reiniciar o servidor levou **352 s** — 7,6× — tomando exatamente as mesmas decisões: 2 turnos, mesma sequência de ferramentas, os mesmos 562 tokens gerados. A `temperature 0` dá reprodutibilidade de comportamento; o relógio depende de quanto do modelo está residente. Compare turnos e reescritas entre modelos; compare tempo só dentro da mesma condição de cache.

### Reexecução em 03/08/2026: CUDA, perfil afinado, 5 repetições

A linha do `Qwen3.6-35B-A3B` acima é de antes do backend estar certo — rodava em Vulkan, com
`-ngl 36 / --n-cpu-moe 36`. Refeito com CUDA compilado, `-ngl 99 / --n-cpu-moe 30`, ctx 32k e
`--reasoning off`, cinco execuções:

| # | resultado | tempo | turnos | tokens | chamadas |
|---|---|---|---|---|---|
| 1 | APROVADO | 24 s | 3 | 424 | `read_file`×2, `write_file`, `run_tests` |
| 2 | APROVADO | 16 s | 3 | 424 | idem |
| 3 | APROVADO | 16 s | 3 | 424 | idem |
| 4 | APROVADO | 16 s | 3 | 424 | idem |
| 5 | APROVADO | 17 s | 3 | 424 | idem |

**5/5.** Sempre a mesma sequência: lê `cache.py`, lê `test_cache.py`, escreve a correção, roda
o teste, verde. Zero reescrita, zero turno desperdiçado. Os 176 s da medição antiga viram 16 s —
parte é o CUDA, parte é cache de páginas quente (ver a ressalva acima).

Isso estabelece que o modelo faz trabalho agêntico de verdade: ler repositório, editar arquivo,
verificar com teste. 424 tokens de saída, ~11 s de geração a 37 tok/s.

## Bug real: o teto quebra

`scripts/bench_agentic.py timeline_midnight`. A tarefa vem de um bugfix real do Beahub
(`69d3177`), vendorizada em `scripts/agentic_tasks/timeline_midnight/` com um harness de teste
de 40 linhas em Node puro — sem vitest, para o benchmark não depender do `node_modules` de
outro repositório.

**O bug:** um corte às 23:30 termina em `"00:00"`. Aparece na visão de cards e desaparece da
timeline do dia. `"00:00"` era lido como 0 minutos em vez de fim-do-dia (1440), o que produz
duas falhas independentes da mesma raiz: o loop da grade para no horário de fechamento e nunca
cria o slot das 23:30, e `overlaps()` sempre devolve false porque `end=0`.

| avaliador | resultado |
|---|---|
| suíte single-shot, 6 eixos | 18/18 |
| `test-feature.py` (Cache com TTL) | 5/5, determinístico |
| **`timeline_midnight` (bug real)** | **0/3** |

O mesmo modelo que acerta tudo falha aqui. Três execuções, idênticas: 14 turnos, 3 reescritas,
5 execuções de teste, 11.115 tokens, ~328 s.

### Onde exatamente ele para — e é isto que dá resolução

```
testes: 3/5 → 4/5   (progresso parcial)
```

O modelo **acertou a causa raiz** e aplicou nos três lugares visíveis a partir do sintoma:
tratou `"00:00"` como 1440 em `overlaps()`, no `endMinutes` do `buildDayTimeline`, e fez
`minutesToTime` renderizar 1440 de volta como `"00:00"`.

O que faltou é a **consequência**, não a causa: no teste que ainda falha o horário é 22:00–23:30
e o agendamento é 23:30–00:00, ou seja, começa exatamente no fechamento, *fora* da grade. Nenhum
tratamento de meia-noite conserta isso — é preciso crescer a janela da grade para cobrir
agendamentos fora do horário. E nada na mensagem de erro aponta para lá.

As três tentativas de escrita convergiram todas na mesma ideia. Mínimo local: depois da terceira
ele parou de escrever e gastou 4 turnos relendo os mesmos arquivos.

Comparado com a tarefa do Cache (424 tokens, 3 turnos, uma escrita), 11.115 tokens e 14 turnos é
a diferença entre reproduzir padrão memorizado e tentar raciocinar de fato.

### Por que crédito parcial importa

`3/5 → 4/5` é informação que um veredito binário joga fora. É o que permite comparar duas
configurações que ambas reprovam, e é o que faltava nos outros dois avaliadores. O `task.json`
declara um `regex_placar` para extrair o placar da saída do teste, e o runner mede o placar final
**sempre**, inclusive quando reprova.

### O problema: `424` tokens idênticos cinco vezes

Determinismo perfeito num teste de capacidade normalmente não é sinal de bom raciocínio — é
sinal de memorização. "Cache com TTL" é padrão canônico em qualquer corpus de treino, e o modelo
reproduz a mesma solução byte a byte.

Somando com a suíte de `scripts/run_benchmark.py`, que dá 18/18:

| suíte | resultado | serve para |
|---|---|---|
| single-shot, 6 eixos | 18/18 | dizer "o modelo serve" ✓ |
| agêntico, `test-feature.py` | 5/5, determinístico | dizer "o modelo serve" ✓ |
| qualquer comparação entre modelos ou configs | — | **nada: os dois estão no teto** |

**Dois avaliadores no teto não medem mais nada.** Nenhum consegue dizer se uma mudança de
quantização, de ferramenta ou de modelo melhorou ou piorou, porque não há espaço para melhorar.
Para voltar a ter resolução, o benchmark precisa de tarefas onde este modelo **erre** — ver
`TODO.md` 3.11 e 3.12.

**As duas medidas apontam para lados opostos, e é esse o ponto da seção.** Pelo benchmark de geração o `agent` ganha de longe: 72,5 tok/s contra 24,4, e terminou a sessão em menos tempo de parede. Pelo teste de feature ele é o único que não entrega. Gastou os 14 turnos, reescreveu o arquivo seis vezes, rodou os testes cinco — e saiu com código quebrado.

O bug dele merece registro porque é instrutivo:

```python
if expiration_time is not None and time.time() < expiration_time:
    return value
else:
    del self._data[key]      # cai aqui quando NÃO existe TTL
    return default
```

Sem TTL, `expiration_time` é `None`, a condição é falsa, e o `else` **apaga o valor no primeiro `get`** — quebrando justamente o teste mais simples da suíte, o de valor que deveria persistir para sempre. O modelo viu esse teste falhar cinco vezes e reescreveu em volta dele todas as vezes. De quebra deixou `ttl or self.default_ttl`, que trata `ttl=0` como ausente, e não tocou no `__len__`.

Os dois MoE escreveram código equivalente e correto, com uma diferença de gosto no `__len__`: o `moe` conta sem mutar, o Qwen3.6 apaga os expirados como efeito colateral de `len()`. O segundo faz coleta de lixo de graça, mas `len(c)` alterando o container é surpresa escondida — a versão pura é mais defensável. Ambos usam `time.time()` em vez de `time.monotonic()`: passam nos testes e ficam frágeis se o relógio do sistema recuar.

**O que esta seção não prova.** Uma tarefa é um ponto. O resultado mostra que o 30B-A3B é suficiente e que o 8B não é *nesta* tarefa — não estabelece ordem geral de qualidade, e em particular não diz que o `moe` supera o Qwen3.6, que empatou gastando 3,8× mais tempo. Para isso seria preciso um conjunto de tarefas, o que não temos.

**O que ela prova, e generaliza:** tok/s e ciclo de tool calling não predizem entrega. Um modelo pode passar em `test-tools.py`, ser o mais rápido da bancada, e ainda assim não fechar uma feature de trinta linhas. Antes de adotar um perfil como agente, rode a tarefa real.

```bash
uv run --with pytest scripts/test-feature.py moe --host 192.168.3.51
```

---

## Teste de agente de ponta a ponta

Além do teste sintético, uma tarefa real com o `pi`:

**Cenário:** arquivo Python com bug (`def soma(a, b): return a - b`) e uma segunda função correta. Pedido: *"Leia o arquivo soma.py. Tem um bug na função soma. Corrija o arquivo."*

**Resultado:** o agente leu, editou, corrigiu para `a + b` e preservou a outra função. Validado executando:

```
soma(2,3) = 5      (esperado 5)   ✓
media([1,2,3]) = 2.0 (esperado 2.0) ✓
```

**Custo:** ~5,5 minutos e 4 chamadas ao servidor, para um bug de uma linha.

**O que isso mede:** que a cadeia inteira funciona — modelo, tool calling, cliente, edição de arquivo. **O que não mede:** desempenho num refactor multi-arquivo, onde o contexto cresce e o prompt cache perde eficácia. Essa é a limitação mais relevante e ainda não testada.

---

## Qualidade de código: uma observação, não um benchmark

Não temos benchmark de qualidade — HumanEval e afins exigem infraestrutura que não montamos. Mas um caso vale registro por ser instrutivo.

Mesmo prompt para os dois: *"função debounce em TypeScript com genéricos e cancel()"*.

**Qwen2.5-Coder-7B** produziu:

```typescript
timeout = setTimeout(() => { func(...args); }, wait);
return func(...args);   // ← chama IMEDIATAMENTE
```

Compila, passa no type-check, e **anula o debounce por completo**.

**Qwen3-8B** produziu `fn.apply(this, args)` dentro do timeout, limpou o timer e implementou `cancel()` corretamente. (Imprecisão menor: tipou `this` como `T` em vez de `ThisParameterType<T>` — problema de tipagem, não de lógica.)

**Não conclua** que o Qwen3 escreve melhor código a partir de uma amostra. O que este caso mostra é outra coisa, e essa sim generaliza: **modelo pequeno local erra de formas que parecem certas.** Código plausível, compilável e errado. Revisar não é opcional.

---

## Reproduzindo

```bash
# geração
./macos/llm-server.command start agent
./macos/llm-server.command bench

# tool calling
python3 scripts/test-tools.py mlx-community/Qwen3-8B-4bit 8080

# prefill e prompt cache: rode a mesma requisição grande duas vezes
```

Na Máquina B:

```powershell
.\windows\llm-server.ps1 start agent
.\windows\llm-server.ps1 bench
```

E de outra máquina da rede, contra o servidor da Máquina B:

```bash
LLM_HOST=192.168.3.51 python3 scripts/test-tools.py agent

# e a tarefa real, que e a que decide
uv run --with pytest scripts/test-feature.py moe --host 192.168.3.51
```

Se seus números divergirem muito, verifique nesta ordem: RAM livre, swap, e se o modelo cabe. Quase toda divergência grande vem daí — não do modelo.

Na Máquina B a ordem é outra, porque o teto é VRAM: confirme com `.\windows\llm-server.ps1 vram` que o perfil cabe nos 8 GB. Se não couber, o llama.cpp move camadas para a CPU e a geração despenca sem avisar.
