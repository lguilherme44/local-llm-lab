# Diagnóstico — regressão no Linux e benchmarks inconclusivos

**Data:** 2026-08-03
**Máquina alvo:** Pop!_OS 24.04, RTX 3060 Ti (8 GB VRAM), 16 GiB RAM, 12 cores, driver 595.84
**Sintomas relatados:** no Windows os mesmos modelos geravam a landing page completa; no Linux não
terminam um `index.html` sem quebrar. Estatísticas do benchmark confusas e não conclusivas.

---

## Resultado final medido (CUDA compilado)

CUDA foi compilado e medido. **O ganho não veio do backend** — veio de entender que
o modelo precisa caber na VRAM. Mesma máquina, mesmas flags, mesmo dia:

| perfil | pesos | arquitetura | geração | prefill | GPU util |
|---|---|---|---|---|---|
| `agent` Qwen3 8B | 5.0 GB | densa, **cabe na VRAM** | **73.6 tok/s** | 66.0 tok/s | **98 %** |
| `moe` Qwen3.6 35B-A3B | 16.8 GB | MoE, 3 B ativos | **27.2 tok/s** | 27.3 tok/s | 21 % |
| `qwen27b` Qwen3.6 27B | 15.2 GB | densa, não cabe | **3.1 tok/s** | 7.0 tok/s | 17 % |

O `qwen27b` denso: Vulkan 2.7 → CUDA 3.2 tok/s. **+19 %, não 10×.** A previsão de
15-30 tok/s com CUDA estava errada, e o motivo é físico: 15.2 GB de pesos densos em 8 GB de
VRAM significa ~9 GB na RAM computados pela CPU, a cada token. Nenhum backend conserta isso.
GPU a 17 % é a assinatura do problema — a placa está ociosa esperando a CPU.

O MoE entrega **9× o denso do mesmo tamanho** porque só 3 B de parâmetros são ativados por
token. Os pesos ainda estão na RAM, mas o volume de multiplicação por token é ordens de
grandeza menor.

### Afinando o MoE: +50% que estava sendo desperdiçado

A GPU a 21 % e a VRAM em 4.5 de 8 GB indicavam folga ociosa. Varredura medida:

| `-ngl` | `--n-cpu-moe` | geração | VRAM | veredito |
|---|---|---|---|---|
| 36 | 36 | 25.4 tok/s | 4.5 GB | ponto de partida herdado do Windows |
| 99 | 36 | 32.0 tok/s | 4.9 GB | só subir o `ngl` já dá +26 % |
| 99 | 32 | 36.1 tok/s | 6.4 GB | |
| 99 | 30 | **37.7 tok/s** | 7.1 GB | **escolhido** — +50 %, ~1 GB de folga |
| 99 | 29 | 38.2 tok/s | 7.5 GB | fio de navalha; qualquer app derruba |
| 99 | 28 | `abort (core dumped)` | — | estourou a VRAM |

O botão real é o `--n-cpu-moe`, não o `-ngl`: baixá-lo devolve tensores de expert da RAM para a
VRAM. O `-ngl 36` herdado do Windows estava deixando 26 % de performance na mesa sem motivo.

`cpu_moe=29` é 1.3 % mais rápido que 30 e consome 400 MB a mais. Não vale: o desktop COSMIC mais
o Chrome já usam ~600 MB de VRAM, e um pico deles com 29 mata o servidor. Ficar em 30 troca
1.3 % de throughput por não ter o serviço caindo.

Qualidade revalidada com a config nova: **6/6 nos cinco eixos**, nenhuma truncagem.

**A intuição original de testar MoE estava certa, e por uma razão melhor do que a suposta.**
Não é "mesmo que lento, entregaria bom código": é que MoE é a *única* arquitetura que torna
um modelo grande viável nesta máquina.

## Resumo executivo

A regressão no Linux não tem relação com os modelos escolhidos. `linux/llm-server.sh` é um port
incompleto de `windows/llm-server.ps1` e perde as quatro decisões que fazem o Windows funcionar:
backend CUDA, `-ngl 999`, KV cache em `q8_0` e flash attention. O resultado é 2.69 tok/s de geração
e prefill entre 1 e 9 tok/s, com swap ativo.

Em paralelo, `scripts/run_moe_benchmark_pipeline.py` não instrumenta o que mede: não registra
`finish_reason`, estima contagem de tokens por divisão de caracteres, aquece o prompt cache antes de
medir TTFT e pontua qualidade por presença de substring. Ele é incapaz de detectar o próprio
fracasso — daí o `BENCHMARK_REPORT.md` afirmar *"Issues: None detected"* para um HTML cortado no
meio de uma tag.

---

## Parte 1 — A regressão no Linux

### 1.1 O backend é Vulkan, não CUDA

`linux/llm-server.sh:148` baixava o asset Vulkan:

```bash
URL=".../llama-${LATEST_TAG}-bin-ubuntu-vulkan-x64.tar.gz"
```

O cabeçalho do mesmo arquivo se descreve como "llama.cpp com CUDA". O script do Windows, por outro
lado, documenta explicitamente o risco que o do Linux corre (`windows/llm-server.ps1:527-528`):

> `# winget install llama.cpp entrega build CPU/Vulkan, SEM CUDA. Por isso vamos`
> `# direto no release do GitHub pegar o zip com CUDA.`

Confirmado na máquina: existe `libggml-vulkan.so` e **nenhuma** biblioteca CUDA.

**Causa raiz do port ter falhado:** o release do llama.cpp **não publica build CUDA para Linux**.
No release `b10242` os únicos assets CUDA são `llama-*-bin-win-cuda-12.4-x64.zip` e
`-13.3-x64.zip`. Para Linux há `vulkan`, `rocm`, `sycl`, `openvino` e CPU puro. Quem escreveu o
script procurou o asset CUDA, não achou, e aceitou o Vulkan. No Linux **CUDA exige compilar do
fonte** com `-DGGML_CUDA=ON`.

O `cmd_setup` original tinha um fallback que compilava — mas só se o download falhasse. Como o
download do Vulkan sempre teve sucesso, o caminho de compilação nunca executou.

### 1.2 `-ngl` foi confundido com `--n-cpu-moe` (mas isso NÃO causava a lentidão)

> **Correção.** A primeira versão deste documento afirmava que o `-ngl 24` fixo era causa da
> lentidão, por abortar o auto-fit do llama.cpp. **Isso estava errado** e o teste derrubou a
> hipótese. Ver 1.2.1 e 1.4.1. O acoplamento continua sendo defeito de design — mas era um
> defeito benigno.


`linux/llm-server.sh:219-222` derivava o número de camadas na GPU do campo `cpu_moe` do perfil:

```bash
local default_ngl=28
if [[ "$cpu_moe" -gt 0 ]]; then
  default_ngl="$cpu_moe"     # <-- bug
fi
```

São grandezas diferentes:

- `-ngl N` — quantas camadas do modelo vão para a VRAM.
- `--n-cpu-moe N` — de quantas camadas os tensores de *expert* ficam na RAM.

O perfil `qwen27b` tem `cpu_moe=24`, então o servidor subiu com `-ngl 24 --n-cpu-moe 24`. Efeito
observado no log do servidor:

```
W common_fit_params: failed to fit params to free device memory:
  n_gpu_layers already set by user to 24, abort
```

O llama.cpp b10240+ usa `-ngl auto` **por padrão** e dimensiona sozinho contra a VRAM livre.

#### 1.2.1 Por que a correção "óbvia" não funciona

Tentativa 1 — copiar o `-ngl 999` do Windows: **falhou**, `ErrorOutOfDeviceMemory` na carga. Neste
build **qualquer** valor explícito desliga o `common_fit_params`, inclusive 999. O comentário do
script do Windows (*"o llama.cpp reduz se nao couber"*) descreve comportamento de versão antiga.

Tentativa 2 — usar `-ngl auto`: **também falhou**, com um abort diferente:

```
W common_fit_params: failed to fit params to free device memory:
  model_params::tensor_buft_overrides already set by user, abort
```

`--n-cpu-moe` seta `tensor_buft_overrides`, e isso **também** aborta o auto-fit. Com o fit abortado,
`auto` resolve para "todas as camadas" e estoura a VRAM.

**Regra real deste build, não documentada de forma óbvia:** um perfil que usa `--n-cpu-moe` é
*obrigado* a passar `-ngl` explícito. Só perfis com `cpu_moe = 0` podem usar `auto`.

Ou seja: o `-ngl 24` original era **necessário**, não errado. O aviso de abort que encontrei era
consequência do `--n-cpu-moe`, não a doença. O defeito real era derivar o número de `cpu_moe` —
funcionava por coincidência, e quebraria em qualquer perfil onde os dois números divergissem.

Correção aplicada: coluna `ngl` própria na tabela de perfis, `auto` quando `cpu_moe = 0`.

### 1.3 KV cache em f16 e sem flash attention

Paridade perdida entre as duas plataformas:

| Flag | Windows (`llm-server.ps1:827-846`) | Linux (antes) |
|---|---|---|
| Backend | `bin-win-cuda-12.4` | `bin-ubuntu-vulkan` |
| `-ngl` | `999` | `24` (= `cpu_moe`) |
| KV cache | `-ctk q8_0 -ctv q8_0` | ausente → f16, 2× a VRAM |
| Flash attention | `-fa on` | ausente |
| Template | `--jinja` | ausente (default, ok) |
| Alias | `-a <perfil>` | ausente |

O KV em `q8_0` é o que torna 16k de contexto viável em 8 GB. Comentário do Windows
(`llm-server.ps1:806`): *"corta o cache KV pela metade: é o que faz 16k de contexto caber"*.

### 1.4 Medição do estado degradado

Perfil `qwen27b` (`Qwen3.6-27B-IQ4_NL.gguf`, 15.22 GB), como estava rodando:

```
eval time         =  2.69 tokens per second     <- geração
prompt eval time  =  8.80 tokens per second     <- prefill
prompt processing =  1.23 tokens per second
graphs reused     =  1123
GPU util          =  18 %
VRAM              =  6997 / 8192 MiB
```

Prefill entre 1 e 9 tok/s numa 3060 Ti. Com CUDA a ordem de grandeza esperada é 500–1500 tok/s. A
GPU a 18% indica que ela está ociosa esperando CPU e disco.

Pressão de memória no mesmo instante:

```
Mem:   15Gi total | 4.3Gi used | 904Mi free | 11Gi buff/cache
Swap:  19Gi total | 2.5Gi used
vmstat: si 180  so 339  bi 8934
```

`si`/`so` diferentes de zero são swap in/out ativo. `bi 8934` é leitura de bloco constante — as
páginas mmap do modelo estão sendo despejadas e relidas do disco a cada token. 15.22 GB de pesos
mais KV em f16 não têm folga em 15 GiB de RAM. O KV em `q8_0` recuperaria justamente essa margem.

### 1.4.1 Experimento controlado: as flags não são o gargalo

Depois de aplicar `-ctk q8_0 -ctv q8_0 -fa on --jinja` e desacoplar o `-ngl`, **mantendo o backend
Vulkan**, medido no mesmo perfil `qwen27b`:

| métrica | Vulkan, flags originais | Vulkan, flags corrigidas |
|---|---|---|
| geração | 2.69 tok/s | **2.7 tok/s** — igual |
| prefill | 1–9 tok/s | 5–9 tok/s — igual |
| VRAM | 6997 MiB | 6774 MiB |
| GPU util | 18 % | 53 % |
| swap in/out | `si 180  so 339` | `si 40  so 0` — resolvido |

**Conclusão:** o KV em `q8_0` entregou folga de memória real e eliminou o thrashing de swap — o que
importa para subir o contexto além de 16k. Mas em throughput não mudou **nada**.

Isso isola a variável de forma limpa: o gargalo é inteiramente o backend. Vale registrar porque é
tentador atribuir o ganho futuro às flags quando o CUDA entrar — não será delas.

### 1.5 Por que as páginas truncam

Evidência nos artefatos gerados:

| Arquivo | Tamanho | Termina em |
|---|---|---|
| `examples/landing-page/index.html` (Windows) | 30 643 B | `</body></html>` — completo |
| `examples/landing-page-qwen3.6-35b/index.html` | 27 303 B | meio de um `<path d="...` |
| `examples/landing-page-qwen3.6-27b/index.html` | 12 404 B | meio de `<rect x="2" y="2"` |
| `examples/landing-page-deepseek-v2-lite/index.html` | 5 535 B | `</body></html>` — completo, mas curto |
| `examples/landing-page-bonsai-27b/` | vazio | o modelo falhou sem deixar registro |

Cortes no meio de atributo não são fim-de-sequência do modelo; são interrupção de stream.

#### Causa confirmada: os tokens de raciocínio consomem a cota e são invisíveis

Modelos com reasoning (Qwen3.6, DeepSeek-R1 e afins) emitem os tokens de pensamento em
`delta.reasoning_content`, **não** em `delta.content`. Eles consomem `max_tokens` exatamente igual,
mas não aparecem na resposta. O pipeline antigo lia somente `content` (`:193`), então esse gasto era
completamente invisível para a medição.

Verificado contra o servidor, perfil `qwen27b`, prompt *"Diga apenas: ok"* com `max_tokens=40`:

```
TTFT 1.13s | 2.8 tok/s | 40 tok | fim=length | reasoning 100% da saída
content   = ''
reasoning = "Here's a thinking process:\n\n1.  **Analyze User Input:** ..."
```

Quarenta tokens, todos em raciocínio, zero de conteúdo, `finish_reason=length`.

Isso casa exatamente com o padrão dos artefatos, e a tabela de perfis fecha a prova:

| perfil | `extra_args` | página gerada |
|---|---|---|
| `moe` (35B-A3B) | `--reasoning off` | 27 303 B, longa |
| `agent` | `--reasoning off` | — |
| `qwen27b` | **nenhum** | 12 404 B, cortada no meio de `<rect>` |
| `deepseek` | **nenhum** | 5 535 B, curta |
| `bonsai` | **nenhum** | falhou |

Os dois perfis com `--reasoning off` produziram as saídas longas. Os que não têm gastaram a cota
pensando e o HTML ficou com o resto, batendo em `length` no meio de uma tag.

O `urlopen(timeout=300)` e o swap eram hipóteses razoáveis, mas não eram a causa: o servidor tem
`--timeout 3600` e o corte veio de `max_tokens`, não da rede.

**A falha de engenharia central permanece a mesma:** o pipeline não gravava `finish_reason` nem
`usage`. Com `finish_reason=length` registrado, esse bug teria sido óbvio na primeira execução em vez
de virar "Issues: None detected".

#### O que NÃO fazer com essa descoberta

A correção reflexa é adicionar `--reasoning off` nos perfis que faltam. **Cuidado:** o objetivo
declarado é qualidade de código, não velocidade, e para tarefas de raciocínio o pensamento
normalmente *melhora* o resultado. Desligá-lo para caber no orçamento é trocar exatamente a
dimensão que interessa pela que não interessa.

O caminho correto é dimensionar `max_tokens` contabilizando o raciocínio, e medir a fração gasta
nele por modelo — que é agora um campo de primeira classe (`reasoning_share`) em
`scripts/bench_lib.py`. Um modelo que queima 90% da cota pensando para escrever HTML é um dado
relevante sobre esse modelo, não um detalhe de configuração a ser escondido.

### 1.6 A escolha de MoE estava certa

Contra-intuitivo, mas o dado sustenta: o `moe` (35B-A3B, 3 B de parâmetros ativos) gerou 27 KB,
mais que o dobro do `qwen27b` denso (12 KB). Menos pesos tocados por token é exatamente a
arquitetura adequada a 8 GB de VRAM com experts na RAM. O problema nunca foi o modelo.

---

## Parte 2 — Por que as estatísticas não concluem nada

Defeitos em `scripts/run_moe_benchmark_pipeline.py`, por linha da versão original:

### 2.1 `:207` — contagem de tokens inventada

```python
tok_count = max(len(full_text) // 4, len(chunks_text))
```

O llama.cpp devolve `timings.predicted_per_second` e `predicted_n` exatos no chunk final do stream.
O próprio `llm-server.sh bench` (`:420-421`) já lê isso corretamente. O pipeline descarta e estima
4 caracteres por token. HTML e código ficam perto de 3 → **tok/s superestimado em ~25%**.

### 2.2 `:226` — o warmup invalida o TTFT

```python
print("  ♨️ Executando Warmup (descarta cache)...")
execute_streaming_request(prompt, max_tokens=128)
```

O comentário diz o contrário do que o código faz: usa o **mesmo prompt** das rodadas seguintes, o
que popula o prompt cache do llama.cpp. Todos os TTFT medidos depois são cache hit. O log do
servidor confirma reuso (`selected slot by LCP similarity`).

### 2.3 `:246` — "P95" sobre 4 amostras

```python
p95_idx = int(math.ceil(0.95 * n)) - 1   # n=4  ->  ceil(3.8)-1 = 3
```

Com 4 rodadas o índice é sempre o último do array ordenado. A coluna "Geração P95" do dashboard é
literalmente o máximo. Não é percentil de nada.

### 2.4 `:274` — score de qualidade por substring

```python
"dark_mode": "dark" in low or "bg-gray-900" in low or ...
"animations": "transition" in low or "hover:" in low,
```

Sete checks booleanos de presença de texto. Um HTML truncado que não parseia passa em 6 dos 7 e
tira **8.6/10**. Nenhum check valida que o documento é HTML válido de verdade.

### 2.5 `:319` — o teste de raciocínio é gratuito

```python
has_correct_math = "10" in reasoning_res["content"] and "30" in reasoning_res["content"]
```

O enunciado do prompt já contém "Há 10 anos". Qualquer resposta que mencione 30 em qualquer contexto
passa. O mesmo vale para SQL (`:328`) e NestJS (`:337`): presença de palavra-chave, não correção.

### 2.6 `:110` — o instrumento contamina a medição

```python
ssh_cmd = ["ssh", ..., "nvidia-smi --query-gpu=..."]
while self._running:
    subprocess.run(ssh_cmd, ...)
    time.sleep(self.interval)
```

Uma conexão SSH nova por segundo na máquina que está sendo medida. Cada handshake custa CPU e
memória numa máquina com 904 Mi livres. O correto é uma sessão SSH única com
`nvidia-smi --loop-ms=1000` transmitindo continuamente.

### 2.7 RAM e swap nunca são coletados

`peak_ram_gb` aparece só no dict de fallback (`:97`) e nunca é preenchido. Para MoE com experts na
CPU, RAM e swap **são** a métrica limitante — e não estão no relatório.

### 2.8 Zero tratamento de erro por modelo

`main()` não tem `try/except`. `examples/landing-page-bonsai-27b/` está vazio: o Bonsai falhou e não
há linha no relatório nem diagnóstico. Falha silenciosa. O retorno de `run_ssh` no `pull` (`:433`)
também é ignorado.

### 2.9 Uma amostra por teste de qualidade

Uma chamada por tarefa, `temperature=0.2`. Sem repetição e sem variância: é um lance de dado por
modelo. Não dá para distinguir modelo de sorte.

---

## Parte 3 — Landing page é um bom teste para o objetivo?

**Objetivo declarado:** um modelo local para programar, entregar features e corrigir bugs.
Qualidade importa, velocidade não.

**Resposta: não.** Gerar landing page mede quase o oposto disso.

| Landing page mede | Programar de verdade exige |
|---|---|
| Geração longa de output novo | Edição cirúrgica em código existente |
| Zero contexto de entrada | Ler e entender 5–20k tokens de repo alheio |
| Boilerplate Tailwind — o padrão mais memorizado de qualquer corpus | APIs específicas que não podem ser alucinadas |
| Zero tool calling | Loop de ferramentas confiável (ler / editar / rodar teste) |
| Avaliação visual e subjetiva | Passou o teste ou não passou — binário |

Pior: ela **premia o defeito**. Quem cospe mais Tailwind decorado pontua mais alto, e isso não diz
nada sobre corrigir um bug. E como o output é longo, o teste é o mais sensível possível ao gargalo
de throughput — justamente a dimensão que não interessa aqui.

### 3.1 O que medir em vez disso

Cinco eixos, todos com sinal objetivo e verificável por máquina:

1. **Bug fix com teste falhando** — 10 a 15 tarefas extraídas dos próprios repos: um teste vermelho
   mais o arquivo relevante. Métrica: `pass@1` e `pass@3`. Verde ou vermelho, sem juiz.
2. **Aderência a formato de patch** — o modelo devolve search/replace ou diff unificado que
   **aplica limpo**? É onde a maioria dos modelos locais morre como agente, e é invisível num teste
   de HTML.
3. **Tool calling em loop** — N iterações sem alucinar assinatura nem travar. Os perfis marcam
   `tools|sim` e nada valida essa afirmação.
4. **Compreensão de contexto longo** — enterrar um detalhe em 8k de código real e perguntar.
5. **Instrução restritiva** — "responda APENAS o JSON". Taxa de conformidade.

Landing page pode continuar existindo como *smoke test* de "o modelo consegue produzir output longo
sem quebrar" — isso é útil, e é a única coisa que ela mede bem. Mas não pode ser confundida com
avaliação de capacidade de programação, e não pode entrar na média de um score único.

### 3.2 Sobre o score único

`overall_score` hoje é a média de quatro notas, três delas binárias 10-ou-4. Resolução péssima e
mistura dimensões incomparáveis. Um score agregado só se justifica com pesos explícitos e
declarados; caso contrário reporte os eixos separados.

---

## Ordem de correção

Refazer a estatística antes de corrigir o backend é medir com régua torta em mais casas decimais.

1. CUDA compilado no Linux, `-ngl 999`, KV `q8_0`, `-fa on`.
2. Medir de novo e confirmar a ordem de grandeza do prefill.
3. Instrumentação honesta do pipeline (`timings`, `finish_reason`, RAM/swap, erro por modelo).
4. Suíte de qualidade objetiva substituindo os checks por substring.

## Bloqueio conhecido

Instalar o CUDA toolkit e o cmake na máquina Linux exige `sudo` com senha — não é executável a
partir daqui. Comando preparado no `TODO.md`.
