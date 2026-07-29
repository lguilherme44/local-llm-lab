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

O [Omnigent](https://github.com/omnigent-ai/omnigent) é um orquestrador de agentes. Ele não é uma engine de inferência (como o llama.cpp), mas um cliente avançado que permite rodar múltiplos agentes colaborando na mesma sessão.

### Como configurar

Crie um arquivo `agent.yaml` para definir o seu agente apontando para o servidor local:

```yaml
name: meu-agente-local
prompt: |
  Você é um assistente focado e direto, usando o LLM local.

executor:
  harness: openai-agents
  model: mlx-community/Qwen3-8B-4bit  # substitua pelo alias do seu modelo
```

Rode o Omnigent apontando para a nossa API:

```bash
export OPENAI_BASE_URL=http://127.0.0.1:8080/v1
export OPENAI_API_KEY=local
omnigent run agent.yaml
```

**A grande sacada:** Com o Omnigent, você pode ter o `Qwen3` local editando arquivos usando as ferramentas dele e, no mesmo `agent.yaml`, declarar um sub-agente `revisor` usando uma API externa (ex: Claude 3.5) para validar o código gerado pelo modelo local.

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
