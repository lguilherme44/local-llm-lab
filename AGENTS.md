# Agent Teams & Autonomous Workflow
**Projeto:** `local-llm-lab`

Este documento define a pipeline autônoma de desenvolvimento (Spec-Driven Development) e os papéis dos sub-agentes de Inteligência Artificial que atuam neste repositório. O objetivo deste workflow é **extrair a qualidade máxima possível**, removendo a subjetividade e garantindo a verificação empírica de toda feature ou correção implementada.

---

## 1. A Pipeline de Qualidade Extrema (Feature & Fix Workflow)

Para qualquer feature, refatoração significativa ou bug complexo, a execução deve respeitar rigorosamente a seguinte linha de montagem. O avanço de fase só ocorre se a fase anterior concluir seu critério de aceite (Pass/Fail).

### Fase 1: Arquitetura & Especificação (`sdd-explore` → `sdd-tasks`)
- **Ator:** Agent Orchestrator / Architect
- **Ação:** Lê os requisitos do humano, cruza com as limitações de hardware/engine (MLX/llama.cpp) e detalha a solução em **Work Units** (commits entregáveis).
- **Critério de Saída:** Arquivos de `spec` e `tasks` salvos. Nenhum código-fonte modificado ainda.

### Fase 2: Implementação Isolada (`sdd-apply`)
- **Ator:** Coder Agent / Local LLM Task Executor (`scripts/local-task-executor.py`)
- **Ação:** Executa as `tasks` sequencialmente. O modelo local processa tarefas unitárias e a IA orquestradora revisa/refina o código gerado.
- **Regra de Ouro (TDD / Test Mandatory):** Toda nova funcionalidade ou utilitário **DEVE ser acompanhada compulsoriamente pelo seu arquivo de teste unitário** (`test-*.py` ou `.spec.ts`).
- **Critério de Saída:** Código escrito, dependências injetadas e testes unitários passando.

### Fase 3: A Prova de Fogo do E2E (`sdd-verify`)
- **Ator:** Verifier Agent (Terminal Integrado)
- **Ação:** O agente DEVE executar o ambiente real.
  1. Instancia/verifica o servidor de inferência: `./macos/llm-server.command start agent` ou versão Windows.
  2. Roda o script de validação de tooling/suíte contra o LLM instanciado: `python scripts/test-feature.py` ou `test-tools.py`.
- **Critério de Saída:** O log do terminal deve retornar sucesso e zero falhas de parsing/timeout. Se falhar, a pipeline entra em *Fix Loop* e devolve para a Fase 2.

### Fase 4: Tribunal Impiedoso (`judgment-day`)
- **Ator:** 2x Blind Judges (Agentes Adversariais & `scripts/local-blind-judge.py`)
- **Ação:** O orquestrador executa o julgamento cego via modelo local (`scripts/local-blind-judge.py`) e sub-agentes paralelos para avaliar o diff buscando vazamentos de memória, segredos expostos e quebras de contrato.
- **Critério de Saída:** Resposta `JUDGMENT: APPROVED`. Se houver rejeição, a pipeline pausa para correção.

### Fase 5: Entrega (`work-unit-commits` / `prepare-commit-msg`)
- **Ator:** Agent Orchestrator / Git Hook (`.git/hooks/prepare-commit-msg`)
- **Ação:** O Git Hook gera a mensagem no padrão Conventional Commits via modelo local, agrupa os diffs validados e envia a entrega com logs de evidência do E2E.
- **Critério de Saída:** Commit/PR pronto com verificação comprovada.

---

## 2. Configuração Centralizada do Modelo Local
Todas as credenciais e parâmetros do modelo local (URL, API Key, nome do modelo) estão centralizados no arquivo de raiz:
- [`.env.local.llm`](file:///Users/guilhermelellis/Desktop/local-llm-lab/.env.local.llm) e consumidos via `scripts/local_llm_config.py`.

---

## 3. Delegação de Sub-agentes
- **`Codebase Researcher`**: Somente leitura. Faz varredura para entender OOM (Out of Memory) e investigar dependências. Nunca altera arquivos.
- **`Terminal QA`**: Instancia o servidor em background, manda os requests para a porta 8080 e reporta o JSON/stdout de volta. Isolado de quem escreve código.
- **`Blind Judge`**: Recebe apenas a tarefa: "Encontre vulnerabilidades, regressões de performance e quebras da regra de ouro neste diff". 

---

## 4. Contrato de Falha (Fix Loop)
A IA não tem permissão para assumir que um bug foi corrigido "porque o código parece certo". O fechamento de uma issue exige, compulsoriamente, a evidência (log do terminal salvo em bloco de texto) da **Fase 3** no comentário ou PR.

