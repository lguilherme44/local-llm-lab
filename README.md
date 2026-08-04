# local-llm-lab

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-lightgrey.svg?style=flat-square)](#instalação)
[![Runtime](https://img.shields.io/badge/runtime-llama.cpp%20%7C%20MLX-blue.svg?style=flat-square)](#instalação)

Scripts e medições para rodar LLM local em NVIDIA e Apple Silicon. O objetivo é
específico: achar um modelo local que sirva para **programar de verdade** — corrigir
bug, entregar feature, rodar num loop de agente. Não para conversar.

Tudo aqui foi medido na máquina, e o que deu errado está registrado junto.

## Onde estamos hoje

A máquina principal é um Linux com RTX 3060 Ti (8 GB de VRAM) e 16 GB de RAM.
Medido com CUDA em 03/08/2026:

| perfil | modelo | pesos | geração | prefill | suíte de coding |
|---|---|---|---|---|---|
| `moe` | Qwen3.6 35B-A3B (MoE, 3 B ativos) | 16,8 GB | **37,7 tok/s** | ~300 tok/s | **6/6** |
| `agent` | Qwen3 8B | 5,0 GB | 73,6 tok/s | ~400 tok/s | 5/6 |
| `qwen27b` | Qwen3.6 27B (denso) | 15,2 GB | 3,1 tok/s | — | inviável |

**O `moe` é a resposta.** 35 B de parâmetros numa placa de 8 GB, 37 tok/s, e passa nos
cinco eixos da suíte. Dá para usar em loop de agente.

O `qwen27b` denso é o contraste que ensina: arquivo do mesmo tamanho que o MoE, **doze
vezes mais lento**. 15,2 GB de pesos densos não cabem em 8 GB de VRAM, então ~9 GB
ficam na RAM e são computados pela CPU a cada token. A GPU fica a 17% de uso. Não é
ajuste de flag, é limite físico.

O `agent` 8B tem o dobro da velocidade e falhou justamente onde importa: pediram para
adicionar um método e ele **apagou o método existente** no patch. Sintaticamente
perfeito, aplica limpo, quebra o código. É esse tipo de falha que decide se um modelo
serve como agente, e velocidade não prediz nada sobre ela.

A investigação inteira está em
[`docs/diagnostico-linux-benchmark.md`](docs/diagnostico-linux-benchmark.md). O que
falta, em [`TODO.md`](TODO.md).

## Como usar

### Subir um modelo

```bash
# no Linux, direto
./linux/llm-server.sh setup            # compila llama.cpp com CUDA (10-25 min, uma vez)
./linux/llm-server.sh start moe --lan  # --lan expõe na rede local
./linux/llm-server.sh status
./linux/llm-server.sh ask "Explique a diferença entre Q4_K_M e IQ4_NL"
./linux/llm-server.sh stop

# do Mac, via SSH
ssh lellis@192.168.3.51 "~/local-llm-lab/linux/llm-server.sh start moe --lan"
ssh lellis@192.168.3.51 "~/local-llm-lab/linux/llm-server.sh status"
```

Contexto e ajuste fino sem editar o script:

```bash
LLM_CTX=32768 ./linux/llm-server.sh start moe --lan     # ou: --ctx 32768
LLM_NGL=99 LLM_CPU_MOE=30 ./linux/llm-server.sh restart moe --lan
```

### Rodar o benchmark

```bash
python3 scripts/run_benchmark.py                    # todos os perfis
python3 scripts/run_benchmark.py moe                # só um
python3 scripts/run_benchmark.py moe --skip-pull    # pesos já baixados
python3 scripts/run_benchmark.py moe --skip-perf    # só a suíte de qualidade
python3 scripts/run_benchmark.py moe --repeats 3    # 3 tentativas por tarefa (pass@k)
python3 scripts/run_benchmark.py --perf-rounds 10
```

Saída em `benchmark-report/`: `BENCHMARK.md` para ler, `benchmark_summary.json` para
processar, e `responses/<perfil>/` com a resposta bruta de cada tarefa, para quando
você quiser auditar um FAIL.

Roda do Mac e controla o Linux por SSH. Sobrescreva o alvo se precisar:

```bash
LLM_REMOTE_HOST=user@ip LLM_SSH_KEY=~/.ssh/chave python3 scripts/run_benchmark.py moe
```

Os graders têm testes próprios. Vale rodar antes de confiar num resultado:

```bash
python3 scripts/test_bench_tasks.py
```

### Usar como assistente de código

A API é compatível com OpenAI, então qualquer cliente serve.

```bash
export OPENAI_BASE_URL=http://192.168.3.51:8080/v1
export OPENAI_API_KEY=local
```

Uma pegadinha que custou tempo: o provider nativo `llama.cpp` do `pi` exige o servidor
em *router mode* (sem `-m`/`-hf`). Nossos scripts rodam em single-model mode, então o
caminho é um provider custom. Está em [`docs/04-clientes.md`](docs/04-clientes.md).

## A suíte de benchmark

Cinco eixos, todos com veredito binário que a máquina verifica. Sem juiz, sem nota
subjetiva, sem score agregado.

| eixo | o que mede | como é verificado |
|---|---|---|
| `bugfix` | corrige bug em código existente | roda o teste que estava vermelho |
| `patch_format` | emite patch que aplica limpo | aplica o search/replace e executa |
| `tool_call` | emite tool call estruturada | valida o nome e parseia os argumentos |
| `long_context` | acha um fato em ~8 k tokens de código | comparação exata |
| `instruction` | respeita "responda APENAS o JSON" | parseia e confere o schema |

O `patch_format` é o mais decisivo e o menos óbvio. Modelo local costuma escrever
código bom e não conseguir emitir um patch aplicável — e isso trava um agente por
completo, sem aparecer em nenhum teste de "escreva uma função".

### A tarefa que de fato mede: `timeline_midnight`

As duas suítes acima estão no teto — o MoE acerta 18/18 na single-shot e 5/5 no
`test-feature.py`. Quando o baseline acerta tudo, não dá para saber se uma mudança melhorou.

`scripts/bench_agentic.py` roda tarefas multi-turno construídas a partir de **bugfixes reais** do
Beahub. O modelo recebe `list_files`, `read_file`, `write_file` e `run_tests`, e itera até o teste
ficar verde. O arquivo de teste é somente leitura, senão o caminho mais curto para o verde é
apagar os testes.

```bash
python3 scripts/bench_agentic.py --listar
LLM_HOST=192.168.3.51 python3 scripts/bench_agentic.py timeline_midnight
LLM_HOST=192.168.3.51 python3 scripts/bench_agentic.py timeline_midnight --temperature 0.6 --repeats 5
```

Resultado atual do `moe`:

```
REPROVADO — esgotou o teto de 14 turnos
testes: 3/5 → 4/5   (progresso parcial)
14 turnos · 11.115 tokens · 3 reescritas
```

Ele acerta a causa raiz (`"00:00"` é fim-do-dia, 1440 minutos, não zero) e perde a consequência:
um agendamento que começa no horário de fechamento fica fora da grade, então é preciso crescer a
janela — e nada na mensagem de erro aponta para isso. Depois da terceira reescrita entra em mínimo
local e gasta os turnos restantes relendo os mesmos arquivos.

O `3/5 → 4/5` é o ponto: crédito parcial permite comparar duas configurações que ambas reprovam.
Veredito binário jogaria essa informação fora.

### Por que geração de landing page saiu daqui

A suíte anterior media qualidade pedindo uma landing page e pontuando por presença de
substring (`"dark" in html`, `"transition" in html`). Não servia:

- Um HTML truncado no meio de uma tag, que não parseia, tirava 8,6/10.
- O teste de raciocínio passava de graça, porque o enunciado já continha o número
  esperado na resposta.
- Landing page mede geração longa de boilerplate Tailwind, que é o padrão mais
  memorizado de qualquer corpus de treino. Zero contexto de entrada, zero tool
  calling, zero edição de código existente. Quase o oposto de "corrigir bug".

E premia o defeito: quem cospe mais Tailwind decorado pontua mais alto.

Os artefatos em `examples/landing-page-*/` continuam no repo como amostra do que cada
modelo produz, mas não são benchmark. Dois deles estão cortados no meio de uma tag, e
o relatório antigo dizia "Issues: None detected" — porque o pipeline não registrava
`finish_reason` e não tinha como saber.

## Três coisas que mudaram todas as decisões

**0. Reasoning ligado piora tudo neste modelo, e fica com `off`.**
A/B medido, três braços: 18/18 sem reasoning, 8/18 com no orçamento normal, 9/12 com 4×
de orçamento. Custa 7 a 20× mais tokens, e no `patch_format` degenera em loop — 819 linhas
de raciocínio re-copiando o mesmo trecho (`def clear(self):` quarenta e duas vezes) para
adicionar um método de duas linhas que sem reasoning sai em 45 tokens.

Cuidado com a leitura, porém: o baseline acerta tudo, então o experimento só conseguia
mostrar empate ou piora. Ele não responde se reasoning ajudaria em tarefa difícil.
Reproduza com `--reasoning on|off --label X`.

**1. Tokens de reasoning gastam a cota e são invisíveis.**
Qwen3.6 emite o pensamento em `delta.reasoning_content`, não em `delta.content`.
Consome `max_tokens` igual. Medido: para o prompt "Diga apenas: ok" com
`max_tokens=40`, o modelo gastou **100% em raciocínio** e produziu zero conteúdo. Era
isso que truncava as landing pages — os perfis com `--reasoning off` geraram 27 KB, os
sem geraram 12 KB cortados. Um pipeline que só lê `content` não vê nada disso.

**2. MoE é a única arquitetura que viabiliza modelo grande em 8 GB.**
Não é "lento mas bom". O MoE de 35 B roda 12× mais rápido que o denso de 27 B com
arquivo do mesmo tamanho, porque só 3 B de parâmetros são ativados por token. Os pesos
continuam na RAM; o que muda é o volume de multiplicação.

**3. O modelo mais rápido não é o que entrega.**
Vale nas duas máquinas. No Linux, o 8B tem o dobro da velocidade do MoE e falha no
patch. No Windows, o `agent` gera 3× mais tokens por segundo, passa no teste de tool
calling, e não fecha uma feature de trinta linhas: inverte uma condição e reescreve em
volta do próprio bug seis vezes.

## O que tem aqui

```
linux/llm-server.sh        servidor llama.cpp + CUDA (a máquina principal)
macos/llm-server.command   servidor MLX + gestão de modelos
windows/llm-server.ps1     servidor llama.cpp + CUDA

scripts/
  run_benchmark.py         o pipeline de benchmark (é o que você quer rodar)
  bench_lib.py             instrumentação: timings reais, finish_reason, reasoning
  bench_tasks.py           as tarefas e os graders
  bench_server.py          controle do servidor remoto via SSH
  test_bench_tasks.py      testes dos graders
  test-tools.py            valida tool calling isoladamente
  test-feature.py          valida entrega de feature, critério é o pytest
  hooks/prepare-commit-msg gera subject de commit com o LLM local

benchmark-report/          saída da última execução
examples/landing-page*/    amostras de saída (não são benchmark)
```

O `scripts/run_moe_benchmark_pipeline.py` é o pipeline antigo. Continua no repo por
referência, mas não use: os números dele estão errados pelos motivos acima.

### Documentação

| documento | sobre |
|---|---|
| [Diagnóstico Linux](docs/diagnostico-linux-benchmark.md) | a investigação completa, incluindo as hipóteses que caíram |
| [1. Conceitos](docs/01-conceitos.md) | quantização, cache KV, memória unificada vs VRAM |
| [2. Escolher o modelo](docs/02-escolher-modelo.md) | a ordem das perguntas, com a matemática |
| [3. Tool calling](docs/03-tool-calling.md) | metodologia e os dois modos de falha |
| [4. Clientes](docs/04-clientes.md) | pi, Continue, Cline e as armadilhas |
| [5. Manutenção](docs/05-manutencao.md) | baixar, remover, tunar, liberar espaço |
| [6. Troubleshooting](docs/06-troubleshooting.md) | sintoma → diagnóstico errado → causa real |
| [7. Programando com o pi](docs/07-programando-com-pi.md) | o fluxo de trabalho real |

Boa parte desses documentos é anterior à investigação de agosto e ainda cita números do
MLX no Mac. Onde houver conflito, valem o
[diagnóstico](docs/diagnostico-linux-benchmark.md) e o `benchmark-report/`.

## Instalação

### Linux (NVIDIA)

```bash
sudo apt install -y cmake build-essential nvidia-cuda-toolkit
./linux/llm-server.sh setup
./linux/llm-server.sh start moe --lan
```

O `setup` **compila** o llama.cpp com `-DGGML_CUDA=ON`. Não tem como baixar binário
pronto: o release do llama.cpp só publica build CUDA para Windows. Para Linux existem
Vulkan, ROCm, SYCL e CPU puro, nenhum com CUDA.

Isso importa mais do que parece. A versão anterior deste script baixava o build Vulkan
e se descrevia como CUDA. Resultado medido: 2,7 tok/s com a GPU a 18% de uso.

Duas coisas que travariam a compilação e o `setup` resolve sozinho:

- O `nvcc` recusa host compiler mais novo do que ele suporta. No Pop!_OS 24.04 o nvcc é
  12.0 e o gcc padrão é 13.3, o que dá `unsupported GNU version`. O script lê o teto no
  `host_config.h` e escolhe o gcc compatível mais novo que estiver instalado.
- Se o build sair sem os headers do OpenSSL, o downloader interno do llama.cpp perde o
  TLS e falha com `failed to resolve commit` — mensagem que não menciona TLS e manda o
  diagnóstico para o lado errado. O script resolve o `.gguf` pela API do Hugging Face
  com `curl` e passa `-m` local, então o problema não aparece.

### macOS (Apple Silicon)

```bash
uv tool install --python 3.12 mlx-lm
uv tool install --python 3.12 mlx-vlm          # só para multimodal
uv tool install --python 3.12 huggingface_hub

./macos/llm-server.command start agent
./macos/llm-server.command models
```

`uv tool` e não `pip` porque cada pacote ganha um Python isolado, sem colidir com o do
sistema nem cair no `externally-managed-environment`. O `--python 3.12` evita falta de
wheels em versões muito novas.

### Windows (NVIDIA)

```powershell
.\windows\llm-server.ps1 setup
.\windows\llm-clients-setup.ps1
.\windows\llm-server.ps1 start moe
```

Aqui o binário CUDA pronto existe e o `setup` pega do release do GitHub. Não use
`winget install llama.cpp`: aquele pacote entrega build CPU/Vulkan e sua GPU fica
parada.

## Afinando um perfil MoE

O botão é o `--n-cpu-moe`, não o `-ngl`. Baixá-lo devolve tensores de expert da RAM
para a VRAM. Varredura medida no perfil `moe`:

| `-ngl` | `--n-cpu-moe` | geração | VRAM | |
|---|---|---|---|---|
| 36 | 36 | 25,4 tok/s | 4,5 GB | configuração herdada do Windows |
| 99 | 36 | 32,0 tok/s | 4,9 GB | só subir o `ngl` já dá +26% |
| 99 | 32 | 36,1 tok/s | 6,4 GB | |
| 99 | 30 | **37,7 tok/s** | 7,1 GB | **o que está no perfil** |
| 99 | 29 | 38,2 tok/s | 7,5 GB | fio de navalha |
| 99 | 28 | `abort` | — | estourou a VRAM |

O método: desce de 4 em 4 até dar abort, sobe 2, para. Deixe ~1 GB de folga, porque o
desktop e o navegador já usam ~600 MB de VRAM e um pico deles mata o servidor. Foi por
isso que 30 ganhou de 29, que é 1,3% mais rápido e come 400 MB a mais.

Um detalhe do llama.cpp que não é óbvio: `--n-cpu-moe` desliga o auto-fit
(`tensor_buft_overrides already set by user, abort`). Perfil que usa `--n-cpu-moe` é
obrigado a passar `-ngl` explícito; `auto` só funciona sem ele.

## Escolhendo o perfil

Na ordem:

1. **Cabe na VRAM?** Se não couber e o modelo for denso, para aqui — o resto não
   importa. A exceção é MoE, que ativa uma fração dos pesos por token e tolera ficar
   parcialmente na RAM.
2. **Faz tool calling?** Comprovado, não prometido: `python3 scripts/test-tools.py`.
3. **Só então** qualidade.

```bash
./linux/llm-server.sh models          # perfis, tamanho, tools
./macos/llm-server.command models     # no Mac, com tamanho real em disco
```

## O que não foi testado

- Os perfis `deepseek` e `frontier` nunca passaram pela varredura de `cpu_moe` no
  Linux. Os números vieram do Windows.
- Os campos `vram_gb` e `ram_gb` dos perfis foram herdados e não revalidados sob CUDA.
  Só o `moe` está medido.
- Os scripts PowerShell nunca foram executados. Foram escritos com as flags lidas do
  `--help` do binário real e o JSON/YAML validado pelos parsers, mas rodar em Windows
  está pendente.
- O `bonsai` falhou na bateria antiga e não deixou artefato nem log. Não foi
  investigado.
- Existe ~2,9 GB de swap ocupado de forma persistente durante o MoE, sem thrashing. Não
  sei se é resíduo ou custo real de 12,5 GB de experts em 16 GB de RAM.
- **As duas suítes fáceis estão no teto** (18/18 e 5/5) e não medem mais nada. Quem mede é a
  `timeline_midnight` (ver abaixo). Os perfis `deepseek` e `frontier` ainda não passaram por
  ela.

Em outro hardware os números mudam. O método não: medir antes de afirmar, e registrar
quando a medição derruba a hipótese.

## Licença

MIT — veja [LICENSE](LICENSE).
