# Landing page gerada pelo perfil `moe`

Saída **não editada** do Qwen3-Coder-30B-A3B rodando numa RTX 3060 Ti de 8 GB. Está aqui para você ver o que essa classe de modelo entrega de verdade — incluindo o que ela erra.

| | |
|---|---|
| modelo | Qwen3-Coder-30B-A3B-Instruct, UD-Q3_K_XL (12,9 GB) |
| hardware | RTX 3060 Ti 8 GB + 16 GB de RAM |
| config | `ctx 16384`, `--n-cpu-moe 36`, KV em q8_0 |
| prompt | [`prompt.txt`](prompt.txt) — 552 tokens |
| saída | 7.432 tokens, `finish_reason: stop` (não truncou) |
| tempo | 302 s a 25,3 tok/s |
| rede | nenhuma requisição externa; tudo na LAN |

Abra o [`index.html`](index.html) direto no navegador.

## O que ele acertou

- HTML completo e válido, de `<!DOCTYPE>` a `</html>`, num arquivo só
- `tailwind.config` inline com os keyframes `fadeIn` e `slideUp`, exatamente como a diretriz 3 pediu — e duplicou em CSS puro como fallback
- Hero, features, depoimentos, preços e rodapé, com âncoras funcionando
- Um `IntersectionObserver` para animar seções ao entrar na viewport, que **ninguém pediu**
- Preencheu os placeholders do prompt (`[Descreva seu produto]`) inventando um produto coerente, em vez de copiar o colchete

## O que ele ignorou

A diretriz 2 era a mais enfática do prompt — "uso intenso de microinterações" — e citava duas classes pelo nome. Nenhuma das duas aparece:

```
hover encontrados:          hover:-translate-y-1   ausente
  12  hover:text-white      hover:shadow-xl        ausente
   5  hover:text-purple-600
   3  hover:opacity-90
```

Só troca de cor e opacidade. Zero `transform`, zero elevação de sombra.

O mobile-first também ficou frouxo: 6 `sm:`, 16 `md:`, **um único** `lg:`.

## A lição, que generaliza

Este arquivo é a versão visível de um padrão que o resto do repositório documenta em código: **modelo local acerta a forma e perde o detalhe.**

Cinco diretrizes viraram cinco seções estruturalmente corretas e duas cumpridas de fato. Nada quebrou, nada deu erro, nenhum aviso — só ficou genérico exatamente onde o prompt foi específico. É o mesmo erro do `cache.py` em [benchmarks](../../docs/benchmarks.md#teste-de-feature-quando-o-benchmark-e-a-entrega-discordam), onde o modelo usou `time.time()` em vez de `time.monotonic()`: passa, funciona, e está sutilmente aquém.

A diferença é que aqui dá para ver.

**Uso apropriado:** rascunho, protótipo, primeira versão que você vai revisar. **Uso inapropriado:** qualquer coisa que saia daqui sem alguém olhar.

## Reproduzindo

```powershell
# na maquina com a GPU
.\windows\llm-server.ps1 start moe -Lan
```

```bash
# de qualquer maquina da rede
curl -s -X POST http://192.168.3.51:8080/v1/chat/completions \
  -H 'Content-Type: application/json' -H 'Authorization: Bearer local' \
  -d "$(jq -Rs '{model:"moe",messages:[{role:"user",content:.}],max_tokens:8000,temperature:0.3}' \
        examples/landing-page/prompt.txt)"
```

O `max_tokens` importa: a saída passou de 7.400 tokens. Com o padrão de 4.096 que os clientes costumam usar, isso trunca no meio do HTML — e o corte não avisa, só chega `finish_reason: length`.
