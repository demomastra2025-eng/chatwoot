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
      class="flex min-w-0 flex-col gap-3 md:flex-row md:flex-wrap md:items-start md:gap-4"
    >
      <div class="flex min-w-0 flex-1 flex-col gap-1">
        <div class="flex min-w-0 flex-wrap items-center gap-3 md:gap-4">
          <div class="flex min-w-0 items-center gap-0.5">
            <slot name="title">
              <h1 class="mb-0 text-lg font-semibold text-n-slate-12">
                {{ title }}
              </h1>
            </slot>

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
        class="flex min-w-0 flex-wrap items-center justify-center gap-2"
      >
        <slot name="center" />
      </div>

      <div
        class="flex min-w-0 flex-wrap items-center gap-2 self-start md:ml-auto md:justify-end md:self-auto"
      >
        <slot name="actions" />
      </div>
    </div>
  </header>
</template>
