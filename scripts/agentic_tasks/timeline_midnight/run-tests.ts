// Ponto de entrada da suíte. Importar o spec registra os casos; executar() roda.
import "./timeline.utils.spec.ts"
import { executar } from "./harness.ts"

process.exit(executar() === 0 ? 0 : 1)
