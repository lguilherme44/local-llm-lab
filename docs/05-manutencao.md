# Manutenção: baixar, remover, tunar, liberar espaço

Modelos ocupam muito disco e é fácil perder a conta. Um cache com 25 GB em quatro modelos é normal — e invisível se você não olhar.

---

## Ver o que existe

```bash
./macos/llm-server.command models
```

```
PERFIL    EM DISCO ENGINE TOOLS  ESTADO      MODELO
agent     4.3 GB   lm     sim    EM USO      mlx-community/Qwen3-8B-4bit
fast      4.0 GB   lm     nao    baixado     mlx-community/Qwen2.5-Coder-7B-Instruct-4bit
quality   8.4 GB   vlm    ?      baixado     mlx-community/gemma-4-12B-it-qat-OptiQ-4bit
tiny      -        lm     ?      ausente     mlx-community/mini-coder-4b-OptiQ-4bit

Outros modelos no cache  (fora dos perfis)
  335 MB   mlx-community/Qwen3-0.6B-4bit

Disco
  modelos em cache: 24.5 GB · livre no disco: 39 GB
```

Três colunas que importam:

- **EM DISCO** — tamanho real medido, não o declarado
- **TOOLS** — `sim` serve como agente, `nao` só chat/edit
- **Outros modelos no cache** — baixados fora dos perfis. Sem essa seção, esse espaço fica invisível

---

## Baixar

**Um perfil conhecido:**

```bash
./macos/llm-server.command pull agent
```

**Qualquer modelo do Hugging Face:**

```bash
./macos/llm-server.command add mlx-community/Qwen3-14B-4bit
```

O `add` consulta a API **antes** de baixar:

```
Verificando mlx-community/Qwen3-14B-4bit
  tamanho: 8.31 GB · model_type: qwen3 · formato: mlx
  engine sugerido: mlx_lm
```

Ele detecta o engine testando o `model_type` contra os módulos disponíveis em `mlx_lm.models` e `mlx_vlm.models`, preferindo `lm` quando ambos servem (é mais leve). Isso evita o erro que nos custou uma sessão: rodar um modelo multimodal no `mlx_lm`, que falha com `ValueError: Model type ... not supported` no log **enquanto o servidor continua aceitando conexões** e as requisições penduram para sempre.

E recusa o formato errado em vez de baixar em vão:

```
$ ./macos/llm-server.command add Qwen/Qwen3-8B-GGUF
  tamanho: 29.84 GB · formato: gguf
! Este repo é GGUF — formato do llama.cpp, não do MLX.
Use com: llama-server -hf Qwen/Qwen3-8B-GGUF
```

Para tornar um modelo baixado num perfil fixo, adicione a linha que o script sugere em `profiles()`:

```
meu-perfil|mlx-community/Qwen3-14B-4bit|8.31|lm|?||Descrição sua.
```

Campos: `nome|repo|GB|engine|tools|flags-extras|descrição`.

---

## Remover

```bash
./macos/llm-server.command rm balanced                          # por perfil
./macos/llm-server.command rm mlx-community/Qwen3-0.6B-4bit     # por repositório
./macos/llm-server.command rm balanced --yes                    # sem confirmar
```

**Tudo passa pelo CLI oficial `hf cache`**, nunca por `rm -rf`. O cache do Hugging Face tem estrutura de blobs, snapshots e refs; apagar diretório na mão deixa referências quebradas que fazem o próximo download se comportar de forma estranha.

Duas guardas:

**Não remove o modelo em uso.** O processo continuaria servindo arquivos inexistentes:

```
! 'mlx-community/Qwen3-8B-4bit' está EM USO pelo servidor (PID 42766).
Derrube antes: llm-server.command stop
```

**Exige `org/repo` com barra** quando não é nome de perfil, para um erro de digitação não apagar a coisa errada.

---

## Faxina

```bash
./macos/llm-server.command gc
```

Faz duas coisas diferentes de propósito:

1. **Apaga** revisões soltas e downloads incompletos (`hf cache prune`). Um `.downloadInProgress` de 4 GB depois de um Ctrl-C é lixo puro, sem decisão a tomar.
2. **Apenas lista** os modelos fora dos perfis. Apagar modelo é sua escolha — o `gc` não decide isso por você.

---

## Tunar

### Memória de GPU no macOS

```bash
./macos/llm-server.command tune
```

Mostra o `iogpu.wired_limit_mb`, que limita quanta memória o MLX pode manter *wired* na GPU (padrão ~70% da RAM). Elevar deixa mais peso na GPU em vez de comprimir/swapar:

```bash
sudo sysctl iogpu.wired_limit_mb=13107     # 80% de 16 GB
```

É volátil — volta ao padrão ao reiniciar. **Cuidado:** valores altos deixam pouca RAM para o macOS e podem travar o sistema sob pressão. Reverter sem reiniciar: `sudo sysctl iogpu.wired_limit_mb=0`.

### Flags de memória, por engine

As opções úteis não são as mesmas nos dois engines MLX:

| objetivo | `mlx_lm.server` | `mlx_vlm.server` |
|---|---|---|
| quantizar cache KV | — | `--kv-bits 8` |
| limitar cache KV | — | `--max-kv-size 8192` |
| reutilizar prefixo | `--prompt-cache-bytes` | — |
| reduzir pico do prefill | `--prefill-step-size 1024` | `--prefill-step-size 1024` |

O `--prompt-cache-bytes` do `mlx_lm.server` é o que dá o ganho de 25× em prompt repetido. O `--kv-bits` do `mlx_vlm.server` é o que salva contexto longo. Nenhum dos dois tem os dois.

No llama.cpp você tem tudo: `-ctk q8_0 -ctv q8_0` (quantiza KV), `-c` (contexto), `-ngl` (camadas na GPU), `-fa on` (flash attention).

### Contexto: o ajuste mais eficaz

Reduzir o contexto libera memória rápido, porque o cache KV cresce linearmente com ele. Num modelo de 8B, ir de 32k para 8k economiza ~3,6 GB em `f16`. Se você não usa contexto longo, é dinheiro na mesa — veja a tabela em [conceitos](01-conceitos.md#2-cache-kv-o-custo-escondido-do-contexto).

---

## Liberando espaço em disco (macOS)

```bash
./macos/clean.sh                      # relatório, não apaga nada
./macos/clean.sh --apply              # caches seguros
./macos/clean.sh --apply --projects   # + builds, .dart_tool, node_modules
```

Dry-run por padrão. Um script de limpeza que apaga sem mostrar é uma bomba, não uma ferramenta.

O que ele considera **seguro** (regenera sozinho): caches de `uv`, `npm`, `pnpm`, Homebrew, Gradle, node-gyp, pip, CocoaPods; caches de aplicativo (Chrome, instaladores antigos do VSCode, browsers do Playwright); restos de Xcode (DerivedData, Archives).

O que ele **não** toca, de propósito:

- **`~/.pub-cache`** — não é lixo. É o cache de dependências do Dart, compartilhado entre projetos. Apagar não libera espaço permanente: só força re-download de tudo, sempre. Trocar disco por tempo de rede, repetidamente.
- **`~/Library/Application Support/*`** — são perfis (histórico, extensões), não caches.
- **Docker, SDK Android, versões do fvm** — decisões suas. Aparecem numa seção MANUAL com o comando pronto.

Configure onde estão seus repositórios:

```bash
PROJECTS_DIR="$HOME/dev" ./macos/clean.sh
# ou
./macos/clean.sh --projects-dir ~/dev
```

### O detalhe que faz o script funcionar

A varredura usa `fd -I` (`--no-ignore`). Sem essa flag, o `fd` respeita o `.gitignore` — e justamente os maiores alvos (`node_modules`, `.dart_tool`, `build`, `Pods`) estão listados lá. Uma versão anterior deste script relatava quase nada por causa disso, dando a impressão de que não havia o que limpar. Havia 13 GB.

Se você escrever qualquer varredura com `fd` ou `rg`, lembre disso.

### Swap come disco

Num Mac com pouca RAM, o `vm.swapusage` cresce e os swapfiles são arquivos reais de 1 GB cada. Observamos o swap ir de 9 GB para 16 GB sob carga de LLM, com o disco livre caindo de 13 GB para 7 GB **sem nenhum download novo**.

Antes de investigar "o disco encheu do nada":

```bash
sysctl vm.swapusage
```

---

Próximo: [troubleshooting — erros reais e o que significavam](06-troubleshooting.md).
