export interface Store {
  id: string
  name: string
  address: string
  neighborhood: string
  city: string
  state: string
  type: string
  typeLabel: string
  fee: number
  min: number
  free: number
  pickupTime: string
  active: boolean
  sectionsCount: number
  categoriesCount: number
}

export interface StoreDetail {
  sections: string[]
  categories: string[]
  cards: string[]
  weights: string[]
  cuts: string[]
  note: string | null
  alert: {
    title: string
    body: string
  } | null
}

export type SortKey = 'name' | 'typelabel' | 'fee' | 'min' | 'free' | 'active'
export type SortDirection = 'asc' | 'desc' | ''
export type FilterStatus = 'all' | 'on' | 'off'
export type FilterType = 'all' | 'alimenticio' | 'farmacia' | 'petshop' | 'missing' | 'unknown'

export interface SortState {
  key: SortKey
  dir: SortDirection
  type: 'text' | 'num'
}
