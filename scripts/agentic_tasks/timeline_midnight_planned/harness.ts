// Mini-harness de teste, sem dependência externa.
//
// O spec original usa vitest. Trazer vitest para cá amarraria o benchmark ao
// node_modules do repo do SaaS; como o arquivo sob teste não tem NENHUM import,
// vale mais reimplementar o pouco que o spec usa (describe/it/expect.toEqual).
//
// Roda com: node --experimental-strip-types run-tests.ts

type Fn = () => void
const pendentes: { nome: string; fn: Fn }[] = []
let prefixo = ""

export function describe(nome: string, fn: Fn): void {
  const anterior = prefixo
  prefixo = anterior ? `${anterior} > ${nome}` : nome
  fn()
  prefixo = anterior
}

export function it(nome: string, fn: Fn): void {
  pendentes.push({ nome: prefixo ? `${prefixo} > ${nome}` : nome, fn })
}

export function expect(recebido: unknown) {
  return {
    // toEqual do vitest é igualdade estrutural profunda. JSON.stringify basta
    // aqui porque o objeto sob teste é só string/number/boolean, sem undefined,
    // Date, Map nem referência cíclica. Se o spec crescer, isto precisa evoluir.
    toEqual(esperado: unknown) {
      const a = JSON.stringify(recebido, null, 2)
      const b = JSON.stringify(esperado, null, 2)
      if (a !== b) {
        throw new Error(`esperado:\n${b}\n\nrecebido:\n${a}`)
      }
    },
  }
}

export function executar(): number {
  let falhas = 0
  for (const { nome, fn } of pendentes) {
    try {
      fn()
      console.log(`  ok   ${nome}`)
    } catch (erro) {
      falhas++
      console.log(`  FAIL ${nome}`)
      console.log(String((erro as Error).message).split("\n").map(l => `         ${l}`).join("\n"))
    }
  }
  console.log(`\n${pendentes.length - falhas} passaram, ${falhas} falharam, de ${pendentes.length}`)
  return falhas
}
