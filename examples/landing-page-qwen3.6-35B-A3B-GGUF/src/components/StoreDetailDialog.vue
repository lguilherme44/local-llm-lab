<template>
  <dialog class="sheet" ref="dialogRef" aria-labelledby="sheet-title">
    <div class="sheet-inner">
      <div class="sheet-head">
        <div>
          <h2 id="sheet-title">{{ store?.name ?? '—' }}</h2>
          <p id="sheet-sub">
            {{ store ? `${store.address}, ${store.neighborhood}, ${store.city}/${store.state} · ` : '' }}
            <span class="id">{{ store?.id ?? '' }}</span>
          </p>
        </div>
        <button class="close" type="button" aria-label="Fechar detalhe da loja" @click="close">
          <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
            <path d="M4 4l8 8M12 4l-8 8" />
          </svg>
        </button>
      </div>
      <div class="sheet-body">
        <!-- Alerta -->
        <div v-if="detail?.alert" class="sheet-alert">
          <b>{{ detail.alert.title }}</b>
          <p>{{ detail.alert.body }}</p>
        </div>

        <!-- Identificação -->
        <div class="block">
          <p class="block-label">Identificação</p>
          <dl class="pairs">
            <div class="pair">
              <dt>Tipo</dt>
              <dd>{{ store?.typeLabel ?? '' }}</dd>
            </div>
            <div class="pair">
              <dt>Situação</dt>
              <dd>{{ store?.active ? 'Ativa' : 'Inativa' }}</dd>
            </div>
          </dl>
        </div>

        <!-- Entrega e retirada -->
        <div class="block">
          <p class="block-label">Entrega e retirada</p>
          <dl class="pairs">
            <div class="pair">
              <dt>Taxa de entrega</dt>
              <dd>{{ money(store?.fee ?? 0) }}</dd>
            </div>
            <div class="pair">
              <dt>Pedido mínimo</dt>
              <dd>{{ money((store?.min ?? 0), 'sem mínimo') }}</dd>
            </div>
            <div class="pair">
              <dt>Frete grátis a partir de</dt>
              <dd>{{ money((store?.free ?? 0), 'não oferece') }}</dd>
            </div>
            <div class="pair">
              <dt>Retirada na loja</dt>
              <dd>{{ store?.pickupTime ?? '' }}</dd>
            </div>
          </dl>
        </div>

        <!-- Seções -->
        <div class="block">
          <p class="block-label">Seções oferecidas ({{ detail?.sections.length ?? 0 }})</p>
          <template v-if="detail?.sections.length">
            <div class="taglist">
              <span v-for="s in detail.sections" :key="s" class="tag">{{ s }}</span>
            </div>
          </template>
          <p v-else class="none">Nenhuma seção atribuída</p>
        </div>

        <!-- Categorias -->
        <div class="block">
          <p class="block-label">Categorias oferecidas ({{ detail?.categories.length ?? 0 }})</p>
          <template v-if="detail?.categories.length">
            <div class="taglist">
              <span v-for="c in detail.categories" :key="c" class="tag">{{ c }}</span>
            </div>
          </template>
          <p v-else class="none">Nenhuma categoria atribuída</p>
        </div>

        <!-- Bandeiras aceitas -->
        <div class="block">
          <p class="block-label">Bandeiras aceitas</p>
          <template v-if="detail?.cards.length">
            <div class="taglist">
              <span v-for="c in detail.cards" :key="c" class="tag">{{ c }}</span>
            </div>
          </template>
          <p v-else class="none">Nenhuma bandeira cadastrada</p>
        </div>

        <!-- Gramaturas -->
        <div class="block">
          <p class="block-label">Gramaturas</p>
          <template v-if="detail?.weights.length">
            <div class="taglist">
              <span v-for="w in detail.weights" :key="w" class="tag">{{ w }}</span>
            </div>
          </template>
          <p v-else class="none">Nenhuma — o tipo desta loja não vende pesável</p>
        </div>

        <!-- Tipos de corte -->
        <div class="block">
          <p class="block-label">Tipos de corte</p>
          <template v-if="detail?.cuts.length">
            <div class="taglist">
              <span v-for="c in detail.cuts" :key="c" class="tag">{{ c }}</span>
            </div>
          </template>
          <p v-else class="none">Nenhum — o tipo desta loja não vende pesável</p>
        </div>

        <!-- Nota -->
        <div v-if="detail?.note" class="block">
          <div class="rule-note">
            <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
              <circle cx="8" cy="8" r="5.75" />
              <path d="M8 5.25v.01M8 7.5v3.25" />
            </svg>
            <p>{{ detail.note }}</p>
          </div>
        </div>
      </div>

      <div class="sheet-foot">
        <button class="btn btn-ghost" type="button" @click="close">Fechar</button>
        <button class="btn btn-secondary" type="button">Editar configuração</button>
      </div>
    </div>
  </dialog>
</template>

<script setup lang="ts">
import { ref, watch } from 'vue'
import type { Store, StoreDetail } from '@/types/store'

const props = defineProps<{
  store: Store | null
  detail: StoreDetail | null
}>()

const emit = defineEmits<{
  close: []
}>()

// Suppress unused variable warning — emit is used by template via @click="close"
void emit

const dialogRef = ref<HTMLDialogElement | null>(null)

function open() {
  dialogRef.value?.showModal()
}

function close() {
  dialogRef.value?.close()
}

function money(cents: number, zeroText?: string): string {
  if (cents === 0 && zeroText) return zeroText
  return 'R$ ' + (cents / 100).toFixed(2).replace('.', ',')
}

// Auto-open when store changes
watch(
  () => props.store,
  (val) => {
    if (val) open()
  }
)

defineExpose({ open, close })
</script>
