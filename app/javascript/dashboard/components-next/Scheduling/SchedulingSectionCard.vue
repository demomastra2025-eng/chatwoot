<script setup>
const props = defineProps({
  borderless: {
    type: Boolean,
    default: false,
  },
  description: {
    type: String,
    default: '',
  },
  title: {
    type: String,
    default: '',
  },
});
</script>

<template>
  <section
    class="flex flex-col divide-y divide-n-weak overflow-hidden rounded-xl bg-n-solid-2"
    :class="
      props.borderless
        ? ''
        : 'outline outline-1 -outline-offset-1 outline-n-container'
    "
  >
    <header
      v-if="title || description || $slots.headerActions"
      class="flex flex-col gap-3 px-5 py-4 md:flex-row md:items-start md:justify-between"
    >
      <div class="flex flex-col gap-1">
        <h2 v-if="title" class="mb-0 text-heading-2 text-n-slate-12">
          {{ title }}
        </h2>
        <p v-if="description" class="mb-0 text-body-para text-n-slate-11">
          {{ description }}
        </p>
      </div>
      <div class="flex items-center gap-2 self-start md:self-auto">
        <slot name="headerActions" />
      </div>
    </header>
    <div class="px-5 py-4">
      <slot />
    </div>
  </section>
</template>
