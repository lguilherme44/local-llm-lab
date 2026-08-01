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

**A causa:** o modelo devolve a chamada como **texto**, não no campo estruturado.

E a forma varia entre execuções. Duas observadas no mesmo modelo:

```
# com uma ferramenta 'bash' — usou a tag de DECLARAÇÃO
emitido:   <tools>{"name": "bash", "arguments": {"cmd": "ls"}}</tools>
esperado:  <tool_call>{"name": "bash", ...}</tool_call>

# com uma ferramenta 'read_file' — usou bloco markdown
emitido:   ```json
           {"name": "read_file", "arguments": {"path": "config.json"}}
           ```
```

No primeiro caso confundiu `<tools>` (que **declara** quais ferramentas existem, parte do prompt) com `<tool_call>` (que **faz** a chamada). No segundo, ignorou o protocolo e respondeu em markdown.

Nos dois, o parser do servidor não reconheceu e o `tool_calls` voltou `null`. O modelo *entendeu* a tarefa — montou nome e argumentos corretos — e falhou no formato.

Isso aconteceu com o `Qwen2.5-Coder-7B` **e** com o `14B`. O fine-tune que os tornou melhores em escrever código degradou a aderência ao protocolo de ferramentas.

**Implicação prática:** não basta procurar uma tag específica no `content` para "consertar" isso do lado do cliente. A saída é inconsistente. Troque de modelo.

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

## Passar aqui não é o bastante

Tudo nesta página mede uma coisa: o modelo **sabe pedir** uma ferramenta e usar o retorno. É condição necessária para ser agente, e não é suficiente — nem perto.

Medido: o `Qwen3-8B` passa neste teste, é o mais rápido da bancada com 72,5 tok/s, e **não entrega uma feature de trinta linhas**. Recebeu um `Cache` sem expiração e seis testes falhando; gastou 14 turnos, reescreveu o arquivo seis vezes, e saiu com o teste mais simples da suíte quebrado. O bug era uma condição invertida que ele releu cinco vezes sem enxergar.

O `Qwen3-Coder-30B-A3B` resolveu em 2 turnos, gerando 3× mais devagar.

Por isso existe um segundo script. O `test-tools.py` valida o **ciclo**; o `test-feature.py` valida a **entrega**, e o critério dele não é heurística de texto — é o `pytest`:

```bash
uv run --with pytest scripts/test-feature.py moe --host 192.168.3.51
```

Números e análise em [benchmarks](benchmarks.md#teste-de-feature-quando-o-benchmark-e-a-entrega-discordam).

---

## Checklist antes de confiar num modelo como agente

1. Rode `scripts/test-tools.py` — o ciclo completo, não só a primeira chamada
2. Se `tool_calls: null`, veja o `content` — o modelo tentou e errou a tag, ou não tentou?
3. Se `content` vier vazio, suspeite de raciocínio comendo a cota de `max_tokens` antes de checar template: é a causa mais comum e a mais silenciosa (`--reasoning off`)
4. Se falhar em MLX, teste a variante GGUF antes de descartar o modelo
5. Teste nos dois engines antes de culpar o servidor
6. **Rode `scripts/test-feature.py`.** Os cinco passos acima podem passar e o modelo ainda não servir para trabalhar

E o teste final, que nenhum script substitui: **use no seu código**. O `test-feature.py` roda uma tarefa pequena e isolada, escolhida para caber em 16k de contexto. Um refactor multi-arquivo, com o contexto crescendo a cada turno e o prompt cache perdendo eficácia, é outro regime — e continua sendo a limitação mais relevante e menos testada deste repositório.

---

Próximo: [configurando os clientes](04-clientes.md).
