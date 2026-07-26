# Tool calling: metodologia e resultados

Este é o documento central do repositório. Se você vai usar um agente de código local, **tool calling é o requisito que decide tudo** — e é o menos confiável de verificar por documentação.

---

## O que é, em termos práticos

Um agente de código precisa ler arquivos, rodar comandos e editar código. Ele não faz isso sozinho: ele pede ao modelo, e o modelo responde com uma **chamada estruturada**.

O que o agente precisa receber:

```json
{
  "choices": [{
    "message": {
      "content": null,
      "tool_calls": [{
        "id": "abc123",
        "function": { "name": "read_file", "arguments": "{\"path\": \"config.json\"}" }
      }]
    }
  }]
}
```

O `tool_calls` preenchido é o que importa. Se vier `null`, o agente não tem o que executar — mesmo que o modelo tenha *escrito* a intenção em texto.

---

## Por que documentação não basta

O que **parece** garantir suporte:

1. O `chat_template` do modelo declara `<tool_call>` ✅
2. O servidor tem parser de tool calls ✅
3. O modelo aceita o parâmetro `tools` na requisição ✅

Tivemos os três — e o `tool_calls` voltou `null`.

**A causa:** o modelo emitiu a tag **errada**.

```
esperado:  <tool_call>{"name": "bash", "arguments": {...}}</tool_call>
emitido:   <tools>{"name": "bash", "arguments": {...}}</tools>
```

`<tools>` é a tag que **declara** quais ferramentas existem — parte do prompt, não da resposta. `<tool_call>` é a que **faz** a chamada. O modelo confundiu as duas, o parser do servidor não reconheceu, e a "chamada" chegou como texto solto no campo `content`.

Isso aconteceu com o `Qwen2.5-Coder-7B` **e** com o `14B`. O fine-tune que os tornou melhores em escrever código degradou o tool calling.

**Consequência metodológica:** não existe substituto para executar o teste.

---

## O teste

Testar apenas "o modelo emite uma chamada?" é insuficiente. Um agente precisa do **ciclo completo**:

1. Pedir a ferramenta
2. Receber o resultado da execução
3. **Usar aquele resultado** na resposta final

O passo 3 é onde alguns modelos falham silenciosamente: pedem a ferramenta, recebem o retorno e então ignoram, respondendo com informação inventada.

```bash
python3 scripts/test-tools.py <modelo> [porta]
```

O script define uma ferramenta `read_file`, pede ao modelo que a use, devolve um JSON fabricado (`{"name": "meu-projeto", "version": "3.1.4", ...}`) e verifica se a resposta final **contém aqueles valores**. Se o modelo responder sem citar `3.1.4`, ele ignorou a ferramenta — reprovado.

Saída de um caso aprovado:

```
[turno 1 · 3.0s]
  ✓ tool_calls ESTRUTURADO
    -> read_file({"path": "config.json"})
[turno 2 · 4.5s]
  ✓ usou o resultado da ferramenta na resposta
  geração: 16.1 tok/s
APROVADO — serve como agente
```

---

## Resultados

Todos executados com o ciclo completo.

| modelo | runtime | resultado | tok/s |
|---|---|---|---|
| Qwen3-8B-4bit | MLX | ✅ **aprovado** | 16,1 |
| Qwen3-8B-GGUF Q4_K_M | llama.cpp | ✅ **aprovado** | 18,8 |
| Qwen3-4B-GGUF Q4_K_M | llama.cpp | ✅ **aprovado** | 33,1 |
| Qwen2.5-Coder-7B-4bit | MLX | ❌ reprovado | — |
| Qwen2.5-Coder-7B-4bit | mlx-vlm | ❌ reprovado | — |
| Qwen3-4B-Instruct-2507-4bit | MLX | ❌ reprovado | — |

### Os dois modos de falha

**Falha do modelo** — `Qwen2.5-Coder` (7B e 14B). Template correto, parser presente, modelo emite `<tools>` em vez de `<tool_call>`. Testado nos **dois** engines MLX para confirmar que a culpa não era do servidor: falhou igual nos dois.

**Falha de infraestrutura** — `Qwen3-4B-Instruct-2507-4bit`. Este é mais sutil e vale conhecer:

O repositório usa o formato novo do `transformers`, com o template num arquivo separado (`chat_template.jinja`) em vez de dentro do `tokenizer_config.json`. O `mlx_lm` lê o template de dentro do `tokenizer_config.json`, que nesse repositório está **vazio**.

Resultado: sem template de ferramentas, o modelo recebe a requisição com `tools` e responde **string vazia**. Sem tools, responde normalmente. O sintoma (`content: ''`) não sugere em nada a causa real.

**Como reconhecer:** se o modelo funciona sem `tools` e retorna vazio com `tools`, verifique se existe `chat_template.jinja` no repositório:

```bash
curl -s "https://huggingface.co/api/models/<org>/<repo>" | \
  python3 -c "import sys,json; print([f['rfilename'] for f in json.load(sys.stdin)['siblings']])"
```

Se existir, o formato GGUF do mesmo modelo provavelmente funciona — o llama.cpp com `--jinja` usa o template **embutido no arquivo GGUF**, contornando o problema. Foi o caso: o Qwen3-4B falhou em MLX e passou em GGUF.

---

## Diferenças entre servidores

### `mlx_lm.server` (Apple, texto)

Tem parser (`mlx_lm/tokenizer_utils.py` procura `<tool_call`). Funciona quando o modelo emite a tag certa.

### `mlx_vlm.server` (Apple, multimodal)

Também tem parser, **e exige o campo `model` no corpo da requisição**:

```json
{ "model": "mlx-community/Qwen3-8B-4bit", "messages": [...] }
```

Sem ele: `422 Unprocessable Entity`, **para sempre**. O servidor aceita conexões, responde 422 a cada tentativa, e o cliente parece estar travando. Diagnóstico só sai lendo o log.

Inclua o `model` sempre — o `mlx_lm.server` aceita o campo igual, então não há motivo para omitir.

### `llama-server` (llama.cpp)

Precisa de `--jinja` para usar o template embutido no GGUF. **Já é o padrão** nas versões atuais, mas explicitar não custa.

Dois cuidados: ele escuta em `0.0.0.0` por padrão (expõe na rede — force `--host 127.0.0.1`) e libera CORS para `*` sem chave (use `--api-key`).

---

## Checklist antes de confiar num modelo como agente

1. Rode `scripts/test-tools.py` com o ciclo completo
2. Se `tool_calls: null`, veja o `content` — o modelo tentou e errou a tag, ou não tentou?
3. Se `content` vier vazio, procure `chat_template.jinja` no repositório
4. Se falhar em MLX, teste a variante GGUF antes de descartar o modelo
5. Teste nos dois engines antes de culpar o servidor

E o teste final, que nenhum script substitui: **dê uma tarefa real**. Coloque um bug num arquivo e peça ao agente para corrigir. Foi assim que validamos o `pi` — arquivo com `return a - b`, pedido "leia e corrija". Ele leu, editou, acertou e preservou o resto do arquivo.

Levou **5,5 minutos e 4 chamadas** para um bug de uma linha. Funciona; o custo por turno é alto.

---

Próximo: [configurando os clientes](04-clientes.md).
