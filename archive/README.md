# archive

Coisas removidas do projeto que valia guardar, com o motivo.

## `harness-models-api/` — as rotas de gestão de modelo

Vinham do `harness/`, um fork do [Chatbot UI](https://github.com/mckaywrigley/chatbot-ui)
que foi removido em 03/08/2026. São a única parte que fazia algo que nenhuma ferramenta
pronta faz: gerenciar o `llama-server` pela web.

| arquivo | o que fazia |
|---|---|
| `download.route.ts` | baixa peso do Hugging Face na máquina remota |
| `list.route.ts` | lista modelos em disco |
| `load.route.ts` | sobe um perfil e reporta VRAM |
| `status.route.ts` | estado do servidor |
| `upload.route.ts` | envia `.gguf` local para a máquina remota |

São referência, não código vivo: usam `NextResponse` e o runtime do Next.js. Se um dia
virar um painel de verdade, o valor está na lógica, não nos arquivos.

### Por que o harness saiu

Ele era meio, não fim — o objetivo é programar melhor, não ter um harness. E como harness
de programação faltava metade do essencial:

| capacidade | tinha? |
|---|---|
| escrever arquivo | sim (`/api/workspace/files`, só POST) |
| listar arquivos | sim (`/api/workspace/tree`, só nomes) |
| **ler conteúdo de arquivo** | **não** — nenhum endpoint expunha leitura |
| **rodar teste** | **não** — `execSync` só em `/api/git` |
| **loop de tool calling** | **não** — as rotas de chat não passavam `tools` |

Sem ler código e sem rodar teste, não dá para corrigir bug. E sem loop de ferramentas o
modelo não chamava nada sozinho — a pessoa era o transporte, copiando e colando.

O `PLAN.md` dele também partia de uma premissa incompatível com o objetivo:
*"Zero-Context Guarantee"*, mandar só a mensagem do usuário sem contexto. Bom para medir
modelo sem contaminação, inútil para programar, que exige mandar arquivo, teste e stack
trace.

Três defeitos que valem lembrar, porque são fáceis de repetir:

1. **Confinamento de path que não confina.** `workspace/files` derivava a base de
   `targetDir`, que vinha do body da requisição, e depois checava
   `absoluteFilePath.startsWith(baseWorkspace)`. Quem chama define a base, então a checagem
   passava sempre.
2. **Command injection.** `git worktree add -b "${name}" "${path}" ${baseBranch}` com
   `execSync`. O `name` era sanitizado; o `baseBranch` ia cru do body para o shell.
3. **Sandbox de iframe desarmado.** `sandbox="allow-scripts allow-same-origin"` anula o
   sandbox. O próprio `PLAN.md` avisava para não usar `allow-same-origin`; foi usado para
   carregar o Tailwind CDN no preview. Junto com (1), fechava uma cadeia: HTML gerado pelo
   modelo → clique em "Preview" → script com mesma origem → POST em `/api/workspace/files`
   com `targetDir` arbitrário.

O que ficou no lugar: usar ferramenta pronta (Cline, Aider, Continue) apontando para o
`llama-server`, e investir o tempo na suíte de benchmark, que é o que responde "esse modelo
serve?".

### Histórico do git

O harness era um repo aninhado (gitlink `160000`) cujo `origin` apontava para o **upstream**
`mckaywrigley/chatbot-ui`, não para um fork. Os cinco commits próprios nunca foram
publicados em lugar nenhum:

```
a17ba75 feat(models): add remote download, upload, status and vram load APIs and UI tabs
db579d4 feat(memory): implement sliding window logic for chat context
4f49b8b feat(workspace): implement diff-match-patch editing support
ab49df8 feat(tools): implement minimalist JSON Schema tool calling
e179b25 fix(chat): prevent redirect loop on new chat
```

Antes de apagar, o histórico completo foi salvo em bundle (fora do repo, porque tem 3,4 MB):

```
~/Desktop/harness-chatbot-ui-history.bundle
```

Para recuperar tudo:

```bash
git clone ~/Desktop/harness-chatbot-ui-history.bundle harness-recuperado
```

Enquanto esse arquivo existir, nada foi perdido de verdade. Se você decidir que não quer
mais, apague o bundle — mas é decisão sua, não consequência de ter apagado a pasta.
