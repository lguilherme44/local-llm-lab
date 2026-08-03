# Relatório de Benchmark e Diagnóstico: Perfil `qwen27b`

## Métricas de Desempenho
- **Modelo/Perfil:** `qwen27b`
- **Vazão Média (Benchmark):** 0.00 tok/s
- **Tempo de Geração (Landing Page):** 900.12s
- **Tokens de Saída Gerados:** 0
- **Motivo da Finalização (`finish_reason`):** `unknown`

## Monitoramento de Erros & Causas Raiz

### 1. Causa Raiz dos Erros 503 (Service Unavailable / Remote Connection Closed)
- **Causa:** Ocorrem durante a transição de perfis no script `llm-server.sh`. Quando um modelo anterior deixa um processo `llama-server` em estado zumbi (PID não liberado) ou consome a VRAM da GPU RTX 3060 Ti (8GB), novas conexões HTTP retornam 503 ou a conexão é fechada abruptamente até que haja um encerramento forçado via `kill -9`.
- **Solução Implementada:** Encerramento compulsório via `pkill -9 llama-server` antes de inicializar o novo perfil.

### 2. Causa Raiz de Páginas Incompletas / Cortes de Código
- **Status da Tag `</html>`:** Não (Corte no final)
- **Causa:** Erro de timeout ou desconexão na chamada HTTP durante a geração (timed out).
