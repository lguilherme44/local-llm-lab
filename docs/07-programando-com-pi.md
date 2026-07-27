# Programando com o pi e um modelo local

Guia de uso real: do primeiro comando ao que funciona e ao que não funciona. A configuração está em [clientes](04-clientes.md); aqui é sobre **trabalhar** com isso.

---

## Do zero ao primeiro comando

**1. Suba o servidor com um modelo que faça tool calling.** Isso não é opcional — sem ferramentas o `pi` não lê nem edita arquivo.

```bash
./macos/llm-server.command start agent
```

O perfil `agent` (Qwen3-8B) é o único da nossa lista com tool calling comprovado. O `fast` escreve código melhor e **não serve** aqui — ele devolve a chamada como texto e o agente fica sem nada para executar.

**2. Instale o pi**, se ainda não tiver:

```bash
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
```

**3. Configure o provider local** em `~/.pi/agent/models.json` (veja [clientes](04-clientes.md)). No Windows, `.\windows\llm-clients-setup.ps1` faz isso.

**4. Abra o pi na pasta do projeto:**

```bash
cd meu-projeto
pi --provider mlx-local --model mlx-community/Qwen3-8B-4bit --api-key local
```

Para não repetir os parâmetros, fixe o padrão em `~/.pi/agent/settings.json`:

```json
{
  "defaultProvider": "mlx-local",
  "defaultModel": "mlx-community/Qwen3-8B-4bit"
}
```

Depois disso, só `pi`.

---

## Ajuste que muda tudo: compactação

Este é o ajuste mais importante para modelo local, e o padrão do `pi` está errado para o nosso caso.

A auto-compactação dispara quando:

```
contextTokens > contextWindow − reserveTokens
```

O `reserveTokens` padrão é **16384**. Com um modelo de contexto 32k, isso significa que a compactação começa em **16k — na metade do contexto disponível**. E cada compactação é uma **chamada extra ao modelo** para gerar o resumo: num modelo local, dezenas de segundos que você paga sem obter trabalho.

Crie `~/.pi/agent/settings.json` (ou `<projeto>/.pi/settings.json`) com:

```json
{
  "compaction": {
    "enabled": true,
    "reserveTokens": 4096,
    "keepRecentTokens": 12000
  }
}
```

Isso empurra o gatilho de 16k para ~28k, aproveitando o contexto que você declarou.

> `reserveTokens` precisa cobrir a resposta mais longa que você espera. 4096 combina com o `--max-tokens 4096` dos nossos scripts. Se aumentar um, aumente o outro.

Compactação manual, quando você sabe que virou uma fase nova do trabalho:

```
/compact terminei o parser, foco agora nos testes
```

A instrução opcional direciona o resumo — vale usar.

---

## O que esperar de desempenho

Medido num MacBook Air M4 de 16 GB com Qwen3-8B:

| operação | tempo |
|---|---|
| pergunta simples, sem ferramenta | 2–5 s |
| turno com uma chamada de ferramenta | ~30–60 s |
| tarefa completa (ler, editar, verificar) | **minutos** |

A referência que temos: corrigir um bug de uma linha (`return a - b` → `a + b`) levou **5,5 minutos e 4 chamadas** ao servidor.

**Por que tão mais lento que a nuvem:** o agente reenvia system prompt, definições de ferramentas e histórico **a cada turno**. Com prefill a ~154 tok/s, um contexto de 3.500 tokens custa ~23 s antes do primeiro token da resposta.

O prompt cache derruba isso para ~1 s em prefixo repetido (22×) — é o que torna a coisa viável do segundo turno em diante. Certifique-se de que o servidor subiu com ele (os nossos scripts já fazem).

**Consequência prática:** modelo local não é para trabalho interativo de vaivém rápido. É para tarefas que você delega e vai fazer outra coisa.

---

## O que funciona bem

Tarefas **fechadas, locais e verificáveis**:

- *"Adicione tratamento de erro nesta função"*
- *"Escreva testes para o módulo X"*
- *"Renomeie a variável Y em todo este arquivo"*
- *"Converta esta função para async"*
- *"Explique o que este arquivo faz"* (nem usa ferramenta — é rápido)
- *"Rode os testes e conserte o que falhar"* — funciona bem porque o teste **verifica** o resultado

O padrão comum: **escopo de um ou dois arquivos, com critério de sucesso objetivo.**

Dê o arquivo de entrada explicitamente em vez de deixar o modelo procurar. O `pi` aceita arquivos como argumento:

```bash
pi @src/parser.ts "adicione tratamento para entrada vazia"
```

Cada busca que o modelo evita é um turno de ~40 s economizado.

## O que funciona mal

- **Refactor multi-arquivo.** O contexto cresce, o prompt cache perde eficácia e cada turno fica mais caro que o anterior. Já vimos o custo por turno subir ao longo de uma sessão.
- **"Explore o projeto e me diga o que melhorar."** Sem escopo, o modelo faz muitas chamadas de ferramenta, e cada uma custa dezenas de segundos.
- **Tarefas que dependem de raciocínio longo.** Um 8B quantizado erra decisões de arquitetura de formas plausíveis.
- **Depurar algo que você não entende.** O modelo vai propor algo que *parece* certo. Sem entender o problema, você não tem como avaliar.

---

## A regra que não pode ser esquecida

**Modelo pequeno local erra de formas que parecem certas.**

Pedimos um `debounce` em TypeScript. O modelo respondeu:

```typescript
timeout = setTimeout(() => { func(...args); }, wait);
return func(...args);   // ← chama IMEDIATAMENTE
```

Compila. Passa no type-check. E **anula o debounce inteiro** — a função é chamada na hora *e* agendada.

Revisar não é opcional. Isso vale para qualquer LLM, e mais ainda para um 8B quantizado rodando no seu laptop.

**O corolário prático:** prefira tarefas com verificação automática. *"Faça os testes passarem"* é muito melhor que *"implemente essa feature"*, porque o teste é um juiz que não depende da sua atenção.

---

## Fluxo recomendado

O que se mostrou produtivo, dado o custo por turno:

**1. Escopo apertado, entrada explícita.**
```bash
pi @src/slugify.py @tests/test_slugify.py "faça os testes passarem"
```

**2. Deixe rodar.** Não fique olhando. Cada turno leva ~40 s e você vai se irritar sem motivo.

Nós mesmos caímos nessa: interrompemos a mesma execução três vezes achando que estava travada. Os processos abandonados **terminaram com sucesso** depois de 10+ minutos. Se o servidor está registrando requisições no log, está trabalhando.

```bash
./macos/llm-server.command logs     # confirme atividade antes de concluir travamento
```

**3. Revise o diff.** Sempre. Veja a regra acima.

**4. `/compact` ao mudar de fase.** Antes que a auto-compactação dispare no meio de um raciocínio.

**5. Troque de modelo conforme a tarefa.**

```bash
./macos/llm-server.command restart fast    # ~5 s
```

Use `fast` (Qwen2.5-Coder) para *pedir código em chat*, onde escreve melhor e ferramentas não importam. Use `agent` (Qwen3) quando ele precisar **agir** nos arquivos.

---

## Quando não usar modelo local

Vale dizer com clareza, porque insistir no lugar errado gera frustração e a conclusão errada de que "LLM local não serve".

**Fique no local quando:** o código é sensível e não pode sair da máquina; você está sem rede; a tarefa é repetitiva e mecânica; você quer aprender como isso funciona por dentro; ou volume alto tornaria a API caro.

**Vá para a nuvem quando:** a tarefa exige raciocínio sobre muitos arquivos; você precisa de vaivém rápido e interativo; o problema é difícil e um modelo fraco vai te custar mais tempo do que economiza; ou é urgente.

Não é ideologia. Um 8B quantizado num laptop é uma ferramenta com envelope de uso definido — e conhecer o envelope é o que separa usar bem de reclamar.

---

## Comandos do pi que valem conhecer

| comando | para quê |
|---|---|
| `/model` | trocar de modelo/provider na sessão |
| `/compact [instruções]` | resumir o contexto agora |
| `/new` | sessão nova, contexto zerado |
| `/fork` | ramificar a sessão atual e testar outro caminho |
| `/copy` | copiar a última resposta |
| `/export` | exportar a sessão |
| `/hotkeys` | ver os atalhos |

Fora da sessão:

```bash
pi -c                 # continuar a última sessão
pi -r                 # escolher uma sessão para retomar
pi -p "pergunta"      # não-interativo: responde e sai
pi --no-tools ...      # desliga ferramentas (chat puro, muito mais rápido)
```

O `--no-tools` é subestimado: para *"explique este código"* ou *"como faço X em Python"*, ferramentas só adicionam tokens ao prompt. Sem elas, a resposta sai em segundos em vez de minutos.

---

Voltar ao [índice](../README.md#documentação).
