<script setup>
import { computed } from 'vue';

const props = defineProps({
  columnCount: {
    type: Number,
    default: 4,
  },
  presentation: {
    type: String,
    default: 'board',
    validator: value => ['board', 'calendar', 'list'].includes(value),
  },
});

const boardColumnCount = computed(() =>
  Math.min(Math.max(Number(props.columnCount) || 4, 3), 6)
);
</script>

<template>
  <div
    class="w-full animate-pulse"
    data-test="crm-page-skeleton"
    :data-presentation="presentation"
    aria-hidden="true"
  >
    <div
      v-if="presentation === 'board'"
      class="flex min-h-[28rem] gap-3 overflow-hidden"
    >
      <section
        v-for="column in boardColumnCount"
        :key="column"
        class="min-w-[15rem] flex-1 rounded-xl bg-n-alpha-1 p-3 outline outline-1 outline-n-container"
      >
        <header class="mb-3 flex items-center justify-between gap-3">
          <span class="h-4 w-24 rounded bg-n-alpha-3" />
          <span class="size-5 rounded-full bg-n-alpha-3" />
        </header>
        <div class="grid gap-2">
          <article
            v-for="card in 3"
            :key="card"
            class="rounded-xl bg-n-solid-2 p-3 outline outline-1 outline-n-weak"
          >
            <span class="mb-3 block h-4 w-4/5 rounded bg-n-alpha-3" />
            <span class="mb-2 block h-3 w-2/5 rounded bg-n-alpha-2" />
            <div class="mt-4 flex items-center justify-between">
              <span class="size-6 rounded-full bg-n-alpha-3" />
              <span class="h-3 w-16 rounded bg-n-alpha-2" />
            </div>
          </article>
        </div>
      </section>
    </div>

    <div
      v-else-if="presentation === 'calendar'"
      class="overflow-hidden rounded-xl outline outline-1 outline-n-container"
    >
      <div class="grid grid-cols-7 border-b border-n-weak bg-n-surface-2/80">
        <span
          v-for="day in 7"
          :key="day"
          class="h-11 border-r border-n-weak p-3 last:border-r-0"
        >
          <span class="block h-3 w-3/5 rounded bg-n-alpha-3" />
        </span>
      </div>
      <div class="grid grid-cols-7">
        <div
          v-for="cell in 28"
          :key="cell"
          class="h-24 border-b border-n-weak p-2"
          :class="cell % 7 === 0 ? 'border-r-0' : 'border-r'"
        >
          <span class="block h-3 w-5 rounded bg-n-alpha-2" />
          <span
            v-if="cell % 3 === 0"
            class="mt-3 block h-8 rounded-md bg-n-alpha-3"
          />
        </div>
      </div>
    </div>

    <div
      v-else
      class="overflow-hidden rounded-xl outline outline-1 outline-n-container"
    >
      <div
        class="grid grid-cols-[2fr_1fr_1fr_1fr] gap-4 border-b border-n-weak bg-n-surface-2/80 px-5 py-3"
      >
        <span
          v-for="column in 4"
          :key="column"
          class="h-3 rounded bg-n-alpha-3"
        />
      </div>
      <div
        v-for="row in 7"
        :key="row"
        class="grid grid-cols-[2fr_1fr_1fr_1fr] items-center gap-4 border-b border-n-weak px-5 py-3 last:border-b-0"
      >
        <div class="flex items-center gap-3">
          <span class="size-7 shrink-0 rounded-full bg-n-alpha-3" />
          <span class="h-4 w-3/4 rounded bg-n-alpha-3" />
        </div>
        <span class="h-4 w-4/5 rounded bg-n-alpha-2" />
        <span class="h-4 w-3/5 rounded bg-n-alpha-2" />
        <span class="h-4 w-2/3 rounded bg-n-alpha-2" />
      </div>
    </div>
  </div>
</template>
