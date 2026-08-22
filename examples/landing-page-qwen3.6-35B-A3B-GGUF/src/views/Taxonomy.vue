<template>
  <div class="wrap">
    <!-- Cabeçalho -->
    <section>
      <p class="breadcrumb">
        <router-link to="/">Início</router-link>
        <svg viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
          <path d="M4.5 2.5L8 6l-3.5 3.5" />
        </svg>
        Taxonomia
      </p>
      <div class="head">
        <div>
          <h1>Seções e categorias</h1>
          <p>
            São <strong>dois recursos</strong> no contrato, e continuam dois — a
            coincidência de forma não é razão para unificar. Esta tela parametriza
            só a <strong>apresentação</strong>, que é onde a coincidência é real.
          </p>
        </div>
        <p class="source">
          <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
            <ellipse cx="8" cy="4" rx="5.25" ry="2.25" />
            <path d="M2.75 4v8c0 1.24 2.35 2.25 5.25 2.25s5.25-1.01 5.25-2.25V4" />
            <path d="M2.75 8c0 1.24 2.35 2.25 5.25 2.25s5.25-1.01 5.25-2.25" />
          </svg>
          Fixture local · <code>taxonomy.ts</code>
        </p>
      </div>
    </section>

    <!-- Seletor de recurso (tabs) -->
    <div class="seg" role="tablist" aria-label="Recurso de taxonomia">
      <button
        type="button"
        role="tab"
        id="tab-secoes"
        data-key="secoes"
        :aria-selected="resource === 'secoes'"
        :aria-controls="'panel-' + resource"
        :tabindex="resource === 'secoes' ? 0 : -1"
        @click="switchResource('secoes')"
      >
        Seções <b>{{ sections.length }}</b>
      </button>
      <button
        type="button"
        role="tab"
        id="tab-categorias"
        data-key="categorias"
        :aria-selected="resource === 'categorias'"
        :aria-controls="'panel-' + resource"
        :tabindex="resource === 'categorias' ? 0 : -1"
        @click="switchResource('categorias')"
      >
        Categorias <b>{{ categories.length }}</b>
      </button>
    </div>

    <!-- Painel de Seções -->
    <section
      class="panel"
      id="panel-secoes"
      role="tabpanel"
      aria-labelledby="tab-secoes"
      :hidden="resource !== 'secoes'"
      v-if="resource === 'secoes'"
    >
      <div class="card">
        <div class="card-head">
          <div>
            <h2>{{ sections.length }} seções</h2>
            <p>
              O <strong>identificador</strong> é o que as lojas referenciam. O
              <strong>nome exibido</strong> é só o que aparece na tela. Renomear o
              nome não quebra referência nenhuma — mexer no identificador quebraria
              todas, e é por isso que ele não se escreve.
            </p>
          </div>
        </div>
        <div class="tablewrap">
          <table>
            <caption class="sr">seções, com identificador, descrição, quantidade de referências e situação</caption>
            <thead>
              <tr>
                <th scope="col">Nome exibido</th>
                <th scope="col">Identificador</th>
                <th scope="col">Descrição</th>
                <th scope="col" class="c-num">Lojas que referenciam</th>
                <th scope="col">Situação</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="section in sections" :key="section.id" :data-id="section.id" :data-active="section.active ? '1' : '0'">
                <td class="c-name">
                  <button
                    class="rowbtn"
                    type="button"
                    :data-id="section.id"
                    :data-name="section.name"
                    :data-desc="section.description"
                    :data-active="section.active ? '1' : '0'"
                    :aria-label="'Editar ' + section.name"
                    @click="openEditSection(section)"
                  >
                    <b>{{ section.name }}</b>
                  </button>
                </td>
                <td class="c-id"><code>{{ section.id }}</code></td>
                <td class="c-desc">
                  <template v-if="section.description">{{ section.description }}</template>
                  <template v-else><span class="dash">sem descrição</span></template>
                </td>
                <td class="c-ref" :data-zero="section.references === 0">{{ section.references }}</td>
                <td>
                  <span class="state" :data-on="section.active ? 'true' : 'false'">
                    {{ section.active ? 'Ativa' : 'Inativa' }}
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <section class="notice" data-kind="failure" style="margin-block-start: var(--sp-7);">
        <strong>Nenhuma das 9 seções é referenciada por identificador</strong>
        <p>
          Cinco das seis lojas carregam valores de seção — mas gravados como
          <strong>rótulo</strong> (<code>Frios e Laticínios</code>), não como
          identificador (<code>frios-e-laticinios</code>). Nada casa por id hoje.
        </p>
        <ul>
          <li><strong>6 resolveriam</strong> se a normalização fosse aplicada: Mercearia, Frios e Laticínios, Carnes, Padaria, Medicamentos e Higiene.</li>
          <li><strong>3 continuariam sem destino:</strong> <code>Dermocosméticos</code> é <strong>categoria</strong>, não seção; <code>Acessórios</code> não existe em lado nenhum; e <code>Ração</code> normaliza para <code>racoes</code>, enquanto a seção é <code>racoes</code>.</li>
        </ul>
      </section>

      <section class="notice" data-kind="success" style="margin-block-start: var(--sp-5);">
        <strong>Nenhum identificador com forma de rótulo</strong>
        <p>
          A verificação procura maiúscula, espaço e acento no identificador — o
          sinal de que um rótulo virou id por acidente. As 9 entradas desta
          lista passaram. Esta linha existe para provar que a verificação rodou:
          sumir com ela faria "não há" e "ninguém verificou" ficarem iguais.
        </p>
      </section>
    </section>

    <!-- Painel de Categorias -->
    <section
      class="panel"
      id="panel-categorias"
      role="tabpanel"
      aria-labelledby="tab-categorias"
      :hidden="resource !== 'categorias'"
      v-if="resource === 'categorias'"
    >
      <div class="card">
        <div class="card-head">
          <div>
            <h2>{{ categories.length }} categorias</h2>
            <p>
              O <strong>identificador</strong> é o que os produtos referenciam. O
              <strong>nome exibido</strong> é só o que aparece na tela. Renomear o
              nome não quebra referência nenhuma — mexer no identificador quebraria
              todas, e é por isso que ele não se escreve.
            </p>
          </div>
        </div>
        <div class="tablewrap">
          <table>
            <caption class="sr">categorias, com identificador, descrição, quantidade de referências e situação</caption>
            <thead>
              <tr>
                <th scope="col">Nome exibido</th>
                <th scope="col">Identificador</th>
                <th scope="col">Descrição</th>
                <th scope="col" class="c-num">Produtos que referenciam</th>
                <th scope="col">Situação</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="cat in categories" :key="cat.id" :data-id="cat.id" :data-active="cat.active ? '1' : '0'">
                <td class="c-name">
                  <button
                    class="rowbtn"
                    type="button"
                    :data-id="cat.id"
                    :data-name="cat.name"
                    :data-desc="cat.description"
                    :data-active="cat.active ? '1' : '0'"
                    :aria-label="'Editar ' + cat.name"
                    @click="openEditCategory(cat)"
                  >
                    <b>{{ cat.name }}</b>
                  </button>
                </td>
                <td class="c-id"><code>{{ cat.id }}</code></td>
                <td class="c-desc">
                  <template v-if="cat.description">{{ cat.description }}</template>
                  <template v-else><span class="dash">sem descrição</span></template>
                </td>
                <td class="c-ref" :data-zero="cat.references === 0">{{ cat.references }}</td>
                <td>
                  <span class="state" :data-on="cat.active ? 'true' : 'false'">
                    {{ cat.active ? 'Ativa' : 'Inativa' }}
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <section class="notice" data-kind="failure" style="margin-block-start: var(--sp-7);">
        <strong>3 das 11 categorias são referenciadas por produto</strong>
        <p>
          Café, Queijos e Bovinos. As lojas também carregam valores de categoria,
          todos como rótulo — nenhum casa por identificador.
        </p>
        <ul>
          <li><strong>Uma referência aponta para o recurso errado:</strong> o produto <em>Suco de Uva Integral 1L</em> tem <code>bebidas</code> em <code>categories</code>, e <code>bebidas</code> é <strong>seção</strong>. A categoria de suco existe e é <code>sucos</code>.</li>
          <li>Desativar uma categoria com 0 referências <strong>não dá conflito</strong> — e é justamente aí que está o risco: o servidor só recusa quando alguém referencia, e hoje quase ninguém referencia por id.</li>
        </ul>
      </section>

      <section class="notice" data-kind="success" style="margin-block-start: var(--sp-5);">
        <strong>Nenhum identificador com forma de rótulo</strong>
        <p>
          A verificação procura maiúscula, espaço e acento no identificador — o
          sinal de que um rótulo virou id por acidente. As 11 entradas desta
          lista passaram. Esta linha existe para provar que a verificação rodou:
          sumir com ela faria "não há" e "ninguém verificou" ficarem iguais.
        </p>
      </section>
    </section>

    <!-- Dialog / Sheet de Edição -->
    <dialog
      class="sheet"
      :open="editOpen"
      aria-labelledby="sheet-title"
      @close="editOpen = false"
      @click="handleSheetOverlay"
    >
      <div class="sheet-inner" @click.stop>
        <div class="sheet-head">
          <div>
            <h2 id="sheet-title">Editar {{ editTitle }}</h2>
            <p id="sheet-sub">Nome, descrição e situação. O identificador não.</p>
          </div>
          <button class="close" type="button" aria-label="Fechar edição" @click="editOpen = false">
            <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
              <path d="M4 4l8 8M12 4l-8 8" />
            </svg>
          </button>
        </div>
        <div class="sheet-body">
          <div class="block">
            <p class="block-label">Identificador</p>
            <div class="locked">
              <code>{{ editId }}</code>
              <p>
                Não é um campo desabilitado — é um valor. Campo desabilitado promete
                que um dia edita. Este nunca edita: é o que as lojas e os produtos
                gravaram, e mudá-lo quebraria toda referência em silêncio.
              </p>
            </div>
          </div>
          <div class="block field">
            <label for="f-name">Nome exibido</label>
            <input
              id="f-name"
              type="text"
              v-model="editName"
            />
            <span class="hint">Renomear aqui não afeta referência nenhuma.</span>
          </div>
          <div class="block field">
            <label for="f-desc">Descrição</label>
            <textarea id="f-desc" v-model="editDescription" />
            <span class="hint">Opcional. Dez das onze categorias estão sem descrição hoje.</span>
          </div>
          <div class="block">
            <label class="check">
              <input type="checkbox" v-model="editActive" />
              Ativa
            </label>
            <p class="rule-note" style="margin-block-start: var(--sp-4);">
              <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
                <circle cx="8" cy="8" r="5.75" />
                <path d="M8 5.25v.01M8 7.5v3.25" />
              </svg>
              Desativar é decisão comercial, não defeito. O servidor recusa com
              <code>CONFLICT</code> quando alguém ainda referencia — e é ele quem sabe
              quantos, porque a contagem é do lado de quem referencia.
            </p>
          </div>
        </div>
        <div class="sheet-foot">
          <button class="btn btn-ghost" type="button" @click="editOpen = false">Cancelar</button>
          <button class="btn btn-primary" type="button" @click="saveEdit">Salvar</button>
        </div>
      </div>
    </dialog>
  </div>
</template>

<script setup lang="ts">
import { ref, computed } from 'vue'

// ── Tipos ────────────────────────────────────────────────────────────────
interface TaxonomyItem {
  id: string
  name: string
  description: string
  active: boolean
  references: number
}

// ── Estado das abas ──────────────────────────────────────────────────────
const resource = ref<'secoes' | 'categorias'>('secoes')

function switchResource(key: 'secoes' | 'categorias') {
  resource.value = key
}

// ── Dados das seções (fixtures do painel-taxonomia.html) ─────────────────
const sections = ref<TaxonomyItem[]>([
  { id: 'mercearia', name: 'Mercearia', description: 'Secos e básicos de despensa.', active: true, references: 0 },
  { id: 'frios-e-laticinios', name: 'Frios e Laticínios', description: '', active: true, references: 0 },
  { id: 'carnes', name: 'Carnes', description: 'Bovinos, suínos e aves.', active: true, references: 0 },
  { id: 'padaria', name: 'Padaria', description: '', active: true, references: 0 },
  { id: 'bebidas', name: 'Bebidas', description: '', active: true, references: 0 },
  { id: 'medicamentos', name: 'Medicamentos', description: '', active: true, references: 0 },
  { id: 'higiene', name: 'Higiene', description: '', active: true, references: 0 },
  { id: 'racoes', name: 'Rações', description: '', active: true, references: 0 },
  { id: 'bazar', name: 'Bazar', description: 'Descontinuada em 2024.', active: false, references: 0 },
])

// ── Dados das categorias (fixtures do painel-taxonomia.html) ─────────────
const categories = ref<TaxonomyItem[]>([
  { id: 'arroz-e-feijao', name: 'Arroz e feijão', description: '', active: true, references: 0 },
  { id: 'cafe', name: 'Café', description: '', active: true, references: 1 },
  { id: 'queijos', name: 'Queijos', description: '', active: true, references: 1 },
  { id: 'bovinos', name: 'Bovinos', description: '', active: true, references: 1 },
  { id: 'paes', name: 'Pães', description: '', active: true, references: 0 },
  { id: 'analgesicos', name: 'Analgésicos', description: '', active: true, references: 0 },
  { id: 'dermocosmeticos', name: 'Dermocosméticos', description: '', active: true, references: 0 },
  { id: 'caes', name: 'Cães', description: '', active: true, references: 0 },
  { id: 'gatos', name: 'Gatos', description: '', active: true, references: 0 },
  { id: 'sucos', name: 'Sucos', description: '', active: true, references: 0 },
  { id: 'importados', name: 'Importados', description: 'Descontinuada.', active: false, references: 0 },
])

// ── Estado do dialog/sheet de edição ─────────────────────────────────────
const editOpen = ref(false)
const editType = ref<'section' | 'category'>('section')
const editId = ref('')
const editName = ref('')
const editDescription = ref('')
const editActive = ref(false)

const editTitle = computed(() => editType.value === 'section' ? 'Seção' : 'Categoria')

// ── Abrir edição de seção ────────────────────────────────────────────────
function openEditSection(section: TaxonomyItem) {
  editType.value = 'section'
  editId.value = section.id
  editName.value = section.name
  editDescription.value = section.description
  editActive.value = section.active
  editOpen.value = true
}

// ── Abrir edição de categoria ────────────────────────────────────────────
function openEditCategory(category: TaxonomyItem) {
  editType.value = 'category'
  editId.value = category.id
  editName.value = category.name
  editDescription.value = category.description
  editActive.value = category.active
  editOpen.value = true
}

// ── Salvar edição ────────────────────────────────────────────────────────
function saveEdit() {
  const target = editType.value === 'section' ? sections.value : categories.value

  const item = target.find((i) => i.id === editId.value)
  if (item) {
    item.name = editName.value
    item.description = editDescription.value
    item.active = editActive.value
  }

  editOpen.value = false
}

// ── Fechar ao clicar no overlay ──────────────────────────────────────────
function handleSheetOverlay(event: MouseEvent) {
  if ((event.target as HTMLElement).classList.contains('sheet')) {
    editOpen.value = false
  }
}
</script>
