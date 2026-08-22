<template>
  <div class="app">
    <!-- Trilho lateral -->
    <aside class="rail">
      <div class="rail-brand">
        <b>Vila Nova</b>
        <span>Painel da rede</span>
      </div>

      <div>
        <p class="nav-label">Operação</p>
        <nav class="nav" aria-label="Áreas do painel">
          <router-link
            class="nav-item"
            to="/"
            active-class="active"
            exact-active-class="active"
          >
            <span class="nav-name">Início</span>
          </router-link>

          <router-link
            class="nav-item"
            to="/lojas"
          >
            <span class="nav-name">Lojas</span>
            <span class="nav-count" title="2 lojas com pendência de configuração">2</span>
          </router-link>

          <router-link
            class="nav-item"
            to="/produtos"
          >
            <span class="nav-name">Produtos</span>
          </router-link>

          <router-link
            class="nav-item"
            to="/taxonomia"
          >
            <span class="nav-name">Taxonomia</span>
          </router-link>
        </nav>
      </div>

      <p class="rail-foot">
        <b>5 de 12 registros com pendência</b>
        2 lojas e 3 produtos. Seções e categorias não têm sinal de pendência
        definido — inativa é estado legítimo, não defeito.
      </p>
    </aside>

    <!-- Conteúdo principal -->
    <main class="main">
      <router-view />
    </main>
  </div>
</template>

<style scoped>
/* Override router-link-active classes to match design tokens */
.nav-item.router-link-active,
.nav-item.router-link-exact-active {
  background: var(--accent-wash);
  color: var(--accent-press);
  font-weight: 700;
  box-shadow: inset 3px 0 0 0 var(--accent);
}
</style>
