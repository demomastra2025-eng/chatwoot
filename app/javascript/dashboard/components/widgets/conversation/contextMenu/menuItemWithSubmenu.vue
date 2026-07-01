<script setup>
import { computed, ref, useTemplateRef } from 'vue';
import { useWindowSize, useElementBounding } from '@vueuse/core';

const props = defineProps({
  option: {
    type: Object,
    default: () => {},
  },
  subMenuAvailable: {
    type: Boolean,
    default: true,
  },
  mobile: {
    type: Boolean,
    default: false,
  },
});

const menuRef = useTemplateRef('menuRef');
const isSubmenuOpen = ref(false);
const { width: windowWidth, height: windowHeight } = useWindowSize();
const { bottom, right } = useElementBounding(menuRef);

// Vertical position
const verticalPosition = computed(() => {
  const SUBMENU_HEIGHT = 240; // 15rem in pixels
  const spaceBelow = windowHeight.value - bottom.value;
  return spaceBelow < SUBMENU_HEIGHT ? 'bottom-0' : 'top-0';
});

// Horizontal position
const horizontalPosition = computed(() => {
  const SUBMENU_WIDTH = 240;
  const spaceRight = windowWidth.value - right.value;
  return spaceRight < SUBMENU_WIDTH ? 'right-full' : 'left-full';
});

const submenuPosition = computed(() => [
  verticalPosition.value,
  horizontalPosition.value,
]);

const rootClass = computed(() => [
  !props.subMenuAvailable ? 'opacity-50 cursor-not-allowed' : '',
  props.mobile
    ? 'mobile-menu-with-submenu flex-col items-stretch gap-1'
    : 'items-center',
]);

const submenuClass = computed(() => {
  if (props.mobile) {
    return [
      'mobile-submenu static mt-1 w-full rounded-lg bg-n-alpha-1 p-1 shadow-none outline outline-1 outline-n-weak',
      'max-h-56 overflow-y-auto overflow-x-hidden cursor-pointer',
      isSubmenuOpen.value ? 'block' : 'hidden',
    ];
  }

  return [
    'submenu bg-n-alpha-3 backdrop-blur-[100px] p-1 shadow-lg rounded-md absolute hidden max-h-[15rem] overflow-y-auto overflow-x-hidden cursor-pointer',
    ...submenuPosition.value,
  ];
});

const toggleSubmenu = () => {
  if (!props.mobile || !props.subMenuAvailable) return;

  isSubmenuOpen.value = !isSubmenuOpen.value;
};
</script>

<template>
  <div
    ref="menuRef"
    class="text-n-slate-12 menu-with-submenu min-width-calc w-full p-1 flex min-h-7 rounded-md relative bg-n-alpha-3/50 backdrop-blur-[100px] justify-between hover:bg-n-brand/10 cursor-pointer dark:hover:bg-n-solid-3"
    :class="rootClass"
    role="button"
    tabindex="0"
    :aria-expanded="mobile ? isSubmenuOpen : undefined"
    @click.stop="toggleSubmenu"
    @keydown.enter.prevent="toggleSubmenu"
    @keydown.space.prevent="toggleSubmenu"
  >
    <div class="flex w-full items-center justify-between gap-2">
      <div class="flex h-4 min-w-0 items-center">
        <fluent-icon :icon="option.icon" size="14" class="menu-icon" />
        <p class="my-0 mx-2 min-w-0 truncate text-xs">{{ option.label }}</p>
      </div>
      <fluent-icon
        icon="chevron-right"
        size="12"
        class="flex-shrink-0 transition-transform"
        :class="{ 'rotate-90': mobile && isSubmenuOpen }"
      />
    </div>
    <div v-if="subMenuAvailable" :class="submenuClass">
      <slot />
    </div>
  </div>
</template>

<style scoped lang="scss">
.menu-with-submenu {
  min-width: calc(6.25rem * 2);

  &:not(.mobile-menu-with-submenu):hover {
    .submenu {
      @apply block;
    }
  }
}

.mobile-menu-with-submenu {
  min-width: 0;

  :deep(.menu) {
    width: 100%;
    min-width: 0;
  }
}
</style>
