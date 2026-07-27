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

---

## Modelos num disco externo

Se o SSD interno está apertado, dá para manter os modelos grandes num disco externo. Dois comandos:

```bash
./macos/llm-server.command archive quality   # move os pesos para o externo
./macos/llm-server.command restore quality   # traz de volta
```

O script detecta o primeiro `/Volumes/*/llm-models` que existir (ou use `LLM_EXT` para fixar). O `models` passa a mostrar a localização:

```
agent     4.3 GB   lm   sim   EM USO      (interno)
quality   8.4 GB   vlm  ?     EXTERNO
Disco
  modelos no interno: 18.8 GB · livre no interno: 40 GB
  disco externo: /Volumes/240GB/llm-models (livre 212 GB)
```

### HF_HOME, não caminho de arquivo

Este é o detalhe que faz a diferença entre funcionar e não funcionar.

Para usar um modelo que vive no externo, aponte **`HF_HOME`** para o cache de lá e passe o **repo id** normalmente:

```bash
HF_HOME=/Volumes/SEU_DISCO/llm-models/hf \
  mlx_lm.server --model mlx-community/Qwen3-8B-4bit
```

**Não** passe o caminho do snapshot em `--model`. Os **servidores** (`mlx_lm.server` e `mlx_vlm.server`) re-registram o modelo no cache padrão quando recebem um path, **copiando os pesos de volta para o disco interno** — e todo o ganho evapora. Medido: 2,8 GB reapareceram no interno após um único `start`.

Curiosamente, `mlx_lm.generate` e `mlx_vlm.generate` **não** fazem isso. É específico dos servers, o que torna a armadilha fácil de não perceber em teste rápido.

Medido com o mesmo modelo de 2,8 GB no externo:

| abordagem | tempo de subida | duplicou? |
|---|---|---|
| `--model <path do snapshot>` | 68 s | **sim, 2,8 GB** |
| `HF_HOME=<externo>` + repo id | **2 s** | não |

### A velocidade do barramento decide o resto

O mesmo disco, medido em duas topologias:

| | atrás de hub USB 2.0 | ligado direto (USB 3.2 Gen 2) |
|---|---|---|
| escrita (`dd` 1 GB) | 39 MB/s | **207 MB/s** |
| leitura (`dd` 1 GB) | 40 MB/s | **849 MB/s** |
| arquivar 2,8 GB | ~100 s | **23,5 s** |
| subir modelo de 2,8 GB | — | **2 s** |

**21× na leitura só mudando onde o cabo está ligado.** O disco é o mesmo.

Meça o seu:

```bash
./macos/llm-server.command extbench
```

Ele estima o tempo de carga e dá o veredito. Para leitura confiável, rode `sudo -v` antes — sem limpar o cache de página, o `dd` mede a RAM e devolve números impossíveis (20+ GB/s). O comando detecta isso e avisa.

**Se a velocidade decepcionar, suspeite da topologia antes do disco:**

```bash
ioreg -p IOUSB -w0 -l | rg -o '"(USB Product Name|Device Speed)" = .*'
```

`Device Speed`: `2` = USB 2.0 (480 Mb/s), `3` = USB 3.0 (5 Gb/s), `4` = USB 3.2 Gen 2 (10 Gb/s).

Um hub USB 3.0 se apresenta como **dois** controladores — um lado 2.0 e um lado SuperSpeed — porque USB 3 usa pares de fios separados. Se o seu SSD aparecer sob o lado 2.0, os pares SuperSpeed não foram conectados: cabo sem os fios, porta 2.0 do hub, ou case antigo. **Ligar direto na máquina elimina duas dessas três variáveis de uma vez.**

### Seguro para desconectar

O projeto assume que o disco vai e volta. **Só pesos de modelo vão para o externo** — nada que o sistema precise para funcionar. Desconectar não quebra nada; no pior caso um perfil fica indisponível:

```
! O disco externo (/Volumes/240GB/llm-models) não está montado.
Disponíveis no disco interno: agent fast balanced tiny
Ou rebaixe para o interno: llm-server.command pull quality
```

O caminho do disco é persistido em `~/.local/state/llm-server/ext-root`. Sem isso o script não conseguiria distinguir "esse modelo nunca foi baixado" de "está no disco que você desconectou" — e rebaixaria vários GB por engano. Foi exatamente o bug que apareceu no primeiro teste de desconexão.

### O que NÃO colocar no externo

- **`~/.cache/huggingface` inteiro via symlink** — desconectar quebra qualquer download ou leitura.
- **`node_modules`** — builds ficam lentíssimos e quebram ao desconectar.
- **Caches de ferramentas** (`uv`, `npm`, Homebrew) — usados constantemente.
- **Qualquer coisa em `~/Library`** — o sistema espera que esteja sempre lá.

A regra: se algo é lido durante trabalho normal, fica no interno.

---

### Swap come disco

Num Mac com pouca RAM, o `vm.swapusage` cresce e os swapfiles são arquivos reais de 1 GB cada. Observamos o swap ir de 9 GB para 16 GB sob carga de LLM, com o disco livre caindo de 13 GB para 7 GB **sem nenhum download novo**.

Antes de investigar "o disco encheu do nada":

```bash
sysctl vm.swapusage
```

---

Próximo: [troubleshooting — erros reais e o que significavam](06-troubleshooting.md).
