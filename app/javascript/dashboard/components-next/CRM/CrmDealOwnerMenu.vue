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
    type: [String, Number],
    default: '',
  },
  owners: {
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
const currentOwnerId = computed(() => Number(props.modelValue));

const ownerMetaById = computed(() =>
  props.owners.reduce((result, owner) => {
    result[Number(owner.value)] = {
      label: owner.label,
      thumbnail: owner.thumbnail,
    };
    return result;
  }, {})
);

const currentOwner = computed(
  () =>
    ownerMetaById.value[currentOwnerId.value] || {
      label: t('CRM.GENERAL.EMPTY_VALUE'),
      thumbnail: null,
    }
);

const menuItems = computed(() =>
  props.owners.map(owner => ({
    action: 'select',
    isSelected: Number(owner.value) === currentOwnerId.value,
    label: owner.label,
    thumbnail: owner.thumbnail,
    value: owner.value,
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
    Math.max(rect.width, 192),
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
  const nextOwnerId = Number(value);

  if (nextOwnerId !== currentOwnerId.value) {
    emit('update:modelValue', nextOwnerId);
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
      :options="{ ignore: ['.crm-deal-owner-menu-dropdown'] }"
      @trigger="isOpen = false"
    >
      <button
        type="button"
        :disabled="disabled || !menuItems.length"
        class="inline-flex h-6 max-w-full items-center gap-1 rounded-md bg-n-alpha-black2 px-1.5 text-[9px] font-medium text-n-slate-12 transition-colors hover:bg-n-alpha-black3 disabled:cursor-not-allowed disabled:opacity-50"
        @click.stop="toggleMenu"
      >
        <span class="inline-flex min-w-0 items-center gap-1.5">
          <span class="truncate">{{ currentOwner.label }}</span>
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
          :show-search="owners.length > 8"
          :style="dropdownStyle"
          label-class="!text-[11px]"
          class="crm-deal-owner-menu-dropdown top-8 min-w-[12rem] !fixed !z-[240]"
          @action="handleAction"
        />
      </Teleport>
    </OnClickOutside>
  </div>
</template>
