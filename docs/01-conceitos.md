# Conceitos que decidem se vai funcionar

Antes de escolher um modelo, quatro conceitos. Sem eles você escolhe por tamanho e se frustra.

---

## 1. Quantização: por que "4-bit" não significa 4× menor

Um modelo é uma pilha de matrizes de números. Treinado, cada número ocupa 16 bits (`bf16`). Quantizar é guardar esses números com menos bits.

| formato | bits por peso | modelo de 8B fica com |
|---|---|---|
| `bf16` | 16 | ~16 GB |
| `8-bit` | 8 | ~8,5 GB |
| `4-bit` | 4 | ~4,6 GB |

A conta não é exata porque **nem toda camada é quantizada igual**. Embeddings e algumas camadas de atenção são sensíveis: cortá-las para 4 bits degrada muito. Então os formatos bons usam precisão mista.

**Três variantes que valem conhecer:**

- **QAT** (*Quantization Aware Training*) — o modelo foi **treinado** já ciente de que seria quantizado. A perda é muito menor que quantizar depois do treino. Quando existe uma variante `-qat`, ela é preferível ao 4-bit comum do mesmo modelo.
- **OptiQ** — quantização de precisão mista nativa do MLX: camadas sensíveis ficam em 8 bits, o resto cai para 4. Cuidado: a alocação de bits é medida no modelo base, então em cima de um fine-tune as sensibilidades podem ter mudado.
- **`Q4_K_M`, `Q5_K_M`, `Q6_K`** (GGUF/llama.cpp) — o `_K` indica quantização por blocos com escala; `_M` é o tamanho médio da variante. `Q4_K_M` é o ponto de equilíbrio mais usado.

**Regra prática:** 4-bit é o padrão sensato. 8-bit raramente compensa o dobro de memória. Abaixo de 4-bit (3-bit, 2-bit) a degradação deixa de ser sutil.

---

## 2. Cache KV: o custo escondido do contexto

O peso do modelo é fixo. O **cache KV** não — ele cresce com o tamanho da conversa, e é o que faz um modelo "que cabia" estourar a memória no meio do uso.

A cada token processado, o modelo guarda dois vetores (Key e Value) por camada. A conta:

```
bytes por token = 2 (K e V) × camadas × kv_heads × head_dim × bytes_por_valor
```

Para o **Qwen3-8B** (36 camadas, 8 kv-heads, head_dim 128, `f16` = 2 bytes):

```
2 × 36 × 8 × 128 × 2 = 147.456 bytes ≈ 144 KB por token
```

Parece pouco. Multiplique:

| contexto | cache KV em `f16` | em `q8_0` |
|---|---|---|
| 4.096 | 0,60 GB | 0,30 GB |
| 8.192 | 1,21 GB | 0,60 GB |
| 16.384 | 2,42 GB | 1,21 GB |
| 32.768 | **4,83 GB** | 2,42 GB |

Em 32k de contexto, o cache KV quase iguala o peso do modelo. **É por isso que existe quantização de cache KV** (`--kv-bits 8` no MLX, `-ctk q8_0 -ctv q8_0` no llama.cpp): corta pela metade com perda desprezível.

Numa GPU de 8 GB, isso é a diferença entre 16k de contexto caber ou não:

```
modelo Q4_K_M    5,03 GB
cache KV q8_0    1,21 GB   (16k)
                 -------
total            6,24 GB   ← cabe nos 8 GB com folga para o desktop
```

Como calcular para outro modelo: pegue `num_hidden_layers`, `num_key_value_heads` e `head_dim` do `config.json` do repositório.

---

## 3. Memória unificada (Apple) ≠ VRAM (NVIDIA)

Parecem o mesmo problema, mas se comportam de forma diferente — e isso muda o diagnóstico.

**Apple Silicon (memória unificada).** CPU e GPU compartilham a mesma RAM. Um modelo de 9 GB num Mac de 16 GB *funciona*, mas compete com o sistema, o navegador e a IDE. Quando aperta, o macOS **comprime e envia para swap** — e a geração desaba sem nenhuma mensagem de erro. Foi como medimos 0,7 tok/s num modelo que deveria fazer ~15.

Dois detalhes que enganam:

- **O `RSS` do processo não mede os pesos.** O MLX aloca em buffers Metal, que não entram no *resident set size*. Um modelo de 9 GB carregado aparece como ~0,02 GB no `ps`. Meça por RAM livre e swap, nunca por RSS.
- **O swap consome disco.** Os swapfiles são arquivos reais. Numa máquina apertada, pouca RAM gera swap, swap enche o disco, e disco cheio limita o que dá para instalar para aliviar. Antes de investigar "disco encheu do nada", rode `sysctl vm.swapusage`.

**NVIDIA (VRAM dedicada).** O limite é rígido: 8 GB são 8 GB. Mas o llama.cpp **não falha** quando não cabe — ele silenciosamente move camadas para a CPU (`-ngl` controla quantas vão para a GPU). O resultado é o mesmo sintoma, causa diferente: fica muito mais lento sem avisar.

**Consequência prática:** em Apple, deixe ~1,5 GB de folga sobre o peso do modelo. Em NVIDIA, ~0,8 GB para o desktop. Nos dois casos, se o `bench` der um número muito abaixo do esperado, suspeite de memória antes de suspeitar do modelo.

---

## 4. Prefill vs geração: dois gargalos diferentes

Toda resposta tem duas fases, com velocidades independentes:

- **Prefill** — processar o prompt que você enviou. Paralelizável, medido em tokens/s de entrada.
- **Geração** — produzir a resposta, um token por vez. Sequencial, e é o número que os benchmarks costumam citar.

No MacBook Air M4 medimos **~176 tok/s de prefill** e **~19 tok/s de geração**. Parece que o prefill não é problema — até você usar um agente.

Um agente de código injeta um system prompt grande, definições de ferramentas e o histórico. **A cada turno.** Com 3.500 tokens de prompt, são 20 segundos antes do primeiro token da resposta. Com 10k, mais de um minuto.

**É aqui que o prompt cache decide a viabilidade.** Ele guarda o estado do prefixo já processado; se o próximo pedido começa igual, aquele trecho não é reprocessado. Medido: o mesmo prompt de 3.517 tokens caiu de **20 s para 0,78 s** — 25× mais rápido.

Por isso os scripts ligam `--prompt-cache-bytes` / `--prompt-cache-size`. Sem isso, agente local em hardware modesto é inviável; com isso, o custo alto é pago só no primeiro turno.

**A ressalva honesta:** contexto que *cresce* invalida parte do cache a cada passo. O ganho é grande em prefixo estável (system prompt, ferramentas) e menor num refactor longo onde o histórico muda sempre.

---

## Bônus: nomenclatura que confunde

**`E4B` não é "4 bilhões de parâmetros".** No Gemma 3n, `E` significa *Effective*: o modelo tem ~8B de pesos brutos, mas usa MatFormer e *Per-Layer Embeddings* para manter um footprint ativo equivalente a um 4B. Consequência prática: o arquivo em disco é bem maior do que o nome sugere — o `E4B` em 8-bit tem 9,3 GB.

**`A3B` indica MoE.** Em `Qwen3-Coder-30B-A3B`, são 30B de parâmetros totais com apenas ~3B **ativos** por token (*Mixture of Experts*). Isso dá velocidade de um 3B com qualidade próxima de um modelo muito maior — **mas todos os 30B precisam estar carregados na memória**. Ótimo com RAM sobrando, inútil quando o gargalo é memória.

---

Próximo: [como escolher o modelo](02-escolher-modelo.md).
