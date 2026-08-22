<template>
  <div class="wrap">
    <!-- Cabeçalho -->
    <section>
      <p class="breadcrumb">
        <router-link to="/">Início</router-link>
        <svg viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
          <path d="M4.5 2.5L8 6l-3.5 3.5" />
        </svg>
        Lojas
      </p>
      <div class="page-head">
        <div>
          <h1>Lojas</h1>
          <p>
            Seis lojas na rede. O tipo decide quais capacidades a loja tem, e é
            por isso que ele aparece antes de qualquer valor comercial na linha.
          </p>
        </div>
        <button class="btn btn-primary" type="button">
          <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
            <path d="M8 3.5v9M3.5 8h9" />
          </svg>
          Cadastrar loja
        </button>
      </div>
    </section>

    <!-- Card principal -->
    <section class="card">
      <!-- Barra de ferramentas -->
      <div class="tools">
        <label class="search">
          <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.75" aria-hidden="true">
            <circle cx="7" cy="7" r="4.25" />
            <path d="M10.25 10.25L13.5 13.5" />
          </svg>
          <span class="sr">Buscar loja por nome, bairro ou cidade</span>
          <input
            type="search"
            placeholder="Buscar por nome, bairro ou cidade"
            autocomplete="off"
            v-model="search"
          />
        </label>

        <span class="picker">
          <label for="tipo">Tipo</label>
          <select id="tipo" v-model="filterType">
            <option value="all">Todos</option>
            <option value="alimenticio">Alimentício (2)</option>
            <option value="farmacia">Farmácia (1)</option>
            <option value="petshop">Petshop (1)</option>
            <option value="missing">Sem tipo (1)</option>
            <option value="unknown">Tipo desconhecido (1)</option>
          </select>
        </span>

        <span class="chips" role="group" aria-label="Filtrar por situação">
          <button
            class="chip"
            type="button"
            :aria-pressed="status === 'all'"
            data-status="all"
            @click="status = 'all'"
          >
            Todas <b>6</b>
          </button>
          <button
            class="chip"
            type="button"
            :aria-pressed="status === 'on'"
            data-status="on"
            @click="status = 'on'"
          >
            Ativas <b>4</b>
          </button>
          <button
            class="chip"
            type="button"
            :aria-pressed="status === 'off'"
            data-status="off"
            @click="status = 'off'"
          >
            Inativas <b>2</b>
          </button>
        </span>

        <output class="count">{{ count }} de {{ total }} lojas</output>
      </div>

      <!-- Tabela -->
      <div class="tablewrap">
        <table>
          <caption class="sr">Lojas da rede Vila Nova, com tipo, condições de entrega e situação</caption>
          <thead>
            <tr>
              <th scope="col">
                <button
                  class="sortbtn"
                  type="button"
                  :data-key="'name'"
                  :data-dir="sortKey === 'name' ? sortDir : ''"
                  @click="sortBy('name')"
                >
                  Loja
                  <svg class="sortmark" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
                    <path d="M2.5 4.5L6 8l3.5-3.5" />
                  </svg>
                </button>
              </th>
              <th scope="col">
                <button class="sortbtn" type="button" :data-key="'typelabel'" :data-dir="sortKey === 'typelabel' ? sortDir : ''" @click="sortBy('typelabel')">
                  Tipo
                  <svg class="sortmark" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
                    <path d="M2.5 4.5L6 8l3.5-3.5" />
                  </svg>
                </button>
              </th>
              <th scope="col" class="c-num">
                <button class="sortbtn" type="button" :data-key="'fee'" :data-dir="sortKey === 'fee' ? sortDir : ''" @click="sortBy('fee')">
                  Entrega
                  <svg class="sortmark" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
                    <path d="M2.5 4.5L6 8l3.5-3.5" />
                  </svg>
                </button>
              </th>
              <th scope="col" class="c-num">
                <button class="sortbtn" type="button" :data-key="'min'" :data-dir="sortKey === 'min' ? sortDir : ''" @click="sortBy('min')">
                  Mínimo
                  <svg class="sortmark" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
                    <path d="M2.5 4.5L6 8l3.5-3.5" />
                  </svg>
                </button>
              </th>
              <th scope="col" class="c-num">
                <button class="sortbtn" type="button" :data-key="'free'" :data-dir="sortKey === 'free' ? sortDir : ''" @click="sortBy('free')">
                  Frete grátis
                  <svg class="sortmark" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
                    <path d="M2.5 4.5L6 8l3.5-3.5" />
                  </svg>
                </button>
              </th>
              <th scope="col">Retirada</th>
              <th scope="col">Oferta</th>
              <th scope="col">
                <button class="sortbtn" type="button" :data-key="'active'" :data-dir="sortKey === 'active' ? sortDir : ''" @click="sortBy('active')">
                  Situação
                  <svg class="sortmark" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
                    <path d="M2.5 4.5L6 8l3.5-3.5" />
                  </svg>
                </button>
              </th>
            </tr>
          </thead>
          <tbody>
            <tr
              v-for="store in filteredStores"
              :key="store.id"
              :data-id="store.id"
              :data-name="store.name"
              :data-place="store.address + ' ' + store.neighborhood + ' ' + store.city + ' ' + store.state"
              :data-type="store.type"
              :data-typelabel="store.typeLabel"
              :data-fee="String(store.fee)"
              :data-min="String(store.min)"
              :data-free="String(store.free)"
              :data-active="store.active ? '1' : '0'"
              :hidden="isHidden(store)"
              class="store-row"
              @click="handleRowClick($event, store)"
            >
              <td class="c-name">
                <button class="rowbtn" type="button" @click.stop="openDetail(store)">
                  <b>{{ store.name }}</b>
                  <span>{{ store.address }} · {{ store.neighborhood }}, {{ store.city }}/{{ store.state }}</span>
                </button>
              </td>
              <td>
                <template v-if="store.type === 'missing' || store.type === 'unknown'">
                  <span class="plate" :data-sev="store.type === 'missing' ? 'grave' : 'grave'">
                    {{ store.typeLabel }}
                  </span>
                </template>
                <span v-else class="type">{{ store.typeLabel }}</span>
              </td>
              <td class="c-num">{{ formatMoney(store.fee) }}</td>
              <td class="c-num">{{ formatMin(store.min) }}</td>
              <td class="c-num">{{ formatFree(store.free) }}</td>
              <td>{{ store.pickupTime }}</td>
              <td class="c-off">
                <template v-if="store.sectionsCount > 0 || store.categoriesCount > 0">
                  <b>{{ store.sectionsCount }}</b> <span>seções ·</span> <b>{{ store.categoriesCount }}</b> <span>categorias</span>
                </template>
                <template v-else>
                  <span class="plate" data-sev="atencao">Não oferece nada</span>
                </template>
              </td>
              <td>
                <span class="state" :data-on="String(store.active)">{{ store.active ? 'Ativa' : 'Inativa' }}</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <!-- Estado vazio -->
      <div class="empty" v-if="filteredStores.length === 0" hidden>
        <b>Nenhuma loja corresponde a estes filtros</b>
        <p>A rede tem seis lojas. Nenhuma delas satisfaz a combinação atual de busca, tipo e situação.</p>
        <button class="btn btn-secondary" type="button" @click="resetFilters">Limpar filtros</button>
      </div>
    </section>

    <!-- Dialog de detalhe -->
    <StoreDetailDialog
      :store="selectedStore"
      :detail="selectedStoreDetail"
      @close="selectedStore = null"
    />
  </div>
</template>

<script setup lang="ts">
import { ref, computed } from 'vue'
import StoreDetailDialog from '@/components/StoreDetailDialog.vue'
import type { Store, StoreDetail } from '@/types/store'

// ── Dados das lojas (fixtures do protótipo) ──────────────────────────────
const stores: Store[] = [
  {
    id: 'centro',
    name: 'Vila Nova Centro',
    address: 'R. Barão de Itapetininga, 255',
    neighborhood: 'República',
    city: 'São Paulo',
    state: 'SP',
    type: 'alimenticio',
    typeLabel: 'Alimentício',
    fee: 790,
    min: 0,
    free: 28300,
    pickupTime: '25 min',
    active: true,
    sectionsCount: 4,
    categoriesCount: 5,
  },
  {
    id: 'pinheiros',
    name: 'Vila Nova Pinheiros',
    address: 'R. dos Pinheiros, 1.402',
    neighborhood: 'Pinheiros',
    city: 'São Paulo',
    state: 'SP',
    type: 'alimenticio',
    typeLabel: 'Alimentício',
    fee: 990,
    min: 8000,
    free: 24900,
    pickupTime: '',
    active: true,
    sectionsCount: 3,
    categoriesCount: 4,
  },
  {
    id: 'farmacia-sp',
    name: 'Vila Nova Farma Centro',
    address: 'Av. São João, 1.100',
    neighborhood: 'Centro',
    city: 'São Paulo',
    state: 'SP',
    type: 'farmacia',
    typeLabel: 'Farmácia',
    fee: 590,
    min: 0,
    free: 0,
    pickupTime: '15 min',
    active: true,
    sectionsCount: 3,
    categoriesCount: 3,
  },
  {
    id: 'petshop-abc',
    name: 'Vila Nova Pet Santo André',
    address: 'R. Coronel Oliveira Lima, 480',
    neighborhood: 'Centro',
    city: 'Santo André',
    state: 'SP',
    type: 'petshop',
    typeLabel: 'Petshop',
    fee: 890,
    min: 3000,
    free: 15000,
    pickupTime: '',
    active: false,
    sectionsCount: 2,
    categoriesCount: 2,
  },
  {
    id: 'deposito',
    name: 'Depósito Vila Nova',
    address: 'R. Guaicurus, 78',
    neighborhood: 'Lapa',
    city: 'São Paulo',
    state: 'SP',
    type: 'missing',
    typeLabel: 'Sem tipo',
    fee: 0,
    min: 0,
    free: 0,
    pickupTime: '60 min',
    active: false,
    sectionsCount: 0,
    categoriesCount: 0,
  },
  {
    id: 'import-2019',
    name: 'Vila Nova Osasco',
    address: 'Av. dos Autonomistas, 3.200',
    neighborhood: 'Vila Yara',
    city: 'Osasco',
    state: 'SP',
    type: 'unknown',
    typeLabel: 'Tipo desconhecido',
    fee: 690,
    min: 5000,
    free: 20000,
    pickupTime: '40 min',
    active: true,
    sectionsCount: 1,
    categoriesCount: 1,
  },
]

const storeDetails: Record<string, StoreDetail> = {
  'centro': {
    sections: ['Mercearia', 'Frios e Laticínios', 'Carnes', 'Padaria'],
    categories: ['Arroz e feijão', 'Café', 'Queijos', 'Bovinos', 'Pães'],
    cards: ['Visa', 'Mastercard', 'Elo', 'Pix'],
    weights: ['100g', '250g', '500g', '750g', '1kg'],
    cuts: ['Fatiado', 'Em cubos', 'Peça inteira', 'Moído'],
    note: null,
    alert: null,
  },
  'pinheiros': {
    sections: ['Mercearia', 'Frios e Laticínios', 'Carnes'],
    categories: ['Arroz e feijão', 'Café', 'Queijos', 'Bovinos'],
    cards: ['Visa', 'Mastercard', 'Pix'],
    weights: ['250g', '500g', '1kg'],
    cuts: ['Fatiado', 'Peça inteira'],
    note: null,
    alert: null,
  },
  'farmacia-sp': {
    sections: ['Medicamentos', 'Higiene', 'Dermocosméticos'],
    categories: ['Analgésicos', 'Sabonetes', 'Protetor solar'],
    cards: ['Visa', 'Mastercard', 'Elo'],
    weights: [],
    cuts: [],
    note: 'Gramatura e tipo de corte estão vazios POR REGRA, não por falta de dado: farmácia não vende pesável. Os campos não aparecem desabilitados — campo desabilitado promete que um dia edita.',
    alert: null,
  },
  'petshop-abc': {
    sections: ['Ração', 'Acessórios'],
    categories: ['Cães', 'Gatos'],
    cards: ['Visa', 'Pix'],
    weights: [],
    cuts: [],
    note: 'Gramatura e tipo de corte vazios por regra do tipo petshop.',
    alert: null,
  },
  'deposito': {
    sections: [],
    categories: [],
    cards: ['Pix'],
    weights: [],
    cuts: [],
    note: null,
    alert: {
      title: 'Duas pendências neste registro',
      body: 'O campo de tipo está gravado como string vazia, e a loja não oferece nenhuma seção nem categoria. Está inativa, o que contém o dano — ativar sem resolver as duas publica uma loja vazia na vitrine.',
    },
  },
  'import-2019': {
    sections: ['Mercearia'],
    categories: ['Arroz e feijão'],
    cards: ['Visa', 'Mastercard'],
    weights: ['500g'],
    cuts: [],
    note: null,
    alert: {
      title: 'Tipo fora do contrato',
      body: 'Gravada como "mercearia", valor de uma integração antiga. O contrato aceita alimentício, farmácia e petshop. Isto é desconhecido, não ausente — a decisão é mapear para um tipo válido, não escolher um do zero.',
    },
  },
}

// ── Estado de filtro e ordenação ─────────────────────────────────────────
const search = ref('')
const filterType = ref('all')
const status = ref<'all' | 'on' | 'off'>('all')
const sortKey = ref('name')
const sortDir = ref<'asc' | 'desc'>('asc')
const selectedStore = ref<Store | null>(null)

// ── Utilitários ──────────────────────────────────────────────────────────
function norm(s: string): string {
  return (s || '').toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '')
}

function formatMoney(cents: number): string {
  return 'R$ ' + (cents / 100).toFixed(2).replace('.', ',')
}

function formatMin(cents: number): string {
  if (cents === 0) return '<span class="dash">sem mínimo</span>'
  return formatMoney(cents)
}

function formatFree(cents: number): string {
  if (cents === 0) return '<span class="dash">não oferece</span>'
  return formatMoney(cents)
}

// ── Filtragem e ordenação ────────────────────────────────────────────────
const filteredStores = computed(() => {
  const term = norm(search.value.trim())
  const wantType = filterType.value

  let result = stores.filter((store) => {
    const hay = norm(store.name + ' ' + store.address + ' ' + store.neighborhood + ' ' + store.city + ' ' + store.state)
    const okTerm = !term || hay.includes(term)
    const okType = wantType === 'all' || store.type === wantType
    const okStatus =
      status.value === 'all' ||
      (status.value === 'on' && store.active) ||
      (status.value === 'off' && !store.active)
    return okTerm && okType && okStatus
  })

  // Ordenação
  const dir = sortDir.value === 'asc' ? 1 : -1
  result.sort((a, b) => {
    if (sortKey.value === 'name') return (a.name.localeCompare(b.name, 'pt-BR')) * dir
    if (sortKey.value === 'typelabel') return (a.typeLabel.localeCompare(b.typeLabel, 'pt-BR')) * dir
    const numKey = sortKey.value as 'fee' | 'min' | 'free' | 'active'
    return ((a[numKey] as number) - (b[numKey] as number)) * dir
  })

  return result
})

// ── Helpers de visibilidade (para atributo hidden) ───────────────────────
function isHidden(store: Store): boolean {
  const term = norm(search.value.trim())
  const wantType = filterType.value
  const hay = norm(store.name + ' ' + store.address + ' ' + store.neighborhood + ' ' + store.city + ' ' + store.state)

  const okTerm = !term || hay.includes(term)
  const okType = wantType === 'all' || store.type === wantType
  const okStatus =
    status.value === 'all' ||
    (status.value === 'on' && store.active) ||
    (status.value === 'off' && !store.active)

  return !(okTerm && okType && okStatus)
}

// ── Ações ────────────────────────────────────────────────────────────────
function sortBy(key: 'name' | 'typelabel' | 'fee' | 'min' | 'free' | 'active') {
  if (sortKey.value === key) {
    sortDir.value = sortDir.value === 'asc' ? 'desc' : 'asc'
  } else {
    sortKey.value = key
    sortDir.value = 'asc'
  }
}

function openDetail(store: Store) {
  selectedStore.value = store
}

function handleRowClick(event: MouseEvent, store: Store) {
  if ((event.target as HTMLElement).closest('.rowbtn')) return
  selectedStore.value = store
}

function resetFilters() {
  search.value = ''
  filterType.value = 'all'
  status.value = 'all'
}

const count = computed(() => filteredStores.value.length)
const total = computed(() => stores.length)

const selectedStoreDetail = computed(() => {
  return selectedStore.value ? storeDetails[selectedStore.value.id] || null : null
})

// ── Suporte a hash URL (como o protótipo) ────────────────────────────────
function checkHash() {
  const hash = window.location.hash.slice(1)
  if (hash) {
    const store = stores.find((s) => s.id === hash)
    if (store) {
      selectedStore.value = store
    }
  }
}

checkHash()
window.addEventListener('hashchange', checkHash)
</script>
