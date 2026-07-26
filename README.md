# local-llm-lab

Rodar LLM local em **Apple Silicon** e **NVIDIA**, com scripts que funcionam e — mais importante — com os **números medidos** em cada máquina.

Não é uma coleção de comandos copiados de tutorial. Cada tok/s aqui saiu de um teste executado, cada armadilha documentada custou uma sessão de depuração, e o que **não** funcionou está registrado com o mesmo cuidado do que funcionou.

```bash
# macOS (Apple Silicon)
./macos/llm-server.command start agent
./macos/llm-server.command ask "Escreva um debounce genérico em TypeScript"

# Windows (NVIDIA)
.\windows\llm-server.ps1 setup
.\windows\llm-server.ps1 start tiny
```

---

## Por que este repositório existe

Rodar um modelo local é fácil. Rodar o modelo **certo**, no runtime **certo**, com o cliente **certo**, sabendo **por que** está lento — isso é outra coisa.

Três descobertas que mudaram todas as decisões deste repositório:

**1. O modelo melhor em código pode ser inútil como agente.**
O `Qwen2.5-Coder-7B` escreve código melhor que o `Qwen3-8B`. Mas ele **não consegue chamar ferramentas**: emite `<tools>` (a tag de *declaração*) onde deveria emitir `<tool_call>` (a tag de *chamada*). O fine-tune para código degradou o tool calling. Resultado: serve para chat no editor, não serve para agente.

**2. A degradação por falta de memória não é uma rampa, é um precipício.**
Mesma máquina, mesmo runtime, dois modelos:

| modelo | pesos | tok/s |
|---|---|---|
| Qwen2.5-Coder-7B (4-bit) | 4,3 GB | **19,7** |
| Gemma 4 12B (4-bit QAT) | 9,0 GB | **0,7** |

**28× mais lento.** Não porque o modelo é ruim — porque não cabe. Quando os pesos excedem a memória livre, cada token passa a esperar disco.

**3. Metade dos "travamentos" era diagnóstico errado.**
Servidor que não responde nem sempre está travado. Neste repositório documentamos casos que *pareciam* timeout e eram: arquitetura não suportada, campo obrigatório ausente no payload, lazy loading, e simples lentidão. Cada um exigiu ler log em vez de adivinhar.

---

## O que tem aqui

### Scripts

```
macos/
  llm-server.command      servidor MLX (API OpenAI) + gestão de modelos
  clean.sh                libera espaço em disco, dry-run por padrão
  limpar-ios-sdk.command  remove runtime do simulador iOS órfão
windows/
  llm-server.ps1          servidor llama.cpp + CUDA
  llm-clients-setup.ps1   configura pi e Continue
scripts/
  test-tools.py           valida se um modelo faz tool calling de verdade
  check-links.py          confere links e âncoras desta documentação
```

### Documentação

| documento | sobre |
|---|---|
| [1. Conceitos](docs/01-conceitos.md) | quantização, cache KV, memória unificada vs VRAM, prefill vs geração |
| [2. Escolher o modelo](docs/02-escolher-modelo.md) | a ordem correta das perguntas, com a matemática |
| [3. Tool calling](docs/03-tool-calling.md) | metodologia, resultados e os dois modos de falha |
| [4. Clientes](docs/04-clientes.md) | pi, Continue, Cline — e as armadilhas de cada um |
| [5. Manutenção](docs/05-manutencao.md) | baixar, remover, tunar, liberar espaço |
| [6. Troubleshooting](docs/06-troubleshooting.md) | sintoma → diagnóstico errado → causa real |
| [Benchmarks](docs/benchmarks.md) | todos os números e como foram obtidos |

Se você só quer que funcione, leia [Escolher o modelo](docs/02-escolher-modelo.md). Se algo já quebrou, vá direto ao [Troubleshooting](docs/06-troubleshooting.md).

---

## Números medidos

**Hardware A** — MacBook Air M4, 16 GB de memória unificada, sem ventoinha. Runtime: MLX.

| perfil | modelo | pesos | tok/s | tool calling |
|---|---|---|---|---|
| `agent` | Qwen3-8B-4bit | 4,6 GB | 16–19 | ✅ |
| `fast` | Qwen2.5-Coder-7B-4bit | 4,3 GB | 19,7 | ❌ |
| `balanced` | Qwen2.5-Coder-14B-4bit | 8,3 GB | não medido | ❌ |
| `quality` | Gemma-4-12B-it-qat-OptiQ | 9,0 GB | 0,7 | não medido |

Também medido nessa máquina: **prefill a ~176 tok/s** (3.517 tokens de prompt = 20 s antes do primeiro token) e **prompt cache com ganho de 25×** (o mesmo prompt repetido cai de 20 s para 0,78 s).

**Hardware B** — mesma máquina, runtime llama.cpp/Metal, para comparar formatos:

| modelo | pesos | tok/s | tool calling |
|---|---|---|---|
| Qwen3-4B-GGUF Q4_K_M | 2,50 GB | **33,1** | ✅ |
| Qwen3-8B-GGUF Q4_K_M | 5,03 GB | 18,8 | ✅ |

O 4B roda ao **dobro** da velocidade do 8B e faz tool calling igualmente bem. Em hardware limitado, esse é o trade-off que importa — e é o oposto do reflexo "maior é melhor".

Metodologia completa em [`docs/benchmarks.md`](docs/benchmarks.md).

---

## Instalação

### macOS (Apple Silicon)

```bash
uv tool install --python 3.12 mlx-lm
uv tool install --python 3.12 mlx-vlm          # só para modelos multimodais
uv tool install --python 3.12 huggingface_hub

./macos/llm-server.command start agent
```

Por que `uv tool` e não `pip`: cada pacote ganha um Python isolado, sem colidir com o Python do sistema nem cair no `externally-managed-environment`. E o `--python 3.12` evita a falta de wheels em versões muito novas.

### Windows (NVIDIA)

```powershell
.\windows\llm-server.ps1 setup     # baixa llama.cpp com CUDA
.\windows\llm-clients-setup.ps1    # configura pi + Continue
.\windows\llm-server.ps1 start tiny
```

O `setup` **não** usa `winget install llama.cpp`: aquele pacote entrega build CPU/Vulkan, sem CUDA — sua GPU ficaria parada. O script baixa o release oficial do GitHub com o binário CUDA correto.

---

## Escolhendo o perfil

Regra prática, nesta ordem:

1. **Cabe na memória?** Se os pesos não couberem, nada mais importa — veja o precipício acima.
2. **Precisa chamar ferramentas?** Se sim, precisa de tool calling comprovado, não prometido.
3. **Só então** pense em qualidade.

```bash
./macos/llm-server.command models     # o que existe, o que ocupa, o que está em uso
.\windows\llm-server.ps1 vram         # orçamento de VRAM por perfil
```

A coluna `TOOLS` diz o que decide o uso: `sim` serve como agente (pi, Cline), `nao` serve para chat e edição.

---

## Gerenciando modelos

```bash
./macos/llm-server.command models            # lista tudo, com tamanho real em disco
./macos/llm-server.command add <org/repo>    # baixa qualquer modelo MLX do Hugging Face
./macos/llm-server.command rm <perfil|repo>  # remove
./macos/llm-server.command gc                # tira downloads incompletos
```

O `add` consulta a API do Hugging Face **antes** de baixar: mostra tamanho, `model_type` e formato, detecta qual engine roda aquele modelo, e recusa repos GGUF apontando para o llama.cpp. Evita puxar 20 GB para descobrir que não serve.

O `rm` se recusa a remover o modelo que o servidor tem carregado — o processo continuaria servindo arquivos inexistentes.

Detalhes em [`docs/05-manutencao.md`](docs/05-manutencao.md).

---

## Clientes

Ambos os servidores expõem API compatível com OpenAI, então qualquer cliente serve. Configurações prontas e testadas para:

- **[pi](https://github.com/mariozechner/pi)** — agente de código no terminal
- **Continue** (VSCode) — chat, edit, apply

```bash
export OPENAI_BASE_URL=http://127.0.0.1:8080/v1
export OPENAI_API_KEY=local
```

Uma armadilha que custou tempo: o provider nativo `llama.cpp` do `pi` exige o servidor em **router mode** (iniciado sem `-m`/`-hf`). Nossos scripts rodam em **single-model mode**, então o caminho correto é um provider custom. Explicado em [`docs/04-clientes.md`](docs/04-clientes.md).

---

## Honestidade sobre o que não foi testado

- Os scripts **PowerShell nunca foram executados**. Foram escritos com as flags lidas do `--help` do binário real, a matemática de VRAM calculada, e o JSON/YAML gerado validado pelos parsers — mas a execução em Windows está pendente. Bugs encontrados por revisão manual estão no histórico de commits.
- Os números de `tool calling` no Windows são inferidos: a combinação llama.cpp + Qwen3 foi validada com backend **Metal**, não CUDA. O que se prova é runtime + modelo + tool calling funcionando juntos; o backend é a parte madura.
- `balanced` e `quality` não têm tok/s medido na configuração final.

Se você rodar em outro hardware, os números vão mudar. O que não muda é o método: **medir antes de afirmar**.

---

## Licença

MIT — veja [LICENSE](LICENSE).
