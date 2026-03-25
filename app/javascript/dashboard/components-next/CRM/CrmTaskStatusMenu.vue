<script setup>
import { computed, ref } from 'vue';
import { OnClickOutside } from '@vueuse/components';
import { useI18n } from 'vue-i18n';

import Button from 'dashboard/components-next/button/Button.vue';
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
  neutral: {
    type: Boolean,
    default: false,
  },
  statuses: {
    type: Array,
    default: () => [],
  },
});

const emit = defineEmits(['update:modelValue']);
const { t } = useI18n();

const isOpen = ref(false);

const statusMetaById = computed(() =>
  props.statuses.reduce((result, status) => {
    result[Number(status.id)] = {
      category: status.category || 'open',
      icon:
        status.category === 'done'
          ? 'i-lucide-circle-check-big'
          : 'i-lucide-circle-dot',
      label: status.name,
    };
    return result;
  }, {})
);

const currentStatusId = computed(() => Number(props.modelValue));

const currentStatus = computed(
  () =>
    statusMetaById.value[currentStatusId.value] || {
      category: 'open',
      icon: 'i-lucide-circle-dot',
      label: t('CRM.GENERAL.EMPTY_VALUE'),
    }
);

const buttonColor = computed(() => {
  if (props.neutral) return 'slate';

  return currentStatus.value.category === 'done' ? 'teal' : 'slate';
});

const menuItems = computed(() =>
  props.statuses.map(status => ({
    action: 'select',
    icon:
      status.category === 'done'
        ? 'i-lucide-circle-check-big'
        : 'i-lucide-circle-dot',
    isSelected: Number(status.id) === currentStatusId.value,
    label: status.name,
    value: status.id,
  }))
);

const toggleMenu = () => {
  if (props.disabled) return;
  isOpen.value = !isOpen.value;
};

const handleAction = ({ value }) => {
  const nextStatusId = Number(value);

  if (nextStatusId !== currentStatusId.value) {
    emit('update:modelValue', nextStatusId);
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
            :class="currentStatus.icon"
            aria-hidden="true"
          />
          <span class="truncate">{{ currentStatus.label }}</span>
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
        class="top-9 min-w-[11rem] ltr:right-0 rtl:left-0"
        @action="handleAction"
      />
    </OnClickOutside>
  </div>
</template>
