<script setup>
import { computed } from 'vue';
import { useRouter } from 'vue-router';

const props = defineProps({
  items: { type: Array, default: () => [] },
  activeChildNames: { type: Array, default: () => [] },
});

const emit = defineEmits(['select']);
const router = useRouter();

const isActive = item => props.activeChildNames.includes(item.name);
const counterLabel = item => {
  const count = Number(item.count) || 0;
  return String(count);
};

const visibleItems = computed(() => props.items.filter(item => item.to));

const handleSelect = async item => {
  if (!item.to || isActive(item)) return;
  await router.push(item.to);
  emit('select');
};
</script>

<template>
  <li v-show="visibleItems.length" class="my-1 list-none -mx-1">
    <div class="grid grid-cols-2 gap-0.5 rounded-lg bg-n-alpha-2 p-0.5">
      <button
        v-for="item in visibleItems"
        :key="item.name"
        type="button"
        class="flex h-7 min-w-0 items-center justify-center gap-0.5 rounded-md px-0.5 text-[11px] font-medium transition-colors"
        :class="
          isActive(item)
            ? 'bg-n-solid-1 text-n-blue-11 shadow-sm'
            : 'text-n-slate-10 hover:text-n-slate-12'
        "
        :title="item.label"
        @click="handleSelect(item)"
      >
        <span class="truncate">{{ item.label }}</span>
        <span
          class="shrink-0 text-[10px] tabular-nums"
          :class="isActive(item) ? 'text-n-blue-11' : 'text-n-slate-9'"
        >
          {{ counterLabel(item) }}
        </span>
      </button>
    </div>
  </li>
</template>
