<script setup>
defineProps({
  description: {
    type: String,
    default: '',
  },
  title: {
    type: String,
    required: true,
  },
});
</script>

<template>
  <header class="bg-n-surface-1 px-5 pb-2 pt-4">
    <div
      class="flex flex-col gap-3 md:grid md:grid-cols-[minmax(0,max-content)_1fr_minmax(0,max-content)] md:items-center md:gap-4"
    >
      <div class="flex min-w-0 flex-col gap-1">
        <div class="flex min-w-0 flex-wrap items-center gap-3 md:gap-4">
          <div class="flex min-w-0 items-center gap-0.5">
            <h1 class="mb-0 text-lg font-semibold text-n-slate-12">
              {{ title }}
            </h1>

            <slot name="title-actions" />
          </div>

          <div
            v-if="$slots.left"
            class="flex min-w-0 flex-wrap items-center gap-2 md:pl-1"
          >
            <slot name="left" />
          </div>
        </div>

        <p v-if="description" class="mb-0 text-xs text-n-slate-11">
          {{ description }}
        </p>
      </div>

      <div
        v-if="$slots.center"
        class="flex flex-wrap items-center justify-center gap-2 min-w-0"
      >
        <slot name="center" />
      </div>

      <div
        class="flex items-center gap-2 self-start md:justify-end md:self-auto"
      >
        <slot name="actions" />
      </div>
    </div>
  </header>
</template>
