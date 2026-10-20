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
  <section
    class="flex flex-col w-full h-full min-h-0 overflow-hidden bg-n-background"
  >
    <header
      class="sticky top-0 z-10 border-b border-n-weak bg-n-background/95 backdrop-blur px-6 py-3"
    >
      <div class="flex flex-wrap items-center justify-between gap-3 w-full">
        <div class="flex items-center gap-3 min-w-0">
          <h1
            v-if="title"
            class="text-base font-semibold tracking-tight text-n-slate-12 truncate mb-0"
          >
            {{ title }}
          </h1>
          <div
            v-if="$slots.meta || $slots['header-meta']"
            class="inline-flex items-center gap-1.5 rounded-full bg-n-alpha-2 px-2.5 py-0.5 text-xs font-medium text-n-slate-11"
          >
            <slot name="meta" />
            <slot name="header-meta" />
          </div>
        </div>
        <div
          v-if="$slots.actions || $slots['header-actions']"
          class="flex items-center gap-2 shrink-0"
        >
          <slot name="actions" />
          <slot name="header-actions" />
        </div>
      </div>

      <div v-if="$slots.tabs" class="mt-3">
        <slot name="tabs" />
      </div>
    </header>

    <div class="flex-1 min-h-0 overflow-y-auto px-6 py-4">
      <div class="flex flex-col gap-4 w-full">
        <slot />
      </div>
    </div>
  </section>
</template>
