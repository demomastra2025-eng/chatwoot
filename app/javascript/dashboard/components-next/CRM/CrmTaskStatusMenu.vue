<script setup>
import { computed, nextTick, ref } from 'vue';
import { OnClickOutside } from '@vueuse/components';
import { useEventListener } from '@vueuse/core';
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
  borderless: {
    type: Boolean,
    default: false,
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
const triggerRef = ref(null);
const dropdownStyle = ref({});
const teleportTarget = ref('body');
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

const buttonVariant = computed(() => {
  if (props.borderless) return 'ghost';
  return props.neutral ? 'outline' : 'faded';
});

const buttonClass = computed(() => {
  if (props.borderless) {
    return '!h-6 !gap-1 !rounded-full !bg-transparent !px-1.5 !text-xs !font-medium';
  }

  return '!h-7 !gap-1 !rounded-full !px-2.5 !text-xs !font-medium';
});

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
  const nextStatusId = Number(value);

  if (nextStatusId !== currentStatusId.value) {
    emit('update:modelValue', nextStatusId);
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
      :options="{ ignore: ['.crm-task-status-menu-dropdown'] }"
      @trigger="isOpen = false"
    >
      <Button
        size="xs"
        :variant="buttonVariant"
        color="slate"
        no-animation
        :disabled="disabled"
        :class="buttonClass"
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

      <Teleport :to="teleportTarget">
        <DropdownMenu
          v-if="isOpen"
          :menu-items="menuItems"
          :style="dropdownStyle"
          class="crm-task-status-menu-dropdown top-9 min-w-[11rem] !fixed !z-[240]"
          @action="handleAction"
        >
          <template #thumbnail="{ item }">
            <span
              class="size-2.5 shrink-0 rounded-full outline outline-1 outline-black/10 dark:outline-white/10"
              :style="{
                backgroundColor: item.color || fallbackTaskStatusColor,
              }"
            />
          </template>
        </DropdownMenu>
      </Teleport>
    </OnClickOutside>
  </div>
</template>
