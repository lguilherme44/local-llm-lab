# Como escolher o modelo

A ordem das perguntas importa. Invertê-la é a causa mais comum de frustração com LLM local.

```
1. Cabe na memória?          se não, nada mais importa
2. Precisa de ferramentas?   se sim, precisa ser comprovado
3. Qual a qualidade?         só agora
```

Quase todo mundo começa pelo 3.

---

## Passo 1: cabe?

### Apple Silicon

```
memória_disponível = RAM_total − ~5 GB (sistema + apps abertos)
teto_de_pesos      = memória_disponível − 1,5 GB (cache KV e folga)
```

Num Mac de 16 GB com uso normal, isso dá um **teto prático de ~5 GB de pesos**. Não os 10 GB que a RAM total sugere.

Verifique o estado real antes de decidir:

```bash
./macos/llm-server.command status     # RAM livre e swap
sysctl vm.swapusage                   # se já está swapando, seu teto é menor ainda
```

Se o swap já está em uso alto **antes** de subir o modelo, a máquina está sob pressão — escolha um perfil menor do que a conta sugere.

### NVIDIA

```
teto = VRAM_total − 0,8 GB (desktop) − cache_KV
```

Numa RTX 3060 Ti (8 GB), com cache KV em `q8_0` e 16k de contexto (1,21 GB), o teto de pesos fica em ~6 GB.

```powershell
.\windows\llm-server.ps1 vram    # mostra o orçamento por perfil
```

### O precipício

Medido na mesma máquina, mesmo runtime:

| modelo | pesos | tok/s |
|---|---|---|
| Qwen2.5-Coder-7B-4bit | 4,3 GB | **19,7** |
| Gemma-4-12B-4bit-QAT | 9,0 GB | **0,7** |

**28× mais lento.** O Gemma 4 não é um modelo ruim — ele simplesmente não caía nos 16 GB com apps abertos. Cada token virou uma ida ao disco.

A lição: **não existe "um pouco grande demais".** Ou cabe, e você tem velocidade usável, ou não cabe, e fica inutilizável. Escolha o maior que **cabe com folga**, não o maior que "quase cabe".

---

## Passo 2: precisa chamar ferramentas?

Isso divide os modelos em duas categorias que **não** se sobrepõem com qualidade de código.

**Você precisa de tool calling se** vai usar um agente — `pi`, Cline, Aider, o modo Agent do Continue. O agente precisa que o modelo devolva uma chamada estruturada (`tool_calls` no JSON) para poder ler arquivos, rodar comandos e editar código.

**Você não precisa se** vai usar só chat, explicação de código, ou edição inline no editor.

E aqui está o resultado que contraria a intuição:

| modelo | escreve código | tool calling |
|---|---|---|
| Qwen2.5-Coder-7B | melhor | ❌ falha |
| Qwen2.5-Coder-14B | melhor ainda | ❌ falha |
| Qwen3-8B | bom | ✅ funciona |
| Qwen3-4B | ok | ✅ funciona |

Os modelos **especializados em código são os que falham** como agente. O fine-tune que os tornou melhores em escrever código degradou a capacidade de emitir chamadas de ferramenta no formato correto — eles produzem `<tools>` (a tag que *declara* as ferramentas disponíveis) onde deveriam produzir `<tool_call>` (a tag que *faz* a chamada).

**Nunca confie na promessa.** O `config.json` pode declarar suporte a tools, o chat template pode ter a tag certa, e o modelo ainda errar na hora. Teste:

```bash
python3 scripts/test-tools.py <repo-ou-alias> [porta]
```

Metodologia e resultados completos em [tool calling](03-tool-calling.md).

**A combinação que funciona bem:** dois perfis, um de cada tipo. Use o `agent` (Qwen3) com o `pi`, e o `fast` (Qwen2.5-Coder) para chat no VSCode. Trocar leva 5 segundos:

```bash
./macos/llm-server.command restart fast
```

---

## Passo 3: agora sim, qualidade

Com os dois filtros aplicados, sobram poucas opções. Aí valem as regras normais:

- **Mais parâmetros > mais bits.** Um 8B em 4-bit é melhor que um 4B em 8-bit, com tamanho parecido.
- **Prefira `-qat` quando existir.** Treinado ciente da quantização, perde muito menos.
- **`-Instruct` / `-it` para conversa.** Modelos base (sem sufixo) completam texto, não seguem instruções.
- **MoE (`A3B`) só com memória sobrando.** Ativa poucos parâmetros por token, mas carrega todos.

### O caso contra "o maior que couber"

Medido com llama.cpp, mesma máquina:

| modelo | pesos | tok/s |
|---|---|---|
| Qwen3-4B Q4_K_M | 2,50 GB | **33,1** |
| Qwen3-8B Q4_K_M | 5,03 GB | 18,8 |

O 4B roda ao **dobro** da velocidade e faz tool calling igualmente bem. O 8B dá respostas melhores, mas em hardware limitado a pergunta é: *melhor o suficiente para valer metade dos tokens por segundo?*

Para autocomplete e tarefas mecânicas, não. Para raciocinar sobre arquitetura, provavelmente sim. **Tenha os dois e troque conforme a tarefa** — é mais barato que escolher errado uma vez.

---

## Onde procurar modelos

**Apple Silicon (MLX):** organização [`mlx-community`](https://huggingface.co/mlx-community) no Hugging Face. Convenção de nomes: `<modelo>-<quant>`, com sufixos `-it`/`-Instruct` (instruction-tuned), `-qat`, `-OptiQ`, `-dwq`/`-DWQ` (quantização com destilação).

**NVIDIA / llama.cpp (GGUF):** repositórios `*-GGUF`. As fontes mais confiáveis são a organização oficial do modelo (ex: `Qwen/Qwen3-8B-GGUF`) e `bartowski`, que publica muitas variantes de quantização.

Antes de baixar, deixe o script verificar:

```bash
./macos/llm-server.command add mlx-community/Qwen3-14B-4bit
```

Ele consulta a API do Hugging Face primeiro e mostra tamanho, `model_type` e formato — e recusa repos GGUF apontando para o llama.cpp, em vez de baixar 20 GB inúteis.

---

## Resumo em uma tela

| sua situação | perfil | por quê |
|---|---|---|
| 8–16 GB, quer agente | `agent` (Qwen3-8B) | tool calling comprovado, cabe |
| 8–16 GB, chat/edit no editor | `fast` (Qwen2.5-Coder-7B) | código melhor, tools não importam |
| memória muito apertada | `tiny` (Qwen3-4B) | 1,5× mais rápido, tools funcionam |
| GPU de 8 GB **e** 16 GB de RAM livre | `moe` (Qwen3-Coder-30B-A3B) | só no Windows; ver a ressalva abaixo |
| 32 GB+ | teste `balanced`/`quality` | aí o teto é outro — meça |
| precisa de imagem/áudio | modelo multimodal + `mlx_vlm` | `mlx_lm` não carrega |

---

## A exceção MoE

Tudo acima assume modelo **denso**, onde a regra é dura: o que não cabe na memória rápida é inutilizável, e a queda é de 28×, não de 30%.

Modelos **MoE** quebram essa regra por construção. O `moe` do Windows serve um Qwen3-Coder de 30 B numa 3060 Ti de 8 GB porque só 8 dos seus 128 experts são lidos por token — então manter experts na RAM do sistema custa pouco, enquanto a atenção, lida sempre, fica na GPU.

Medido: **24,4 tok/s de geração e 595 de prefill**, contra 72,5 e 393 do `agent`. Gera 3× mais devagar e faz prefill 1,5× *mais rápido* — e prefill é o que domina em uso agêntico.

**A ressalva, e ela é séria:** com 16 GB de RAM ele sobe com ~0,2 GB livres. Não é "apertado", é sem margem. Abrir o navegador empurra experts para o pagefile, e aí a geração vai a 1–2 tok/s. Se a sua máquina tem 16 GB e você usa ela para outra coisa ao mesmo tempo, fique no `agent`. Com 32 GB, o `moe` deixa de ter ressalva.

Números e método completos em [benchmarks](benchmarks.md#um-moe-de-30b-numa-gpu-de-8-gb).

---

Próximo: [tool calling — metodologia e resultados](03-tool-calling.md).
