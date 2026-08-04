# Plano pré-registrado — `product_unavailable` (beahub@d3372f6)

Escrito **antes** de rodar qualquer execução e **sem ler o diff do commit**, para testar a ponta
de cima da pipeline "modelo grande planeja, local executa".

## O que eu vi (e só isso)

Exatamente o que um planejador teria: a descrição do bug, o teste que falha, e o código.

1. **Assunto do commit:** *"impede vender produto indisponível no Caixa"*.
2. **O teste que falha**, `api/src/modules/sales/sales.service.spec.ts`:
   - chama `service.addItem(saleId, { kind: PRODUCT, productId }, tenantId)`
   - o mock devolve um produto que existe no tenant mas tem `available: false`
   - espera `rejects.toThrow('Produto indisponível para venda')`
   - espera `tx.saleItem.create` **não** ter sido chamado
3. **O código bugado**, `sales.service.ts`: `addItem` delega para `buildItemData`, que no ramo
   `PRODUCT` faz `tx.product.findFirst({ where: { id, tenantId } })`, lança se `!product`, e
   depois usa `product.name` e `product.price`. **Não há nenhuma checagem de `available`.**

Não abri `git show d3372f6` em momento algum.

## O plano

1. No `buildItemData`, ramo `PRODUCT`, depois de confirmar que o produto existe, rejeitar quando
   `available === false`, lançando `BadRequestException` com a mensagem exata
   `'Produto indisponível para venda'`.
2. A checagem vai no `buildItemData`, **não** no `addItem`. `buildItemData` é chamado de dois
   lugares (itens iniciais em `openSale` e `addItem`); colocar lá cobre os dois, e é a fonte de
   verdade única.
3. Lançar **antes** de qualquer `saleItem.create` — o teste verifica explicitamente que a criação
   não ocorreu. Como já está dentro da transação e antes do `create`, a ordem natural resolve.
4. Não mexer nos outros ramos: `SERVICE` não tem essa regra, e o teste de produto sem comissão
   precisa continuar passando.

## Predição registrada

Este bug é **local**: a checagem que falta fica exatamente onde o produto é buscado. Ao contrário
da `timeline_midnight`, não exige enxergar uma consequência distante.

Portanto **espero que o modelo resolva sem plano**. Se resolver, esta tarefa não testa a hipótese
do planejador — ela só confirma que bug local ele resolve sozinho.

O valor de planejador só apareceria num bug onde a evidência não aponta direto para a correção. É
por isso que a `timeline_midnight` foi um teste melhor da pipeline, e é por isso que o próximo
candidato precisa ser escolhido por essa propriedade, não por conveniência de fixture.

## Como ler o resultado

| sem plano | com plano | conclusão |
|---|---|---|
| passa | — | tarefa fácil; não diz nada sobre planejador |
| falha | passa | plano ajuda mesmo em bug local; e meu plano sem contaminação funcionou |
| falha | falha | ou meu plano é ruim, ou o gargalo aqui é execução |
