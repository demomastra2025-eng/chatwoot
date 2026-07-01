<script setup>
import { computed, nextTick, ref } from 'vue';
import { OnClickOutside } from '@vueuse/components';
import { useEventListener } from '@vueuse/core';
import { useI18n } from 'vue-i18n';

import Button from 'dashboard/components-next/button/Button.vue';
import DropdownMenu from 'dashboard/components-next/dropdown-menu/DropdownMenu.vue';
import {
  APPOINTMENT_STATUS_ICONS,
  APPOINTMENT_STATUS_VALUES,
} from 'dashboard/routes/dashboard/scheduling/constants';

const props = defineProps({
  disabled: {
    type: Boolean,
    default: false,
  },
  modelValue: {
    type: String,
    default: 'scheduled',
  },
  neutral: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['update:modelValue']);
const { t } = useI18n();

const isOpen = ref(false);
const triggerRef = ref(null);
const dropdownStyle = ref({});
const teleportTarget = ref('body');

const statusLabels = computed(() => ({
  cancelled: t('SCHEDULING.APPOINTMENT_STATUS.cancelled'),
  completed: t('SCHEDULING.APPOINTMENT_STATUS.completed'),
  confirmed: t('SCHEDULING.APPOINTMENT_STATUS.confirmed'),
  no_show: t('SCHEDULING.APPOINTMENT_STATUS.no_show'),
  scheduled: t('SCHEDULING.APPOINTMENT_STATUS.scheduled'),
}));

const buttonColor = computed(() => {
  if (props.neutral) return 'slate';

  const colorMap = {
    cancelled: 'ruby',
    completed: 'slate',
    confirmed: 'blue',
    no_show: 'ruby',
    scheduled: 'amber',
  };

  return colorMap[props.modelValue] || colorMap.scheduled;
});

const currentLabel = computed(
  () => statusLabels.value[props.modelValue] || statusLabels.value.scheduled
);
const currentIcon = computed(
  () =>
    APPOINTMENT_STATUS_ICONS[props.modelValue] ||
    APPOINTMENT_STATUS_ICONS.scheduled
);

const menuItems = computed(() =>
  APPOINTMENT_STATUS_VALUES.map(value => ({
    action: 'select',
    icon: APPOINTMENT_STATUS_ICONS[value],
    isSelected: value === props.modelValue,
    label: statusLabels.value[value] || value,
    value,
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
  if (props.disabled) return;

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
  <div ref="triggerRef" class="relative" @click.stop>
    <OnClickOutside
      :options="{ ignore: ['.scheduling-status-menu-dropdown'] }"
      @trigger="isOpen = false"
    >
      <Button
        size="xs"
        :variant="neutral ? 'outline' : 'faded'"
        :color="buttonColor"
        no-animation
        :disabled="disabled"
        class="!h-7 !gap-1 !rounded-full !px-2.5 !text-xs !font-medium"
        @click.stop="toggleMenu"
      >
        <span class="inline-flex min-w-0 items-center gap-1.5">
          <span
            class="size-3.5 shrink-0"
            :class="currentIcon"
            aria-hidden="true"
          />
          <span class="truncate">{{ currentLabel }}</span>
          <span
            class="size-3.5 shrink-0"
            :class="[isOpen ? 'i-lucide-chevron-up' : 'i-lucide-chevron-down']"
            aria-hidden="true"
          />
        </span>
      </Button>

      <Teleport :to="teleportTarget">
        <DropdownMenu
          v-if="isOpen"
          :menu-items="menuItems"
          class="scheduling-status-menu-dropdown top-9 min-w-[11rem] !fixed"
          :style="dropdownStyle"
          @action="handleAction"
        />
      </Teleport>
    </OnClickOutside>
  </div>
</template>
