# Troubleshooting: erros reais e o que cada um significava

Todos os casos abaixo aconteceram de verdade durante a construção deste repositório. Estão aqui com o sintoma, o diagnóstico errado que fizemos primeiro, e a causa real.

O padrão que se repete: **quase todo "travamento" tinha outra explicação.**

---

## O servidor não responde

### Requisições penduram para sempre, servidor aceita conexões

**Diagnóstico errado:** memória insuficiente, swap.

**Causa real:** arquitetura não suportada pelo engine.

```
ValueError: Model type gemma4_unified not supported.
```

O `mlx_lm.server` registrou isso no log, **e continuou rodando**. O processo aceitava conexões, respondia ao `/v1/models`, e as requisições de geração ficavam penduradas indefinidamente. CPU em 0,0% e 0,03 GB de memória eram a pista: nada havia sido carregado.

**Correção:** modelos multimodais (`gemma3n`, `gemma4_unified`, `qwen2_vl`) exigem `mlx_vlm.server`. Só texto puro (`qwen2`, `qwen3`, `llama`) roda no `mlx_lm.server`.

**Como evitar:** verifique o `model_type` antes:

```bash
curl -s "https://huggingface.co/api/models/<org>/<repo>" | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['config'].get('model_type'))"
```

Ou use `llm-server.command add <repo>`, que faz isso e escolhe o engine.

---

### `422 Unprocessable Entity` repetido

**Sintoma:** o cliente parece travado; o log mostra `422` a cada tentativa.

**Causa:** falta o campo `model` no corpo da requisição. O `mlx_vlm.server` é multi-modelo e valida com Pydantic — sem `model`, rejeita **sempre**.

```json
{ "model": "mlx-community/Qwen3-8B-4bit", "messages": [...], "max_tokens": 100 }
```

O `mlx_lm.server` aceita o campo igual, então inclua sempre.

---

### `/v1/models` responde, geração não

**Causa:** *lazy loading*. Os dois servidores MLX respondem ao `/v1/models` **antes** de carregar os pesos.

Um health check que só consulta `/v1/models` reporta "no ar em 3 s" com zero carregado. O health check válido faz uma geração real:

```bash
curl -fsS http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"<repo>","messages":[{"role":"user","content":"ok"}],"max_tokens":1}'
```

---

### `BrokenPipeError` no log do servidor

**Diagnóstico errado:** timeout do cliente, problema de rede.

**Causa real:** era só **lentidão**. O cliente desistiu porque *nós* interrompemos, não porque estourou timeout.

Interrompemos a mesma execução três vezes achando que estava travada. Os processos abandonados **terminaram com sucesso** depois de mais de 10 minutos, com respostas corretas.

**Lição:** antes de diagnosticar travamento, meça quanto tempo a operação *deveria* levar. Um agente com system prompt grande em hardware modesto leva minutos por turno — e isso é normal, não defeito.

---

## Está lento

### Geração muito abaixo do esperado

Meça primeiro, adivinhe depois:

```bash
./macos/llm-server.command status    # RAM livre e swap
sysctl vm.swapusage                  # macOS
nvidia-smi                           # NVIDIA: VRAM em uso
```

**Se o swap está alto ou a VRAM estourou**, o modelo não cabe. Não há tuning que resolva — use um perfil menor. Medimos 0,7 tok/s num modelo que deveria fazer ~15, só por não caber.

**Cuidado com uma medição enganosa no macOS:** o `RSS` do processo **não** mede os pesos. O MLX aloca em buffers Metal, fora do *resident set size*. Um modelo de 9 GB carregado aparece como 0,02 GB no `ps`. Meça por RAM livre e swap.

**No llama.cpp**, quando os pesos não cabem na VRAM ele **não falha** — move camadas para a CPU silenciosamente. Confira quantas camadas foram para a GPU no log de inicialização.

### Primeiro token demora muito, resto é rápido

Isso é **prefill**, não geração — e é normal.

Medido: 3.517 tokens de prompt = 20 s antes do primeiro token, com geração a 19 tok/s depois. São gargalos independentes.

**Se acontece a cada turno de um agente**, verifique se o prompt cache está ativo. Com ele, prefixo repetido cai de 20 s para 0,78 s (25×):

```
--prompt-cache-size 2 --prompt-cache-bytes 1500000000    # mlx_lm.server
```

### Fica lento com o tempo (Mac sem ventoinha)

MacBook Air não tem ventoinha. Carga sustentada de GPU esquenta e o clock cai. Não há correção — só expectativa realista: os primeiros minutos são mais rápidos que o resto.

---

## Tool calling

### `tool_calls: null` mas o modelo "tentou"

Olhe o `content`. Se tiver algo assim:

```
<tools>{"name": "bash", "arguments": {"cmd": "ls"}}</tools>
```

O modelo emitiu a tag **errada** — `<tools>` declara ferramentas, `<tool_call>` faz a chamada. O parser do servidor não reconhece.

Aconteceu com `Qwen2.5-Coder-7B` e `14B`, nos **dois** engines MLX (confirmando que a culpa é do modelo, não do servidor). O fine-tune para código degradou o tool calling.

**Correção:** use um modelo não especializado em código. `Qwen3-8B` e `Qwen3-4B` passaram.

### Resposta vazia quando envia `tools`

**Sintoma:** `content: ''`, `tool_calls: null`. Sem `tools`, responde normal.

**Causa:** o repositório usa `chat_template.jinja` separado (formato novo do `transformers`), e o `mlx_lm` lê o template de dentro do `tokenizer_config.json` — que nesse caso está vazio. Sem template de ferramentas, o modelo não sabe o que emitir.

**Verifique:**

```bash
curl -s "https://huggingface.co/api/models/<org>/<repo>" | \
  python3 -c "import sys,json; print([f['rfilename'] for f in json.load(sys.stdin)['siblings']])"
```

Se houver `chat_template.jinja`, tente a variante **GGUF** do mesmo modelo: o llama.cpp com `--jinja` usa o template embutido no arquivo e contorna o problema. Foi o caso do Qwen3-4B — falhou em MLX, passou em GGUF.

---

## Instalação

### `externally-managed-environment` no pip

O Python do Homebrew não aceita `pip install` global. Use ambientes isolados:

```bash
uv tool install --python 3.12 mlx-lm
```

O `--python 3.12` também evita falta de wheels em versões muito novas (o Python do brew pode estar em 3.14).

### `winget install llama.cpp` não usa a GPU

Aquele pacote entrega build **CPU/Vulkan, sem CUDA**. Baixe o release do GitHub:

```
llama-<tag>-bin-win-cuda-12.4-x64.zip
cudart-llama-bin-win-cuda-12.4-x64.zip
```

CUDA 12.4 cobre drivers mais antigos; 13.3 exige driver recente. O `llm-server.ps1 setup` faz isso.

### O modelo baixa de novo mesmo já estando em disco

O llama.cpp guarda os GGUF baixados via `-hf` no **cache do Hugging Face** (`~/.cache/huggingface/hub`), não em diretório próprio. Script que procura no lugar errado rebaixa vários GB achando que não existe.

---

## Disco

### "O disco encheu do nada"

Verifique o swap antes de procurar arquivos:

```bash
sysctl vm.swapusage
```

Os swapfiles são arquivos reais de 1 GB cada. Observamos o swap ir de 9 GB para 16 GB sob carga de LLM, com o disco caindo de 13 GB para 7 GB sem nenhum download.

### A varredura de limpeza não acha nada

Se você escreveu com `fd` ou `rg`: eles **respeitam o `.gitignore` por padrão**. E os maiores alvos (`node_modules`, `.dart_tool`, `build`, `Pods`) estão exatamente lá.

```bash
fd -t d -H -I '^node_modules$' ~/code     # -I = --no-ignore
```

Uma versão anterior do `clean.sh` relatava quase nada por isso. Havia 13 GB.

---

## Armadilhas de shell (se você for editar os scripts)

Duas que morderam mais de uma vez:

**`printf '%-8s'` conta bytes, não caracteres.** Um travessão `—` ocupa 3 bytes em UTF-8 e desalinha a coluna inteira. Use ASCII em tabelas alinhadas.

**`printf '%s\n' "$*"` não interpreta `\n`.** Se você tem um helper `say()` assim, passar `say "\ntexto"` imprime a barra literal. Use `printf` de verdade quando precisar de linha em branco.

**`$args` é reservada no PowerShell.** Atribuir a ela dentro de uma função gera comportamento confuso. Use outro nome.

**Array vazio + `set -u` quebra no bash 3.2 — que é o bash do macOS.** A Apple não atualiza o bash desde a mudança para GPLv3, então `/bin/bash` ainda é 3.2.57. Ali, expandir um array **vazio** sob `set -u` aborta:

```bash
$ /bin/bash -c 'set -u; a=(); printf "%s\n" "${a[@]}"'
/bin/bash: a[@]: unbound variable
```

A forma segura, que funciona nas duas versões:

```bash
"${a[@]+"${a[@]}"}"
```

Este bug esteve no `llm-server.command`: os perfis com flags extras (`agent`, `quality`) subiam, e os com o campo vazio (`fast`, `balanced`, `tiny`) morriam com `unbound variable`. Passou pelos testes porque só o caminho *com* dados foi exercitado depois da mudança.

**A lição maior:** ao adicionar um campo opcional, teste o caso vazio. Ele é o padrão para a maioria das entradas.

**`read` sem TTY recebe EOF na hora.** Um script com confirmação interativa cancela sozinho quando rodado por pipe ou por um agente. Detecte com `[[ ! -t 0 ]]` e ofereça uma flag `--yes`.

**`.ps1` precisa de BOM; `.yaml` e `.json` não podem ter.** A regra é oposta para cada um, e trocá-las quebra os dois.

O Windows PowerShell 5.1 — o `powershell.exe` que já vem no Windows — lê arquivo `.ps1` **sem** BOM como ANSI (Windows-1252). Todo caractere UTF-8 multibyte do script (`á`, `é`, `—`, `─`) chega ao parser como dois caracteres de lixo. Em comentário, o resultado é feio; dentro de uma string exibida, a saída fica ilegível. O PowerShell 7+ (`pwsh.exe`) assume UTF-8 sem BOM e não sofre disso — o que torna o bug invisível para quem só testa no 7.

Por isso os `.ps1` deste repositório são gravados **com** BOM, e o `llm-server.ps1` fixa o encoding de saída no topo:

```powershell
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
```

São dois problemas distintos, e resolver um não resolve o outro: o BOM conserta a **leitura** do arquivo; o `OutputEncoding` conserta a **escrita** no console. Um console em cp850 imprime lixo mesmo lendo o script perfeitamente.

Já os arquivos de configuração que o `llm-clients-setup.ps1` gera (`config.yaml` do Continue, `models.json` do `pi`) precisam do contrário — o parser YAML engasga com BOM. O script escreve assim, de propósito:

```powershell
[IO.File]::WriteAllText($path, $content, (New-Object Text.UTF8Encoding $false))
```

Evite `Set-Content -Encoding UTF8` para esses: no PowerShell 5.1 esse comando **adiciona** BOM. No 7+ não. Mesmo comando, resultado diferente por versão — é a razão de o script usar `WriteAllText` diretamente.

Se você editar um `.ps1` e os acentos começarem a sair errados, o primeiro suspeito é o editor ter salvado sem BOM. Confirme com:

```powershell
Format-Hex .\windows\llm-server.ps1 -Count 3   # deve começar com EF BB BF
```

---

## Quando nada acima explica

1. **Leia o log.** `./macos/llm-server.command logs`. Metade dos casos aqui foi resolvida assim, depois de tempo perdido adivinhando.
2. **Confirme que o processo está fazendo algo.** `ps -o %cpu,rss -p <pid>` — CPU em 0% com pouca memória significa que não carregou.
3. **Teste a camada de baixo.** Se o cliente falha, teste com `curl`. Se o `curl` falha, teste com `mlx_lm.generate` direto. Isole antes de concluir.
