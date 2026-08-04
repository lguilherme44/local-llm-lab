# Modelos testados e descartados

Por que cada um saiu, com o número que decidiu. Existe para a tabela de perfis do
`llm-server.sh` mostrar só o que dá para usar, sem perder o que custou medir.

Hardware: RTX 3060 Ti (8 GB de VRAM), 16 GB de RAM, Pop!_OS 24.04, llama.cpp compilado com CUDA.

O critério é sempre o mesmo: **quatro tarefas construídas a partir de bugfixes reais do Beahub**,
com o teste automatizado do próprio commit como juiz. Detalhe em
[`benchmarks.md`](benchmarks.md) e no [`STATUS.md`](../STATUS.md).

---

## Qwen3.6 27B denso (`qwen27b`) — inviável por física

| | |
|---|---|
| arquivo | `Qwen3.6-27B-IQ4_NL.gguf`, 15,2 GB |
| geração | **3,1 tok/s** |
| GPU util | 17 % |

15,2 GB de pesos densos não cabem em 8 GB de VRAM, então ~9 GB rodam na CPU a cada token. A placa
fica ociosa esperando.

O contraste que ensina: o `moe` tem **arquivo de tamanho parecido** (16,8 GB) e roda a 37,7 tok/s —
**12× mais rápido** — porque só 3 B de parâmetros são ativados por token. Não é ajuste de flag, é
arquitetura.

Vale registrar que trocar Vulkan por CUDA neste modelo deu apenas **+19 %** (2,7 → 3,2 tok/s). Quando
o gargalo é "os pesos não estão na GPU", o backend não resolve.

## DeepSeek Coder V2 Lite 16B (`deepseek`) — não faz tool calling

| | |
|---|---|
| arquivo | `DeepSeek-Coder-V2-Lite-Instruct-Q4_K_M.gguf`, 9,7 GB |
| geração | 28,4 tok/s |
| fixtures | **0/8** |

`chamadas={}` em **turno 1, nas oito execuções**. Responde em prosa e encerra; nunca emite tool call.

O perfil declarava `tools|sim` — afirmação herdada que nunca havia sido validada nesta máquina. É o
segundo caso da sessão em que o campo `tools` da tabela estava errado.

Duas armadilhas de configuração no caminho, e as duas produziram vereditos falsos antes do
verdadeiro:

1. `NAO_CARREGOU` na primeira varredura, por faltarem **238 MiB** de VRAM em ctx 32k. Era orçamento,
   não incompatibilidade.
2. Ao corrigir, mudei `cpu_moe` **e** `ngl` juntos e creditei o sucesso ao primeiro. Com `ngl 99` o
   KV cache não caberia.

Varredura correta (`cpu_moe 20` fixo, ctx 32k): `ngl 16` → 28,4 tok/s e 6,5 GB; `ngl 24` → OOM,
faltaram 3,9 GB de KV. **A regra "`ngl 99` e deixa o llama.cpp decidir" não é universal** — vale para
o `moe`, e aqui o KV pede ~4,6 GB em 32k mesmo em `q8_0`.

## Bonsai 27B (`bonsai`) — baixamos o arquivo errado, e o certo exige um fork

O que estava em disco era `Bonsai-27B-dspark-bf16.gguf` (7,0 GB). Metadados do GGUF:

```
general.architecture = dspark      (não qwen3)
general.size_label   = 3.6B        (não 27B)
dspark.block_count   = 6           (seis camadas)
```

Era o **drafter de decodificação especulativa**, não o modelo.

A suspeita começou por aritmética: "27 B em 6,79 GB de `bf16`" é impossível, porque 27 B em `bf16`
pesaria ~54 GB. Não era `bf16` de um 27B — era `bf16` de um 3,6B auxiliar.

O modelo real (`Bonsai-27B-Q1_0.gguf`, 3,8 GB) usa ~1,1 bit por peso com kernels `Q1_0_g128`, e o
README da PrismML instrui a clonar **o fork deles do llama.cpp**. O padrão não lê nem a arquitetura
`dspark` nem o quant `Q1_0`.

Sobre a alegação da PrismML (ternário retém 95 % do baseline, 1-bit retém 90 %): a aritmética fecha
— 27 B × 1,71 bits ÷ 8 = 5,77 GB contra 5,9 GB anunciados. Mas são números auto-reportados, e
"retém 90 % de um 27B" não é o mesmo que "melhor que o `moe` que já funciona aqui". Essa comparação
ninguém publicou, e este repositório tem como fazê-la se algum dia valer o custo do segundo binário.

## DeepSeek V4 Flash (`frontier`) — 304 B de parâmetros

| variante | tamanho |
|---|---|
| `UD-IQ1_S` (~1,5 bits) | **82,5 GB** |
| `UD-Q4_K_XL` | 155 GB |

Numa placa de 8 GB com 16 GB de RAM, 82,5 GB significaria streaming de SSD a cada token. O
`qwen27b`, com 15 GB e parte na **RAM** — que é uma ordem de magnitude mais rápida que disco — já dá
3,1 tok/s.

O arquivo que estava em disco era um **stub de 4 KB**, resíduo de download falho anterior à correção
do `pull`.

### A regra que estes dois últimos ensinam

Antes de baixar qualquer modelo, faça a conta: **parâmetros × bits ÷ 8 = tamanho**. Se o tamanho
anunciado for muito menor que a conta, não é o modelo — é uma peça dele.

E `dspark` no nome significa **drafter**, não modelo. Vale para a PrismML e para conversões da
comunidade (`DeepSeek-V4-Flash-0731-DSpark-Drafter-GGUF`, cujo README diz textualmente: *"It is not a
standalone language model and does not contain the target model weights"*).

## Qwen3 8B (`chat8b`, antes `agent`) — mantido, mas nunca como agente

Este **não** foi apagado: é o único que cabe inteiro na VRAM (98 % de uso de GPU, 73,6 tok/s) e
serve para pergunta rápida, mensagem de commit e autocomplete.

Mas como executor é o pior caso possível — **1/8** nas fixtures, e numa delas o placar foi de
**5/8 para 1/8**: quebrou quatro testes que estavam passando. Não é "falhou em corrigir", é "deixou
pior do que encontrou".

Chamava-se `agent` e era o **perfil padrão** do script. Quem rodasse `./llm-server.sh start` sem
argumento recebia justamente o único modelo destrutivo. Renomeado e o padrão trocado para `moe`.

## O que sobrou

**`moe`** — Qwen3.6 35B-A3B, 16,8 GB, 37,7 tok/s, **13/14** nas fixtures. O único validado para
trabalho agêntico.

## A lição que atravessa todos

Três campos da tabela de perfis estavam errados por herança, e nenhum tinha sido medido nesta
máquina: o `tools` do `deepseek`, o `ngl` do `deepseek`, e o `ctx` do `quality`. Um quarto — o nome
`agent` — prometia o que o modelo não entrega.

**Tabela de perfis é documentação, e documentação apodrece.** O que a mantém honesta é o `status` e o
`tps` serem preenchidos por medição, e ficarem vazios (`?`) quando ninguém mediu.
