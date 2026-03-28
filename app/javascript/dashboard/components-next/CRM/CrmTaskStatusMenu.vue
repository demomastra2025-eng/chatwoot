<script setup>
import { computed, ref } from 'vue';
import { OnClickOutside } from '@vueuse/components';
import { useI18n } from 'vue-i18n';

import Button from 'dashboard/components-next/button/Button.vue';
import DropdownMenu from 'dashboard/components-next/dropdown-menu/DropdownMenu.vue';
import { DEFAULT_TASK_STATUS_COLOR } from 'dashboard/stores/crm/taskStatusColors';

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
const fallbackTaskStatusColor = DEFAULT_TASK_STATUS_COLOR;

const statusMetaById = computed(() =>
  props.statuses.reduce((result, status) => {
    result[Number(status.id)] = {
      category: status.category || 'open',
      color: status.color || fallbackTaskStatusColor,
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
      color: fallbackTaskStatusColor,
      label: t('CRM.GENERAL.EMPTY_VALUE'),
    }
);

const menuItems = computed(() =>
  props.statuses.map(status => ({
    action: 'select',
    color: status.color || fallbackTaskStatusColor,
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
        color="slate"
        no-animation
        :disabled="disabled"
        class="!h-7 !gap-1 !rounded-full !px-2.5 !text-xs !font-medium"
        @click.stop="toggleMenu"
      >
        <span class="inline-flex min-w-0 items-center gap-1.5">
          <span
            class="size-2.5 shrink-0 rounded-full outline outline-1 outline-black/10 dark:outline-white/10"
            :style="{
              backgroundColor: currentStatus.color || fallbackTaskStatusColor,
            }"
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
      >
        <template #thumbnail="{ item }">
          <span
            class="size-2.5 shrink-0 rounded-full outline outline-1 outline-black/10 dark:outline-white/10"
            :style="{ backgroundColor: item.color || fallbackTaskStatusColor }"
          />
        </template>
      </DropdownMenu>
    </OnClickOutside>
  </div>
</template>
