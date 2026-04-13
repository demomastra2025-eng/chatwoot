<script setup>
import { computed, nextTick, ref, watch } from 'vue';

import TeleportWithDirection from 'dashboard/components-next/TeleportWithDirection.vue';

const props = defineProps({
  items: {
    type: Array,
    required: true,
  },
  overlay: {
    type: Boolean,
    default: false,
  },
  selectedIndex: {
    type: Number,
    default: 0,
  },
});

const emit = defineEmits(['close', 'select']);

const toolsDropdownRef = ref(null);

const onItemClick = idx => emit('select', idx);
const closeOverlay = () => emit('close');

const dropdownClass = computed(() => {
  if (props.overlay) {
    return 'relative z-[1201] flex w-full max-w-xl flex-col gap-1 overflow-y-auto rounded-2xl bg-n-alpha-3 p-2 shadow-xl outline outline-1 outline-n-weak backdrop-blur-[50px] max-h-[min(32rem,calc(100vh-6rem))]';
  }

  return 'absolute bottom-20 z-50 flex w-[22.5rem] flex-col gap-1 overflow-y-auto rounded-xl bg-n-alpha-3 p-2 shadow outline outline-1 outline-n-weak backdrop-blur-[50px] max-h-[20rem]';
});

watch(
  () => props.selectedIndex,
  () => {
    nextTick(() => {
      const el = toolsDropdownRef.value?.querySelector(
        `#tool-item-${props.selectedIndex}`
      );
      if (el) {
        el.scrollIntoView({ block: 'nearest', behavior: 'auto' });
      }
    });
  },
  { immediate: true }
);
</script>

<template>
  <TeleportWithDirection v-if="overlay" to="body">
    <div class="fixed inset-0 z-[1200] flex items-center justify-center p-4">
      <button
        type="button"
        class="absolute inset-0 bg-n-alpha-black1 backdrop-blur-[4px]"
        @click="closeOverlay"
      />

      <div ref="toolsDropdownRef" :class="dropdownClass" @click.stop>
        <div
          v-for="(tool, idx) in items"
          :id="`tool-item-${idx}`"
          :key="tool.id || idx"
          :class="{ 'bg-n-alpha-black2': idx === selectedIndex }"
          class="flex cursor-pointer flex-col gap-1 rounded-md px-2 py-2 hover:bg-n-alpha-black2"
          @click="onItemClick(idx)"
        >
          <div class="flex items-center gap-2">
            <span class="text-sm font-medium text-n-slate-12">
              {{ tool.title }}
            </span>
            <span
              v-if="tool.group_name"
              class="rounded-full bg-n-alpha-black2 px-2 py-0.5 text-[0.6875rem] font-medium text-n-slate-11"
            >
              {{ tool.group_name }}
            </span>
          </div>
          <span class="text-sm text-n-slate-11">{{ tool.description }}</span>
        </div>
      </div>
    </div>
  </TeleportWithDirection>

  <div v-else ref="toolsDropdownRef" :class="dropdownClass">
    <div
      v-for="(tool, idx) in items"
      :id="`tool-item-${idx}`"
      :key="tool.id || idx"
      :class="{ 'bg-n-alpha-black2': idx === selectedIndex }"
      class="flex cursor-pointer flex-col gap-1 rounded-md px-2 py-2 hover:bg-n-alpha-black2"
      @click="onItemClick(idx)"
    >
      <div class="flex items-center gap-2">
        <span class="text-sm font-medium text-n-slate-12">{{
          tool.title
        }}</span>
        <span
          v-if="tool.group_name"
          class="rounded-full bg-n-alpha-black2 px-2 py-0.5 text-[0.6875rem] font-medium text-n-slate-11"
        >
          {{ tool.group_name }}
        </span>
      </div>
      <span class="text-sm text-n-slate-11">{{ tool.description }}</span>
    </div>
  </div>
</template>
