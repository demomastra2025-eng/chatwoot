<script setup>
import { computed, nextTick, ref } from 'vue';
import { OnClickOutside } from '@vueuse/components';
import { useEventListener } from '@vueuse/core';
import { useI18n } from 'vue-i18n';

import DropdownMenu from 'dashboard/components-next/dropdown-menu/DropdownMenu.vue';

const props = defineProps({
  disabled: {
    type: Boolean,
    default: false,
  },
  modelValue: {
    type: String,
    default: '',
  },
  options: {
    type: Array,
    default: () => [],
  },
});

const emit = defineEmits(['update:modelValue']);
const { t } = useI18n();

const isOpen = ref(false);
const triggerRef = ref(null);
const dropdownStyle = ref({});
const teleportTarget = ref('body');

const currentPriorityMeta = computed(() => {
  return (
    props.options.find(option => option.value === props.modelValue) || {
      label: t('CRM.GENERAL.EMPTY_VALUE'),
      value: '',
    }
  );
});

const menuItems = computed(() =>
  props.options.map(option => ({
    action: 'select',
    isSelected: option.value === props.modelValue,
    label: option.label,
    value: option.value,
  }))
);

const resolveTeleportTarget = () => {
  const overlayElement = triggerRef.value?.closest('dialog[open], .modal-mask');
  teleportTarget.value = overlayElement || 'body';
};

const updateDropdownPosition = () => {
  if (!isOpen.value || !triggerRef.value) return;

  const rect = triggerRef.value.getBoundingClientRect();
  const viewportPadding = 8;
  const width = Math.min(
    Math.max(rect.width, 176),
    window.innerWidth - viewportPadding * 2
  );
  const left = Math.min(
    Math.max(rect.right - width, viewportPadding),
    window.innerWidth - width - viewportPadding
  );
  const top = Math.max(rect.bottom + 8, viewportPadding);
  const maxHeight = Math.max(window.innerHeight - top - viewportPadding, 160);

  dropdownStyle.value = {
    left: `${Math.round(left)}px`,
    maxHeight: `${Math.round(maxHeight)}px`,
    top: `${Math.round(top)}px`,
    width: `${Math.round(width)}px`,
  };
};

const toggleMenu = () => {
  if (props.disabled || !menuItems.value.length) return;

  isOpen.value = !isOpen.value;

  if (!isOpen.value) return;

  resolveTeleportTarget();
  nextTick(() => {
    updateDropdownPosition();
  });
};

const handleAction = ({ value }) => {
  if (value !== props.modelValue) {
    emit('update:modelValue', value);
  }

  isOpen.value = false;
};

useEventListener(window, 'resize', updateDropdownPosition);
useEventListener(window, 'scroll', updateDropdownPosition, {
  capture: true,
  passive: true,
});
</script>

<template>
  <div
    ref="triggerRef"
    class="relative max-w-[8.5rem]"
    :class="isOpen ? 'z-[240]' : 'z-[1]'"
    @click.stop
  >
    <OnClickOutside
      :options="{ ignore: ['.crm-task-priority-menu-dropdown'] }"
      @trigger="isOpen = false"
    >
      <button
        type="button"
        :disabled="disabled || !menuItems.length"
        class="inline-flex h-6 max-w-full items-center gap-1 rounded-md bg-n-alpha-black2 px-1.5 text-[10px] font-medium text-n-slate-12 transition-colors hover:bg-n-alpha-black3 disabled:cursor-not-allowed disabled:opacity-50"
        @click.stop="toggleMenu"
      >
        <span class="inline-flex min-w-0 items-center gap-1.5">
          <span class="truncate">{{ currentPriorityMeta.label }}</span>
          <span
            class="inline-flex size-3 shrink-0 items-center justify-center opacity-55"
            aria-hidden="true"
          >
            <span
              class="size-3"
              :class="[
                isOpen ? 'i-lucide-chevron-up' : 'i-lucide-chevron-down',
              ]"
            />
          </span>
        </span>
      </button>

      <Teleport :to="teleportTarget">
        <DropdownMenu
          v-if="isOpen"
          :menu-items="menuItems"
          :style="dropdownStyle"
          class="crm-task-priority-menu-dropdown top-8 min-w-[11rem] !fixed !z-[240]"
          @action="handleAction"
        />
      </Teleport>
    </OnClickOutside>
  </div>
</template>
