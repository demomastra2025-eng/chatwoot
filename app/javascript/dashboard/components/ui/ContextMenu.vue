<script setup>
import {
  computed,
  onMounted,
  nextTick,
  onUnmounted,
  useTemplateRef,
  inject,
} from 'vue';
import { useWindowSize, useElementBounding, useScrollLock } from '@vueuse/core';

import TeleportWithDirection from 'dashboard/components-next/TeleportWithDirection.vue';

const props = defineProps({
  x: { type: Number, default: 0 },
  y: { type: Number, default: 0 },
  mobile: { type: Boolean, default: false },
});

const emit = defineEmits(['close']);

const elementToLock = inject('contextMenuElementTarget', null);

const menuRef = useTemplateRef('menuRef');

const scrollLockElement = computed(() => {
  if (!elementToLock?.value) return null;
  return elementToLock.value?.$el;
});

const isLocked = useScrollLock(scrollLockElement);

const { width: windowWidth, height: windowHeight } = useWindowSize();
const { width: menuWidth, height: menuHeight } = useElementBounding(menuRef);

const calculatePosition = (x, y, menuW, menuH, windowW, windowH) => {
  const PADDING = 16;
  // Initial position
  let left = x;
  let top = y;
  // Boundary checks
  const isOverflowingRight = left + menuW > windowW - PADDING;
  const isOverflowingBottom = top + menuH > windowH - PADDING;
  // Adjust position if overflowing
  if (isOverflowingRight) left = windowW - menuW - PADDING;
  if (isOverflowingBottom) top = windowH - menuH - PADDING;
  return {
    left: Math.max(PADDING, left),
    top: Math.max(PADDING, top),
  };
};

const position = computed(() => {
  if (!menuRef.value) return { top: `${props.y}px`, left: `${props.x}px` };

  const { left, top } = calculatePosition(
    props.x,
    props.y,
    menuWidth.value,
    menuHeight.value,
    windowWidth.value,
    windowHeight.value
  );

  return {
    top: `${top}px`,
    left: `${left}px`,
  };
});

onMounted(() => {
  isLocked.value = true;
  nextTick(() => menuRef.value?.focus());
});

const handleClose = () => {
  isLocked.value = false;
  emit('close');
};

onUnmounted(() => {
  isLocked.value = false;
});
</script>

<template>
  <TeleportWithDirection to="body">
    <div
      v-if="mobile"
      data-test-id="mobile-context-menu-backdrop"
      class="fixed inset-0 z-[9999] cursor-default bg-n-alpha-black1 backdrop-blur-[2px]"
      @click.self="handleClose"
    >
      <div
        ref="menuRef"
        data-test-id="mobile-context-menu-sheet"
        class="fixed inset-x-3 bottom-3 max-h-[80dvh] overflow-y-auto rounded-2xl bg-n-solid-1 p-2 shadow-2xl outline outline-1 outline-n-weak"
        tabindex="0"
        @keydown.esc="handleClose"
      >
        <slot />
      </div>
    </div>
    <div
      v-else
      ref="menuRef"
      class="fixed outline-none z-[9999] cursor-pointer"
      :style="position"
      tabindex="0"
      @blur="handleClose"
      @keydown.esc="handleClose"
    >
      <slot />
    </div>
  </TeleportWithDirection>
</template>
