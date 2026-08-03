# Relatório de Benchmark e Diagnóstico: Perfil `deepseek`

## Métricas de Desempenho
- **Modelo/Perfil:** `deepseek`
- **Vazão Média (Benchmark):** 29.57 tok/s
- **Tempo de Geração (Landing Page):** 81.04s
- **Tokens de Saída Gerados:** 1705
- **Motivo da Finalização (`finish_reason`):** `stop`

## Monitoramento de Erros & Causas Raiz

### 1. Causa Raiz dos Erros 503 (Service Unavailable / Remote Connection Closed)
- **Causa:** Ocorrem durante a transição de perfis no script `llm-server.sh`. Quando um modelo anterior deixa um processo `llama-server` em estado zumbi (PID não liberado) ou consome a VRAM da GPU RTX 3060 Ti (8GB), novas conexões HTTP retornam 503 ou a conexão é fechada abruptamente até que haja um encerramento forçado via `kill -9`.
- **Solução Implementada:** Processo limpo e validado com reinício limpo antes da execução da suíte.

### 2. Causa Raiz de Páginas Incompletas / Cortes de Código
- **Status da Tag `</html>`:** Sim (Página completa)
- **Causa:** Geração finalizada normalmente.
