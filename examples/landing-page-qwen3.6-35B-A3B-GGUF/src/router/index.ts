import { createRouter, createWebHistory } from 'vue-router'

const router = createRouter({
  history: createWebHistory(),
  routes: [
    {
      path: '/',
      component: () => import('@/layouts/MainLayout.vue'),
      children: [
        {
          path: '',
          name: 'home',
          component: () => import('@/views/Dashboard.vue'),
        },
        {
          path: 'lojas',
          name: 'lojas',
          component: () => import('@/views/StoreList.vue'),
        },
        {
          path: 'produtos',
          name: 'produtos',
          component: () => import('@/views/Products.vue'),
        },
        {
          path: 'taxonomia',
          name: 'taxonomia',
          component: () => import('@/views/Taxonomy.vue'),
        },
      ],
    },
  ],
})

export default router
