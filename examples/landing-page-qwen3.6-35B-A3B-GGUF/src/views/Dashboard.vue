<template>
  <div class="wrap">
    <!-- Cabeçalho -->
    <section class="head">
      <div>
        <h1>Início</h1>
        <p>
          Esta tela mostra o que precisa de decisão humana. Cada linha abaixo é
          uma ocorrência real nos dados carregados, com o registro nomeado — não
          há indicador agregado sem registro por trás.
        </p>
      </div>
      <p class="source">
        <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
          <ellipse cx="8" cy="4" rx="5.25" ry="2.25"/>
          <path d="M2.75 4v8c0 1.24 2.35 2.25 5.25 2.25s5.25-1.01 5.25-2.25V4"/>
          <path d="M2.75 8c0 1.24 2.35 2.25 5.25 2.25s5.25-1.01 5.25-2.25"/>
        </svg>
        Fixture local · <code>stores.ts</code> e <code>products.ts</code>
      </p>
    </section>

    <!-- Cobertura por área -->
    <section class="card">
      <div class="card-head">
        <div>
          <h2>Cobertura por área</h2>
          <p>
            Conta <b>registro distinto</b>, não ocorrência. O Depósito Vila Nova
            tem dois problemas e continua sendo uma loja só — contar ocorrência
            passaria de 100%.
          </p>
        </div>
      </div>
      <div class="card-body">
        <div class="cov-grid">
          <div>
            <div class="cov-head">
              <span class="cov-name">Lojas</span>
              <span class="cov-frac">4<small> de 6</small></span>
            </div>
            <div class="cov-track" role="img" aria-label="4 de 6 lojas sem pendência de configuração">
              <div class="cov-fill" :style="{ inlineSize: '66.7%' }"></div>
            </div>
            <p class="cov-note"><b>2 lojas</b> com pendência: Depósito Vila Nova e Vila Nova Osasco.</p>
          </div>

          <div>
            <div class="cov-head">
              <span class="cov-name">Produtos</span>
              <span class="cov-frac">3<small> de 6</small></span>
            </div>
            <div class="cov-track" role="img" aria-label="3 de 6 produtos sem pendência de cadastro">
              <div class="cov-fill" :style="{ inlineSize: '50%' }"></div>
            </div>
            <p class="cov-note"><b>3 produtos</b> com pendência: Marmita da Casa, Item Sem Unidade e Suco de Uva Integral 1L.</p>
          </div>

          <div class="cov-none">
            <svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
              <circle cx="10" cy="10" r="7.25"/>
              <path d="M10 6.5v.01M10 9.5v4"/>
            </svg>
            <p>
              <b>Seções (9) e categorias (11) ficam fora desta conta.</b>
              Bazar e Importados estão inativas, e inativa é decisão comercial —
              não pendência. Sem um sinal de pendência definido, esta área não
              recebe barra: dizer "100% saudável" sem registro verificado é pior
              que não dizer nada.
            </p>
          </div>
        </div>
      </div>
    </section>

    <!-- Seções oferecidas por loja (gráfico de barras) -->
    <section class="card">
      <div class="card-head">
        <div>
          <h2>Seções oferecidas, por loja</h2>
          <p>
            A lista acima diz que <b>1 loja não oferece nada</b>. O gráfico diz
            outra coisa que a contagem não carrega: o Osasco oferece uma seção
            só e não está sinalizado. Ordenado da maior para a menor.
          </p>
        </div>
      </div>
      <div class="card-body">
        <div class="chart">
          <button
            v-for="item in chartData"
            :key="item.id"
            class="bar-row"
            type="button"
            :data-tip="item.tip"
            @mouseenter="showTip($event, item)"
            @mouseleave="hideTip"
            @focus="showTip($event, item)"
            @blur="hideTip"
          >
            <span class="bar-name">{{ item.name }}</span>
            <span class="bar-track">
              <span class="bar-fill" :style="{ inlineSize: item.pct + '%' }"></span>
              <span v-if="item.value === 0" class="bar-zero"></span>
            </span>
            <span class="bar-val" :data-zero="item.value === 0">{{ item.value }}</span>
          </button>
        </div>

        <p class="chart-scale">
          Escala <b>0 a 4 seções</b>. A barra cheia é a loja com mais seções da
          rede — não é um alvo: a taxonomia tem 9 seções, e farmácia nunca vai
          oferecer Carnes.
        </p>

        <details class="tableview">
          <summary>Ver como tabela</summary>
          <table>
            <caption class="sr">Seções e categorias oferecidas por loja</caption>
            <thead>
              <tr>
                <th scope="col">Loja</th>
                <th scope="col">Seções</th>
                <th scope="col">Categorias</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="item in chartData" :key="item.id">
                <td>{{ item.name }}</td>
                <td class="n">{{ item.value }}</td>
                <td class="n">{{ item.categories }}</td>
              </tr>
            </tbody>
          </table>
        </details>
      </div>
    </section>

    <!-- O que precisa de atenção -->
    <section class="card">
      <div class="card-head">
        <div>
          <h2>O que precisa de atenção</h2>
          <p>
            Oito sinais, oito ocorrências medidas. Abra a linha para ver os
            registros afetados. O sinal com zero ocorrência continua na lista:
            fazer a linha desaparecer tornaria "não há" indistinguível de
            "ninguém verificou".
          </p>
        </div>
        <div class="chips" role="group" aria-label="Filtrar sinais por área">
          <button
            v-for="chip in filterChips"
            :key="chip.value"
            class="chip"
            type="button"
            :aria-pressed="filter === chip.value"
            @click="filter = chip.value"
          >
            {{ chip.label }} <b>{{ chip.count }}</b>
          </button>
        </div>
      </div>

      <div class="card-body">
        <div class="signals">
          <details
            v-for="signal in filteredSignals"
            :key="signal.id"
            class="signal"
            :data-area="signal.area"
          >
            <summary>
              <span
                class="plate"
                :data-sev="signal.severity"
              >{{ signal.severityLabel }}</span>
              <span class="signal-n">{{ signal.count }}</span>
              <span class="signal-text">
                <b>{{ signal.title }}</b>
                <span>{{ signal.description }}</span>
              </span>
              <svg class="signal-chev" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
                <path d="M6 3.5l5 4.5-5 4.5" />
              </svg>
            </summary>
            <div class="signal-body">
              <template v-if="signal.records && signal.records.length">
                <div v-for="rec in signal.records" :key="rec.id" class="rec">
                  <b>{{ rec.name }}</b>
                  <code>{{ rec.id }}</code>
                  <span>{{ rec.note }}</span>
                  <a v-if="rec.link" :href="rec.link" target="_blank" rel="noopener">Abrir loja</a>
                </div>
              </template>
              <p v-else class="signal-empty">
                <b>Nenhuma ocorrência.</b> Bazar e Importados são as duas
                inativas, e nenhuma das seis lojas as referencia. Esta linha
                existe justamente para provar que a verificação rodou.
              </p>
            </div>
          </details>
        </div>
      </div>
    </section>

    <!-- Áreas do painel -->
    <section>
      <div class="areas">
        <router-link class="area" to="/lojas">
          <span class="area-name">Lojas</span>
          <span class="area-n">6<small>cadastradas</small></span>
          <span class="area-state" data-sev="grave">2 com pendência de configuração</span>
          <span class="area-go">Abrir lista
            <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
              <path d="M3 8h9M8.5 4.5L12 8l-3.5 3.5" />
            </svg>
          </span>
        </router-link>

        <router-link class="area" to="/produtos">
          <span class="area-name">Produtos</span>
          <span class="area-n">6<small>cadastrados</small></span>
          <span class="area-state" data-sev="grave">3 com pendência de cadastro</span>
          <span class="area-go">Abrir catálogo
            <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
              <path d="M3 8h9M8.5 4.5L12 8l-3.5 3.5" />
            </svg>
          </span>
        </router-link>

        <router-link class="area" to="/taxonomia#secoes">
          <span class="area-name">Seções</span>
          <span class="area-n">9<small>1 inativa</small></span>
          <span class="area-state">Sem sinal de pendência definido</span>
          <span class="area-go">Abrir seções
            <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
              <path d="M3 8h9M8.5 4.5L12 8l-3.5 3.5" />
            </svg>
          </span>
        </router-link>

        <router-link class="area" to="/taxonomia#categorias">
          <span class="area-name">Categorias</span>
          <span class="area-n">11<small>1 inativa</small></span>
          <span class="area-state">Sem sinal de pendência definido</span>
          <span class="area-go">Abrir categorias
            <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
              <path d="M3 8h9M8.5 4.5L12 8l-3.5 3.5" />
            </svg>
          </span>
        </router-link>
      </div>
    </section>

    <!-- Tooltip global -->
    <div class="tip" ref="tipRef" role="status" aria-live="polite"></div>
  </div>
</template>

<script setup lang="ts">
import { ref, computed } from 'vue'

// ── Dados do gráfico de barras ───────────────────────────────────────────
interface ChartItem {
  id: string
  name: string
  value: number
  categories: number
  pct: number
  tip: string
}

const chartData: ChartItem[] = [
  { id: 'centro', name: 'Vila Nova Centro', value: 4, categories: 5, pct: 100, tip: 'Vila Nova Centro · 5 categorias · loja alimentícia ativa' },
  { id: 'pinheiros', name: 'Vila Nova Pinheiros', value: 3, categories: 4, pct: 75, tip: 'Vila Nova Pinheiros · 4 categorias · loja alimentícia ativa' },
  { id: 'farmacia', name: 'Vila Nova Farma Centro', value: 3, categories: 3, pct: 75, tip: 'Vila Nova Farma Centro · 3 categorias · farmácia ativa' },
  { id: 'petshop', name: 'Vila Nova Pet Santo André', value: 2, categories: 2, pct: 50, tip: 'Vila Nova Pet Santo André · 2 categorias · petshop inativa' },
  { id: 'osasco', name: 'Vila Nova Osasco', value: 1, categories: 1, pct: 25, tip: 'Vila Nova Osasco · 1 categoria · tipo fora do contrato, e ativa' },
  { id: 'deposito', name: 'Depósito Vila Nova', value: 0, categories: 0, pct: 0, tip: 'Depósito Vila Nova · 0 categorias · sem tipo definido, e inativa' },
]

// ── Sinais de atenção ───────────────────────────────────────────────────
interface SignalRecord {
  id: string
  name: string
  note: string
  link?: string
}

interface Signal {
  id: string
  severity: 'grave' | 'atencao' | 'ok'
  severityLabel: string
  count: number
  title: string
  description: string
  area: 'lojas' | 'produtos'
  records: SignalRecord[] | null
}

const signals: Signal[] = [
  {
    id: 'loja-sem-tipo',
    severity: 'grave',
    severityLabel: 'Grave',
    count: 1,
    title: 'Loja sem tipo definido',
    description: 'Sem tipo, a plataforma não decide quais capacidades a loja tem.',
    area: 'lojas',
    records: [
      { id: 'deposito', name: 'Depósito Vila Nova', note: 'Campo type gravado como string vazia.', link: '/lojas#deposito' },
    ],
  },
  {
    id: 'loja-tipo-desconhecido',
    severity: 'grave',
    severityLabel: 'Grave',
    count: 1,
    title: 'Loja com tipo fora do contrato',
    description: 'O contrato aceita alimentício, farmácia e petshop. Nada mais.',
    area: 'lojas',
    records: [
      { id: 'import-2019', name: 'Vila Nova Osasco', note: 'Gravada como "mercearia", valor de integração antiga. É desconhecido, não ausente — e pede outra mensagem.', link: '/lojas#import-2019' },
    ],
  },
  {
    id: 'loja-sem-oferta',
    severity: 'atencao',
    severityLabel: 'Atenção',
    count: 1,
    title: 'Loja que não oferece nada',
    description: 'Zero seções e zero categorias: a vitrine abriria vazia.',
    area: 'lojas',
    records: [
      { id: 'deposito', name: 'Depósito Vila Nova', note: 'Nenhuma seção e nenhuma categoria atribuída. Está inativa, o que contém o dano — mas ativar sem configurar publica uma loja vazia.', link: '/lojas#deposito' },
    ],
  },
  {
    id: 'loja-item-desativado',
    severity: 'ok',
    severityLabel: 'Verificado',
    count: 0,
    title: 'Loja que oferece item desativado',
    description: 'Seção ou categoria desligada continuando na vitrine.',
    area: 'lojas',
    records: null,
  },
  {
    id: 'produto-sem-unidade',
    severity: 'grave',
    severityLabel: 'Grave',
    count: 1,
    title: 'Produto sem unidade de medida',
    description: 'Sem unidade não há como precificar nem exibir gramatura.',
    area: 'produtos',
    records: [
      { id: 'sem-unidade', name: 'Item Sem Unidade', note: 'Campo unitMeasure vazio — e ainda assim o produto tem gramaturas cadastradas, o que é contraditório.' },
    ],
  },
  {
    id: 'produto-unidade-desconhecida',
    severity: 'grave',
    severityLabel: 'Grave',
    count: 1,
    title: 'Produto com unidade fora do contrato',
    description: 'A plataforma conhece UN e KG.',
    area: 'produtos',
    records: [
      { id: 'unidade-morta', name: 'Suco de Uva Integral 1L', note: 'Unidade LT, que a plataforma não resolve.' },
    ],
  },
  {
    id: 'produto-categoria-inexistente',
    severity: 'grave',
    severityLabel: 'Grave',
    count: 1,
    title: 'Produto apontando para categoria inexistente',
    description: 'Referência que não resolve na taxonomia.',
    area: 'produtos',
    records: [
      { id: 'unidade-morta', name: 'Suco de Uva Integral 1L', note: 'Categoria bebidas — que é seção, não categoria. A categoria de suco existe e tem id sucos. O produto aponta para o registro errado.' },
    ],
  },
  {
    id: 'produto-sem-categoria',
    severity: 'atencao',
    severityLabel: 'Atenção',
    count: 2,
    title: 'Produto sem categoria',
    description: 'Não aparece em navegação por categoria — só na busca.',
    area: 'produtos',
    records: [
      { id: 'interno-42', name: 'Marmita da Casa', note: 'Nenhuma categoria atribuída.' },
      { id: 'sem-unidade', name: 'Item Sem Unidade', note: 'Nenhuma categoria atribuída — este registro acumula duas pendências e continua contando como um.' },
    ],
  },
]

const filterChips: Array<{ value: 'all' | 'lojas' | 'produtos', label: string, count: number }> = [
  { value: 'all', label: 'Todos', count: 8 },
  { value: 'lojas', label: 'Lojas', count: 4 },
  { value: 'produtos', label: 'Produtos', count: 4 },
]

const filter = ref<'all' | 'lojas' | 'produtos'>('all')

const filteredSignals = computed(() => {
  if (filter.value === 'all') return signals
  return signals.filter((s) => s.area === filter.value)
})

// ── Tooltip do gráfico ──────────────────────────────────────────────────
const tipRef = ref<HTMLElement | null>(null)

function showTip(event: Event, item: ChartItem) {
  if (!tipRef.value) return
  const target = event.target as HTMLElement
  const box = target.getBoundingClientRect()
  const value = String(item.value)
  const unit = item.value === 1 ? ' seção' : ' seções'

  tipRef.value.innerHTML = ''
  const strong = document.createElement('b')
  strong.textContent = value + unit
  const note = document.createElement('span')
  note.textContent = item.tip
  tipRef.value.appendChild(strong)
  tipRef.value.appendChild(note)
  tipRef.value.dataset.open = 'true'

  const w = tipRef.value.offsetWidth
  const h = tipRef.value.offsetHeight
  const left = Math.min(box.left + 24, window.innerWidth - w - 12)
  const top = box.top - h - 8
  tipRef.value.style.left = Math.max(12, left) + 'px'
  tipRef.value.style.top = (top < 8 ? box.bottom + 8 : top) + 'px'
  tipRef.value.setAttribute('aria-label', item.name + ': ' + value)
}

function hideTip() {
  if (tipRef.value) tipRef.value.dataset.open = 'false'
}

window.addEventListener('scroll', hideTip, true)
</script>
