<script setup>
import { computed, ref } from 'vue';
import { OnClickOutside } from '@vueuse/components';
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
    completed: 'teal',
    confirmed: 'blue',
    no_show: 'amber',
    scheduled: 'slate',
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

const toggleMenu = () => {
  if (props.disabled) return;
  isOpen.value = !isOpen.value;
};

const handleAction = ({ value }) => {
  if (value !== props.modelValue) {
    emit('update:modelValue', value);
  }

  isOpen.value = false;
};
</script>

<template>
  <div class="relative" @click.stop>
    <OnClickOutside @trigger="isOpen = false">
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

      <DropdownMenu
        v-if="isOpen"
        :menu-items="menuItems"
        class="ltr:right-0 rtl:left-0 top-9 min-w-[11rem]"
        @action="handleAction"
      />
    </OnClickOutside>
  </div>
</template>
