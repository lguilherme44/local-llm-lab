<template>
  <div class="wrap">
    <!-- Cabeçalho -->
    <section>
      <p class="breadcrumb">
        <router-link to="/">Início</router-link>
        <svg viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
          <path d="M4.5 2.5L8 6l-3.5 3.5" />
        </svg>
        Produtos
      </p>
      <div class="page-head">
        <div>
          <h1>Produtos</h1>
          <p>
            O catálogo é da rede. Preço, estoque e limite de compra são da
            <strong>oferta</strong> — cada loja tem os seus — e por isso não
            estão nesta tela.
          </p>
        </div>
        <button class="btn btn-primary" type="button">
          <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
            <path d="M8 3.5v9M3.5 8h9" />
          </svg>
          Cadastrar produto
        </button>
      </div>
    </section>

    <!-- Aviso de unidade problemática -->
    <section class="notice" data-kind="failure">
      <strong>2 produtos precisam de unidade de medida</strong>
      <p>
        Sem unidade válida o produto não sabe se é vendido por unidade ou por
        quilo, e gramatura e tipo de corte ficam sem sentido.
      </p>
      <ul>
        <li><strong>Item Sem Unidade</strong> — Sem unidade</li>
        <li><strong>Suco de Uva Integral 1L</strong> — Unidade desconhecida (valor gravado: <code>LT</code>)</li>
      </ul>
    </section>

    <!-- Resultado do lote -->
    <section class="notice" id="batch" :data-kind="batchKind" role="status" aria-live="polite" v-if="batchText" :hidden="!batchText">
      <strong>{{ batchTitle }}</strong>
      <p>{{ batchText }}</p>
    </section>

    <!-- Tabela de produtos -->
    <section class="card">
      <div class="card-head">
        <div>
          <h2>{{ products.length }} produtos no catálogo</h2>
          <p>
            Selecione produtos para ativar ou desativar em lote. A operação é
            <strong>uma chamada só e atômica</strong>: ou vale para todos, ou não
            vale para nenhum. Se falhar, a mensagem diz que nada mudou e
            <strong>nomeia</strong> os produtos — nunca o índice deles na página.
          </p>
        </div>
      </div>

      <!-- Barra de lote -->
      <div class="bulk">
        <button class="btn btn-secondary" type="button" :disabled="selectedIds.size === 0" @click="activateSelected">
          Ativar selecionados
        </button>
        <button class="btn btn-ghost" type="button" :disabled="selectedIds.size === 0" @click="deactivateSelected">
          Desativar selecionados
        </button>
        <span class="bulk-count">{{ bulkCountText }}</span>
      </div>

      <!-- Tabela -->
      <div class="tablewrap">
        <table>
          <caption class="sr">Produtos do catálogo, com código de barras, unidade de medida, categorias, imagem e situação</caption>
          <thead>
            <tr>
              <th scope="col"><span class="sr">Selecionar</span></th>
              <th scope="col">Produto</th>
              <th scope="col">Código de barras</th>
              <th scope="col">
                <button class="sortbtn" type="button" :data-key="'unit'" :data-dir="sortKey === 'unit' ? sortDir : ''" @click="sortBy('unit')">
                  Unidade
                  <svg class="sortmark" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
                    <path d="M2.5 4.5L6 8l3.5-3.5" />
                  </svg>
                </button>
              </th>
              <th scope="col" class="c-num">Categorias</th>
              <th scope="col">Imagem</th>
              <th scope="col">Situação</th>
              <th scope="col"><span class="sr">Ações</span></th>
            </tr>
          </thead>
          <tbody>
            <tr
              v-for="product in sortedProducts"
              :key="product.id"
              :data-id="product.id"
              :data-active="product.active ? '1' : '0'"
            >
              <td class="c-sel">
                <label class="check check--cell">
                  <input type="checkbox" :data-pick="product.id" :aria-label="'Selecionar ' + product.name" :checked="selectedIds.has(product.id)" @change="toggleSelect(product.id)" />
                </label>
              </td>
              <td class="c-name">
                <button class="rowbtn" type="button" :aria-label="'Editar ' + product.name">
                  <b>{{ product.name }}</b>
                  <span>{{ product.subtitle }}</span>
                </button>
              </td>
              <td><span class="num">{{ product.sku }}</span></td>
              <td>
                <template v-if="product.unitIssue">
                  <span class="plate" :data-sev="product.unitIssue.sev">{{ product.unitIssue.label }}</span>
                  <code v-if="product.unitIssue.raw" class="raw">{{ product.unitIssue.raw }}</code>
                </template>
                <template v-else>
                  <span class="type">{{ product.unitType }}</span>
                  <span v-if="product.weighable" class="tag">pesável</span>
                </template>
              </td>
              <td class="c-num">
                <template v-if="product.catIssue">
                  <span class="plate" data-sev="atencao">{{ product.catIssue }}</span>
                </template>
                <template v-else>
                  <span class="c-num">{{ product.categoriesCount }}</span>
                </template>
              </td>
              <td><span class="tag" :data-off="!product.hasImage">{{ product.hasImage ? 'Sim' : 'Não' }}</span></td>
              <td>
                <span class="state" :data-on="String(product.active)">{{ product.active ? 'Ativo' : 'Inativo' }}</span>
              </td>
              <td><button class="linkbtn" type="button">Editar</button></td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="foot">
        <label class="check">
          <input type="checkbox" id="pick-all" :checked="allSelected" :indeterminate="indeterminate" @change="toggleAll" />
          Selecionar todos os {{ products.length }} produtos da lista
        </label>
        <p><strong>Quilo</strong> habilita gramatura e tipo de corte; <strong>Unidade</strong> não.</p>
      </div>
    </section>

    <!-- Colunas ausentes -->
    <section>
      <div class="card-head" style="border-block-end:0;padding-inline:0;padding-block-start:0;">
        <div>
          <h2>Três colunas que não existem aqui</h2>
          <p>
            Cada ausência tem evidência medida no painel legado. Sem este texto
            alguém readiciona a coluna, e o erro de modelagem volta com ela.
          </p>
        </div>
      </div>
      <div class="absent">
        <div class="absent-item">
          <b><s>Preço</s> <code>PRD-01</code></b>
          <p>
            A listagem legada mostra três colunas de preço e nenhuma é editável.
            Preço não é do produto: é da oferta <code>(produto, loja)</code>.
            Mostrá-lo aqui exigiria escolher uma loja em silêncio.
          </p>
        </div>
        <div class="absent-item">
          <b><s>Estoque</s> <code>PRD-02 · PRD-11</code></b>
          <p>
            Mesma razão — a unicidade é <code>(product, company)</code>. E a
            coluna do legado ordena no cliente sobre uma página só, o que faz a
            ordenação <strong>parecer</strong> global sem ser.
          </p>
        </div>
        <div class="absent-item">
          <b><s>Limite de compra</s> <code>PRD-03</code></b>
          <p>
            É da oferta, disfarçado de produto no legado. Um campo que pertence a
            outro dono não vira coluna aqui só porque estava na tela antiga.
          </p>
        </div>
      </div>
    </section>
  </div>
</template>

<script setup lang="ts">
import { ref, computed } from 'vue'

// ── Tipos ────────────────────────────────────────────────────────────────
interface Product {
  id: string
  name: string
  subtitle: string
  sku: string
  unitType: string
  weighable: boolean
  unitIssue?: { label: string; sev: string; raw?: string }
  categoriesCount: number
  catIssue?: string
  hasImage: boolean
  active: boolean
}

// ── Dados (fixtures do protótipo) ────────────────────────────────────────
const products = ref<Product[]>([
  {
    id: 'sem-unidade',
    name: 'Item Sem Unidade',
    subtitle: 'item-sem-unidade',
    sku: '7891000100103',
    unitType: '',
    weighable: false,
    unitIssue: { label: 'Sem unidade', sev: 'grave' },
    categoriesCount: 0,
    catIssue: 'sem categoria',
    hasImage: false,
    active: true,
  },
  {
    id: 'unidade-morta',
    name: 'Suco de Uva Integral 1L',
    subtitle: 'Suco Uva 1L · suco-de-uva-integral-1l',
    sku: '7896005800027',
    unitType: '',
    weighable: false,
    unitIssue: { label: 'Unidade desconhecida', sev: 'grave', raw: 'LT' },
    categoriesCount: 1,
    hasImage: false,
    active: true,
  },
  {
    id: 'picanha',
    name: 'Picanha Bovina Resfriada',
    subtitle: 'Picanha · picanha-bovina-resfriada',
    sku: '2000000000015',
    unitType: 'Quilo',
    weighable: true,
    categoriesCount: 1,
    hasImage: true,
    active: true,
  },
  {
    id: 'queijo-minas',
    name: 'Queijo Minas Frescal',
    subtitle: 'Queijo Minas · queijo-minas-frescal',
    sku: '2000000000022',
    unitType: 'Quilo',
    weighable: true,
    categoriesCount: 1,
    hasImage: false,
    active: false,
  },
  {
    id: 'cafe-3coracoes',
    name: 'Café 3 Corações Tradicional 500g',
    subtitle: 'Café 3C Trad 500g · cafe-3coracoes-tradicional-500g',
    sku: '7896005800010',
    unitType: 'Unidade',
    weighable: false,
    categoriesCount: 1,
    hasImage: true,
    active: true,
  },
  {
    id: 'interno-42',
    name: 'Marmita da Casa',
    subtitle: 'Marmita · marmita-da-casa',
    sku: '42',
    unitType: 'Unidade',
    weighable: false,
    categoriesCount: 0,
    catIssue: 'sem categoria',
    hasImage: false,
    active: true,
  },
])

// ── Seleção em lote ──────────────────────────────────────────────────────
const selectedIds = ref<Set<string>>(new Set())

const allSelected = computed(() => selectedIds.value.size === products.value.length && products.value.length > 0)
const indeterminate = computed(() => selectedIds.value.size > 0 && selectedIds.value.size < products.value.length)

function toggleSelect(id: string) {
  const s = selectedIds.value
  if (s.has(id)) s.delete(id)
  else s.add(id)
  selectedIds.value = s
}

function toggleAll(event: Event) {
  const target = event.target as HTMLInputElement
  const s = new Set<string>()
  if (target.checked || target.indeterminate) {
    // Only check when actually checked (indeterminate is a visual state)
    products.value.forEach((p) => s.add(p.id))
  }
  selectedIds.value = s
}

// ── Estado do lote (batch notice) ────────────────────────────────────────
const batchTitle = ref('')
const batchText = ref('')

function showBatch(title: string, text: string) {
  batchTitle.value = title
  batchText.value = text
}

function activateSelected() {
  const activeProducts = products.value.filter((p) => p.active)
  const inactiveSelected = products.value.filter((p) => p.id && selectedIds.value.has(p.id) && !p.active)

  inactiveSelected.forEach((p) => { p.active = true })

  const names = inactiveSelected.map((p) => p.name).join(', ')
  if (names) {
    showBatch(
      `${names} ${inactiveSelected.length === 1 ? 'foi' : 'foram'} ativados.`,
      `A ação ${inactiveSelected.length === 1 ? 'incluiu' : 'incluem'} ${activeProducts.length - inactiveSelected.length + 1} ${activeProducts.length - inactiveSelected.length + 1 === 1 ? 'produto' : 'produtos'} ativos no total.`,
    )
  } else {
    showBatch(
      'Nenhuma alteração necessária.',
      'Os produtos já estavam todos ativos.',
    )
  }
}

function deactivateSelected() {
  const activeSelected = products.value.filter((p) => p.id && selectedIds.value.has(p.id) && p.active)

  activeSelected.forEach((p) => { p.active = false })

  const names = activeSelected.map((p) => p.name).join(', ')
  if (names) {
    showBatch(
      `${names} ${activeSelected.length === 1 ? 'foi' : 'foram'} desativados.`,
      `A ação ${activeSelected.length === 1 ? 'deixou' : 'deixam'} ${products.value.filter((p) => p.active).length} ${products.value.filter((p) => p.active).length === 1 ? 'produto' : 'produtos'} ativos no total.`,
    )
  } else {
    showBatch(
      'Nenhuma alteração necessária.',
      'Os produtos já estavam todos inativos.',
    )
  }
}

const batchKind = computed(() => batchText.value && batchText.value.includes('Nenhuma alteração') ? 'warning' : 'success')

const bulkCountText = computed(() => {
  const n = selectedIds.value.size
  if (n === 0) return 'Nenhum produto selecionado.'
  return n + (n === 1 ? ' produto selecionado.' : ' produtos selecionados.')
})

// ── Ordenação simples ────────────────────────────────────────────────────
type SortKey = 'unit'
type SortDir = 'asc' | 'desc' | ''

const sortKey = ref<SortKey>('unit')
const sortDir = ref<SortDir>('asc')

function sortBy(key: SortKey) {
  if (sortKey.value === key) {
    sortDir.value = sortDir.value === 'asc' ? 'desc' : sortDir.value === 'desc' ? '' : 'asc'
  } else {
    sortKey.value = key
    sortDir.value = 'asc'
  }
}

// Computed sorted products (stable sort by current sort direction)
const sortedProducts = computed(() => {
  if (sortDir.value === '') return products.value
  const dir = sortDir.value === 'asc' ? 1 : -1
  return [...products.value].sort((a, b) => {
    return a.unitType.localeCompare(b.unitType, 'pt-BR') * dir
  })
})

// ── Reatividade do indeterminate (Vue não reage a property nativa) ────
// O HTML <input> usa o atributo :indeterminate para o estado visual
// e o event handler lida com o toggle
</script>
