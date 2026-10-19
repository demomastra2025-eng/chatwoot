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
    <header
      class="sticky top-0 z-10 border-b border-n-weak bg-n-surface-1/95 px-6 backdrop-blur"
    >
      <div class="w-full max-w-5xl mx-auto py-3.5">
        <div
          class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between"
        >
          <div class="flex min-w-0 flex-wrap items-center gap-2.5">
            <h1 class="mb-0 truncate text-heading-2 text-n-slate-12">
              {{ title }}
            </h1>
            <div
              v-if="$slots.meta"
              class="inline-flex items-center gap-1.5 rounded-full bg-n-alpha-2 px-2.5 py-0.5 text-xs font-medium text-n-slate-11"
            >
              <slot name="meta" />
            </div>
          </div>

          <div
            v-if="$slots.actions"
            class="flex shrink-0 flex-wrap items-center gap-2 sm:justify-end"
          >
            <slot name="actions" />
          </div>
        </div>

        <div v-if="$slots.tabs" class="mt-3">
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
