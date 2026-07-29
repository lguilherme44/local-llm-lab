# Configurando os clientes

Os dois servidores expõem API compatível com OpenAI, então em teoria qualquer cliente funciona. Na prática cada um tem uma peculiaridade que custa tempo.

```bash
export OPENAI_BASE_URL=http://127.0.0.1:8080/v1
export OPENAI_API_KEY=local        # o servidor ignora, mas os clientes exigem um valor
```

---

## pi (agente de terminal)

### Onde vai a configuração

**`~/.pi/agent/models.json`** — e não `models-store.json`, que é cache de catálogo e é sobrescrito quando o `pi` atualiza os providers. Errar isso significa ver a configuração desaparecer sozinha.

```json
{
  "providers": {
    "mlx-local": {
      "baseUrl": "http://127.0.0.1:8080/v1",
      "api": "openai-completions",
      "apiKey": "local",
      "compat": {
        "supportsDeveloperRole": false,
        "supportsReasoningEffort": false
      },
      "models": [
        {
          "id": "mlx-community/Qwen3-8B-4bit",
          "name": "Qwen3 8B (local)",
          "contextWindow": 32768,
          "maxTokens": 4096,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        }
      ]
    }
  }
}
```

```bash
pi --provider mlx-local --model mlx-community/Qwen3-8B-4bit --api-key local
```

No Windows, use `.\windows\llm-clients-setup.ps1`, que escreve o arquivo com backup do que já existia.

### Quatro detalhes que quebram

**`--api-key` não é opcional.** O `pi` esconde do `/model` qualquer modelo sem autenticação, mesmo sendo servidor local sem chave. Passe na linha de comando ou deixe um valor dummy no `apiKey` do JSON.

**`compat.supportsDeveloperRole: false`.** Servidores OpenAI-compatible simples não entendem o papel `developer` usado por modelos com reasoning. Sem essa flag o system prompt se perde.

**O `id` precisa casar com o que o servidor espera.** Em MLX é o repositório completo (`mlx-community/Qwen3-8B-4bit`). No llama.cpp com `-a <alias>`, é o alias. O `mlx_vlm.server` **valida** esse campo e devolve 422 se não bater.

**O provider nativo `llama.cpp` exige router mode.** Este é o erro mais fácil de cometer no Windows. A documentação do `pi` é explícita:

> *"Server is not in router mode: Start it without `--model`, `-m`, or `-hf`."*

O provider nativo espera o llama-server iniciado **sem** modelo, com `--models-dir`, expondo os endpoints `/llama` para listar e carregar. Nossos scripts usam `-hf`, que é **single-model mode** — ali esses endpoints não existem e o provider nativo não enxerga nada.

Por isso a configuração usa um provider custom falando direto com `/v1/chat/completions`, que funciona nos dois modos.

### Expectativa de desempenho

Medido num MacBook Air M4 de 16 GB: **~2 minutos por turno**. O `pi` injeta um system prompt grande e faz cerca de duas chamadas por turno; com prefill a ~176 tok/s, o custo aparece antes do primeiro token.

Não confunda isso com travamento. Nós confundimos: interrompemos a execução por três vezes achando que era timeout, e os processos abandonados terminaram com sucesso depois de 10 minutos. **Deixe rodar antes de diagnosticar.**

O prompt cache é o que torna isso viável do segundo turno em diante — prefixo repetido cai de 20 s para 0,78 s.

---

## Continue (VSCode)

### Onde vai

**`~/.continue/config.yaml`** (`%USERPROFILE%\.continue\config.yaml` no Windows).

```yaml
name: Local Config
version: 1.0.0
schema: v1

models:
  - name: Qwen3 8B (local) - agente
    provider: openai
    apiBase: http://127.0.0.1:8080/v1
    apiKey: local
    model: mlx-community/Qwen3-8B-4bit
    roles: [chat, edit, apply]
    defaultCompletionOptions:
      contextLength: 32768
      maxTokens: 4096
      temperature: 0
```

Recarregue a janela depois (`Cmd/Ctrl+Shift+P` → *Reload Window*) e os modelos aparecem no seletor (`Cmd/Ctrl+L`).

### Detalhes

**`provider: openai` vale para qualquer endpoint compatível.** Não manda nada para a OpenAI — quem decide o destino é o `apiBase`. O nome do campo confunde, mas é o valor correto.

**`contextLength` vai dentro de `defaultCompletionOptions`**, não na raiz. Na raiz, é ignorado silenciosamente e o modelo trunca o contexto sem avisar.

**Roles válidas:** `chat`, `edit`, `apply`, `autocomplete`, `embed`, `rerank`, `summarize`. O padrão é `[chat, edit, apply, summarize]`.

**No Windows, grave em UTF-8 sem BOM.** O parser YAML engasga com BOM — o `Set-Content` do PowerShell pode adicionar um.

**Só um modelo fica carregado no servidor por vez.** Listar vários aqui é conveniência para trocar sem editar arquivo, mas trocar a seleção no Continue **não** troca o modelo servido. Para isso:

```bash
./macos/llm-server.command restart fast
```

### Autocomplete: por que fica de fora

Deliberadamente omitido das configurações deste repositório.

O autocomplete dispara **a cada tecla digitada** e competiria com o chat pelo mesmo modelo residente. Num Mac de 16 GB isso empurra o sistema para swap; numa GPU de 8 GB, empurra camadas para a CPU. Nos dois casos, o editor engasga.

Se quiser, use um **segundo servidor** com um modelo pequeno em outra porta:

```bash
LLM_PORT=8081 ./macos/llm-server.command start tiny
```

```yaml
  - name: Autocomplete tiny
    provider: openai
    apiBase: http://127.0.0.1:8081/v1
    apiKey: local
    model: mlx-community/mini-coder-4b-OptiQ-4bit
    roles: [autocomplete]
```

Mas confirme que a soma dos dois modelos cabe na sua memória antes.

---

## Omnigent (Meta-harness)

O [Omnigent](https://github.com/omnigent-ai/omnigent) é um orquestrador de agentes. Ele não é uma engine de inferência (como o llama.cpp), mas um meta-harness: uma camada única sobre Claude Code, Codex, Cursor, `pi` e agentes próprios, com vários agentes colaborando na mesma sessão.

### Instalação

Precisa de **Python 3.12+**. O pacote no PyPI é `omnigent` — o pacote homônimo no **npm é outro projeto**, não instale por lá.

```bash
uv tool install --python 3.12 omnigent
```

### Onde vai a configuração

Num `agent.yaml`. Os dois arquivos deste repositório vivem em [`omnigent/`](../omnigent/).

**Caminho 1 — Omnigent falando direto com o servidor MLX** ([`omnigent/qwen-local.yaml`](../omnigent/qwen-local.yaml)):

```yaml
name: qwen_local
prompt: |
  Você é um assistente de engenharia direto e conciso.

executor:
  harness: openai-agents
  model: mlx-community/Qwen3-8B-4bit
  use_responses: false
  auth:
    type: api_key
    api_key: local
    base_url: http://127.0.0.1:8080/v1

os_env:
  type: caller_process
  cwd: .
```

**Caminho 2 — Omnigent pilotando o `pi`** ([`omnigent/qwen-local-pi.yaml`](../omnigent/qwen-local-pi.yaml)): aqui quem resolve provider e credencial é o `~/.pi/agent/models.json` já configurado acima, e o Omnigent só orquestra o CLI em modo RPC.

```yaml
executor:
  harness: pi
  model: mlx-community/Qwen3-8B-4bit
```

```bash
./macos/llm-server.command start agent        # o servidor precisa estar no ar
omnigent run omnigent/qwen-local.yaml
omnigent run omnigent/qwen-local.yaml -p "resuma o README" # um turno, sem REPL
```

### Três detalhes que quebram

**`use_responses: false` não é opcional.** O harness `openai-agents` usa o Agents SDK, que por padrão fala a **Responses API** (`/v1/responses`). O `mlx_lm.server` só implementa `/v1/chat/completions` — sem essa flag, todo turno morre em 404. O default só é `false` automaticamente para modelos `databricks-*` não-GPT; qualquer outro id, incluindo o nosso, cai no caminho Responses.

**Prefira `executor.auth` a `export OPENAI_BASE_URL`.** As duas rotas funcionam — o executor cai para as variáveis de ambiente quando o spec não declara `auth` —, mas o `auth` deixa o agente autocontido: quem clonar o repositório roda sem preparar o shell.

**A telemetria de produto vem ligada.** O Omnigent envia dados de uso anonimizados por padrão. Num lab local-first isso costuma ser o oposto do que se quer — desligue de forma persistente em `~/.omnigent/config.yaml`:

```yaml
telemetry: false
```

Também vale `OMNIGENT_DISABLE_TELEMETRY=true` ou `DO_NOT_TRACK=1` no ambiente. Não confunda com `OMNIGENT_TELEMETRY_ENABLED`, que é o tracing OpenTelemetry — esse já vem **desligado** e é opt-in.

### Expectativa de desempenho

Vale o mesmo aviso do `pi`, agravado: o Omnigent sobe um servidor local em Python e um runner, então o consumo de RAM some com a folga que o modelo de 8B já deixava apertada. Num Air de 16 GB, com editor e navegador abertos, o sistema vai para swap e o turno passa de minutos. Feche o que puder, ou use o perfil `tiny`.

Medido nesta máquina: com o `mlx_lm.server` residente no perfil `agent` mais o Omnigent, sobraram **0,3 GB de RAM livre e 16,8 GB em swap**. O gargalo é memória, não CPU — e é o motivo pelo qual servir o modelo de outra máquina deixa de ser luxo.

---

## Servindo de outra máquina da rede

Se você tem uma segunda máquina com o modelo carregado, o cliente só precisa trocar o endereço. O ganho é direto: a máquina que edita código para de disputar RAM com a inferência.

Do lado que **serve** (Windows, `llama-server`):

```powershell
.\windows\llm-server.ps1 start agent -Lan
```

O `-Lan` faz bind **no IP da interface física ativa, e só nele**. O padrão sem a flag é `127.0.0.1`, que não sai da máquina.

**Não use `0.0.0.0`**, mesmo que o `$env:LLM_HOST` aceite. Aquilo escuta em *toda* interface: VPN corporativa conectada, Hyper-V, WSL, Tailscale. Um bind num IP específico limita a exposição à rede que você realmente quis atender. Se o `-Lan` não conseguir resolver a interface, ele **falha** em vez de abrir tudo — passe o endereço à mão com `$env:LLM_HOST = '192.168.3.51'`.

E libere a porta apenas para a sua faixa de IP — PowerShell como administrador:

```powershell
New-NetFirewallRule -DisplayName 'llama-server LAN' -Direction Inbound `
  -Protocol TCP -LocalPort 8080 -Action Allow -Profile Private `
  -RemoteAddress 192.168.3.0/24
```

Do lado que **consome** (macOS), veja [`omnigent/qwen-remote.yaml`](../omnigent/qwen-remote.yaml) e o provider `llama-remote` em `~/.pi/agent/models.json`:

```bash
pi --provider llama-remote --model agent --api-key local
omnigent run omnigent/qwen-remote.yaml
```

### O que muda em relação ao local

**O `model` deixa de ser o repo do Hugging Face e passa a ser o ALIAS.** Em single-model mode o `llama-server` responde ao que veio em `-a` — `agent`, `fast`, `tiny`. Mandar `mlx-community/Qwen3-8B-4bit` para ele dá erro de modelo inexistente.

**O contexto é menor.** Os perfis do Windows usam `Ctx = 16384` para `agent` e `fast` (contra 32768 no macOS). Declarar 32768 no cliente faz o servidor truncar sem avisar.

**`--api-key local` sobre HTTP puro não protege nada.** Qualquer um na mesma rede lê os prompts e as respostas em texto claro. Em rede doméstica é um risco que se aceita de olhos abertos; em rede de escritório ou compartilhada, não use — exponha por um túnel (SSH, WireGuard) em vez de abrir a porta.

**A grande sacada:** o `Qwen3` local edita arquivos com as ferramentas dele e, no mesmo `agent.yaml`, um sub-agente `revisor` usa uma API externa (ex: Claude) para validar o código gerado localmente. O trabalho barato fica em casa; a revisão caríssima só vê o diff.

---

## Outros clientes

Qualquer coisa que aceite `OPENAI_BASE_URL` funciona: Aider, Cline, Zed, os SDKs oficiais. Dois pontos a lembrar:

- **Modo agente exige um modelo com tool calling comprovado** — veja [tool calling](03-tool-calling.md). Cliente configurado corretamente com modelo errado falha de formas confusas.
- **Alguns modelos vazam o token de fim de turno** (`<|im_end|>`) no conteúdo da resposta. O `mlx_lm.server` não aplica *skip special tokens*. O comando `ask` dos nossos scripts filtra; clientes de terceiros geralmente não.

---

## Dividindo o trabalho entre dois perfis

A configuração mais produtiva não é escolher um modelo — é ter dois e trocar:

| tarefa | perfil | por quê |
|---|---|---|
| `pi`, Cline, modo agente | `agent` (Qwen3-8B) | único com tool calling comprovado |
| chat e edit no VSCode | `fast` (Qwen2.5-Coder-7B) | escreve código melhor |
| autocomplete | `tiny`, outra porta | precisa ser leve e não competir |

```bash
./macos/llm-server.command restart agent    # ~5 segundos
```

---

Próximo: [manutenção — baixar, remover, tunar](05-manutencao.md).
