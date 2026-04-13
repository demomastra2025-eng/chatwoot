<script setup>
defineProps({
  title: {
    type: String,
    default: '',
  },
  description: {
    type: String,
    default: '',
  },
});
</script>

<template>
  <section class="flex flex-col w-full h-full overflow-hidden bg-n-surface-1">
    <header class="sticky top-0 z-10 px-6 bg-n-surface-1/95 backdrop-blur">
      <div class="w-full max-w-5xl mx-auto py-5">
        <div
          class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between"
        >
          <div class="min-w-0">
            <div
              v-if="$slots.meta"
              class="flex flex-wrap items-center gap-2 mb-2 text-sm text-n-slate-11"
            >
              <slot name="meta" />
            </div>
            <h1 class="mb-1 text-heading-1 text-n-slate-12">
              {{ title }}
            </h1>
            <p
              v-if="description"
              class="max-w-3xl mb-0 text-sm leading-6 text-n-slate-11"
            >
              {{ description }}
            </p>
          </div>

          <div
            v-if="$slots.actions"
            class="flex flex-wrap items-center gap-2 lg:justify-end"
          >
            <slot name="actions" />
          </div>
        </div>

        <div v-if="$slots.tabs" class="mt-4">
          <slot name="tabs" />
        </div>
      </div>
    </header>

    <main class="flex-1 px-6 overflow-y-auto">
      <div class="w-full max-w-5xl mx-auto py-4">
        <slot />
      </div>
    </main>
  </section>
</template>
