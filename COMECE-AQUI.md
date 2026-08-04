# Comece aqui

Explicação sem jargão do que este projeto é, o que descobrimos e como usar.

Se você é a pessoa que construiu isto e só quer o estado técnico, vá para
[`STATUS.md`](STATUS.md).

---

## O que é este projeto

Uma investigação prática: **dá para programar usando um modelo de IA rodando na sua própria
máquina, de graça, sem mandar código para a nuvem?**

A máquina de teste é um PC comum com uma placa de vídeo NVIDIA de 8 GB. Nada de servidor caro.

## A resposta curta

**Dá, com uma condição:** você precisa dizer *o que* fazer. Ele executa bem; ele não descobre bem.

Pense num profissional recém-formado, muito rápido e sem preguiça, que nunca viu o seu sistema.
Peça "implemente esta correção assim" e ele entrega. Peça "descubra por que isso está quebrado" e
ele se perde.

---

## Os quatro conceitos que explicam tudo

Você não precisa de mais que estes.

### 1. O modelo tem que "caber" na placa de vídeo

A placa tem 8 GB de memória. Se o modelo não cabe, o resto vai para a memória do computador, que é
**muito** mais lenta.

Medimos dois modelos de tamanho de arquivo praticamente igual:

| modelo | velocidade |
|---|---|
| um que aproveita a placa | 37 palavras por segundo |
| um que não cabe | 3 palavras por segundo |

**Doze vezes mais lento.** Não é ajuste de configuração, é física: a placa fica esperando.

### 2. "MoE" é o truque que faz um modelo grande caber

Modelo comum: para escrever cada palavra, ele usa *todo* o seu conhecimento. Modelo MoE: ele tem
vários especialistas e consulta só os relevantes para cada palavra.

O efeito prático é que um modelo MoE **grande** pode rodar rápido numa placa **pequena**, porque
consulta pouca coisa por vez. É por isso que o modelo escolhido tem 35 bilhões de parâmetros e
roda melhor que um de 27 bilhões.

### 3. Existe o "backend", e usar o errado custa 10× de velocidade

O backend é o motor que conversa com a placa de vídeo. A NVIDIA tem um motor próprio (CUDA) que é
muito mais rápido que o genérico.

O projeto estava usando o genérico **enquanto se descrevia como usando o da NVIDIA**. Resultado: a
placa ficava 82% do tempo parada. Corrigido.

### 4. O modelo "pensa em voz alta", e isso consome a cota

Alguns modelos escrevem o raciocínio antes de responder. Esse texto conta na cota de resposta, mas
não aparece para você.

Medimos: pedindo *"responda apenas: ok"*, o modelo gastou **100% da cota pensando** e produziu zero
resposta. Era isso que fazia páginas HTML saírem cortadas no meio.

Decisão: **desligado**. Testamos com e sem — sem ele o resultado é melhor, mais rápido e usa 7 a 20
vezes menos cota.

---

## Como usar, na prática

### Ligar o modelo

No PC Linux:

```bash
./linux/llm-server.sh start moe --lan
```

`moe` é o modelo escolhido. `--lan` libera acesso de outros computadores da casa — **sem isso só
funciona no próprio PC**, e o erro que aparece é um confuso "Connection error".

Para desligar e liberar a memória:

```bash
./linux/llm-server.sh stop
```

### Usar para programar

Qualquer ferramenta de IA para código que aceite "servidor personalizado" funciona. O Cline (uma
extensão do VS Code) foi o que testamos.

Configure o endereço como `http://<ip-do-pc>:8080/v1` e a chave como `local`.

### Verificar se está bom

O projeto tem testes automáticos que dão nota ao modelo:

```bash
python3 scripts/run_benchmark.py moe          # testes rápidos
python3 scripts/bench_agentic.py --listar     # testes com bugs reais
```

---

## O que descobrimos, e é a parte interessante

### Medir é mais difícil que fazer

A primeira suíte de testes deste projeto dava nota **8,6 de 10** para um arquivo HTML cortado no
meio de uma tag — porque conferia se certas palavras apareciam no texto, não se o arquivo
funcionava.

O relatório antigo dizia literalmente *"Nenhum problema detectado"* para saídas quebradas.

A suíte nova usa um critério que não admite interpretação: **o teste automatizado passou ou não
passou?** Verde ou vermelho.

### Velocidade não prediz utilidade

Dois modelos, mesma tarefa:

| modelo | velocidade | resolveu? |
|---|---|---|
| menor | 74 palavras/s | **não** |
| maior | 37 palavras/s | **sim** |

O rápido, ao adicionar um método a uma classe, **apagou um método que já existia.** O código
ficava sintaticamente perfeito e quebrado.

### Bug fácil ele resolve; bug difícil, não

Testamos com bugs reais, tirados do histórico do sistema de barbearias do autor.

| bug | o que era | acertou? |
|---|---|---|
| produto indisponível sendo vendido | faltava uma verificação exatamente onde o produto é buscado | **3 de 3** |
| agendamento de meia-noite desaparecendo | causa num lugar, consequência em outro | **1 de 5** |

A diferença não é dificuldade de escrever código — é **distância entre o sintoma e a causa**.

No segundo bug ele até acertou a causa, e perdeu a consequência. Foi como consertar o vazamento e
não perceber que o carpete precisava secar.

### Mas dando o plano, ele acerta

O mesmo bug difícil, com um plano escrito antes:

| | sem plano | com plano |
|---|---|---|
| acertou | 1 de 5 | **5 de 5** |
| cota usada | 10.000 | **2.300** |

**Menos de um quarto do consumo, e cinco vezes mais acerto.** O plano não só faz ele acertar — faz
ele parar de tentar às cegas.

Isso é a base da pipeline descrita em [`docs/pipeline-modelos.md`](docs/pipeline-modelos.md): um
modelo caro escreve o plano, o local grátis executa.

### E o mais importante: ele diz que terminou quando não terminou

Em 3 de 5 tentativas do bug difícil, ele **anunciou que havia corrigido** com o teste ainda
vermelho.

Não é má-fé — ele não sabe que errou. Mas a consequência é séria: **se você acreditar no que ele
diz, recebe um bug com aparência de tarefa concluída.**

É por isso que toda automação aqui roda o teste depois e ignora o que o modelo afirma.

---

## Uma lição sobre confiar em números

Durante esta investigação, **seis medições diferentes estavam erradas** — e todas pelo mesmo
motivo: mediam a ferramenta de medição, não o modelo.

Alguns exemplos:

- A velocidade estava 25% superestimada porque contávamos palavras por divisão aproximada, em vez
  de perguntar ao servidor o número exato.
- Um teste dava "0 de 3" porque a ferramenta de listar arquivos estava quebrada e o modelo ficava
  **cego** — nunca chegou a tentar.
- Outro dava erro de servidor porque a única ferramenta oferecida exigia reescrever o arquivo
  inteiro, e o arquivo era grande demais para caber na resposta.

O sinal que revelou os dois últimos não foi a nota. Foi olhar **o que o modelo tentou fazer**: num
caso ele nunca editou nada, no outro a requisição morria sempre no mesmo ponto.

A lição, que vale para qualquer medição: **antes de acreditar num número, pergunte o que nele pode
estar medindo o seu próprio aparato.**

---

## Onde está cada coisa

| arquivo | conteúdo |
|---|---|
| este | explicação sem jargão |
| [`README.md`](README.md) | visão geral técnica e comandos |
| [`STATUS.md`](STATUS.md) | estado atual e decisões já fechadas |
| [`docs/pipeline-modelos.md`](docs/pipeline-modelos.md) | como dividir trabalho entre modelos caros e grátis |
| [`docs/benchmarks.md`](docs/benchmarks.md) | todos os números medidos e o método |
| [`docs/diagnostico-linux-benchmark.md`](docs/diagnostico-linux-benchmark.md) | a investigação completa, com as hipóteses que caíram |
| [`TODO.md`](TODO.md) | o que falta fazer |
