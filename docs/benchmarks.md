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
```

Se seus números divergirem muito, verifique nesta ordem: RAM livre, swap, e se o modelo cabe. Quase toda divergência grande vem daí — não do modelo.

Na Máquina B a ordem é outra, porque o teto é VRAM: confirme com `.\windows\llm-server.ps1 vram` que o perfil cabe nos 8 GB. Se não couber, o llama.cpp move camadas para a CPU e a geração despenca sem avisar.
