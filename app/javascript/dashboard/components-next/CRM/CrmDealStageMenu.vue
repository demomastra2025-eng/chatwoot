<script setup>
import { computed, nextTick, ref } from 'vue';
import { OnClickOutside } from '@vueuse/components';
import { useEventListener } from '@vueuse/core';
import { useI18n } from 'vue-i18n';

import Button from 'dashboard/components-next/button/Button.vue';
import DropdownMenu from 'dashboard/components-next/dropdown-menu/DropdownMenu.vue';
import { DEFAULT_STAGE_COLOR } from 'dashboard/stores/crm/stageColors';

const props = defineProps({
  disabled: {
    type: Boolean,
    default: false,
  },
  modelValue: {
    type: [String, Number],
    default: '',
  },
  stages: {
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
const currentStageId = computed(() => Number(props.modelValue));
const fallbackStageColor = DEFAULT_STAGE_COLOR;

const stageLabelById = computed(() =>
  props.stages.reduce((result, stage) => {
    result[Number(stage.id)] = stage.name;
    return result;
  }, {})
);

const stageColorById = computed(() =>
  props.stages.reduce((result, stage) => {
    result[Number(stage.id)] = stage.color || fallbackStageColor;
    return result;
  }, {})
);

const currentStageLabel = computed(
  () =>
    stageLabelById.value[currentStageId.value] || t('CRM.GENERAL.EMPTY_VALUE')
);

const currentStageColor = computed(
  () => stageColorById.value[currentStageId.value] || fallbackStageColor
);

const menuItems = computed(() =>
  props.stages.map(stage => ({
    action: 'select',
    color: stage.color || fallbackStageColor,
    isSelected: Number(stage.id) === currentStageId.value,
    label: stage.name,
    value: stage.id,
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
  const nextStageId = Number(value);

  if (nextStageId !== currentStageId.value) {
    emit('update:modelValue', nextStageId);
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
      :options="{ ignore: ['.crm-deal-stage-menu-dropdown'] }"
      @trigger="isOpen = false"
    >
      <Button
        size="xs"
        variant="ghost"
        color="slate"
        no-animation
        :disabled="disabled"
        class="!h-7 !gap-1 !rounded-full !bg-transparent !px-1.5 !text-xs !font-medium"
        @click.stop="toggleMenu"
      >
        <span class="inline-flex min-w-0 items-center gap-1.5">
          <span
            class="size-2.5 shrink-0 rounded-full outline outline-1 outline-black/10 dark:outline-white/10"
            :style="{ backgroundColor: currentStageColor }"
          />
          <span class="truncate">{{ currentStageLabel }}</span>
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
          class="crm-deal-stage-menu-dropdown top-9 min-w-[11rem] !fixed !z-[240]"
          @action="handleAction"
        >
          <template #thumbnail="{ item }">
            <span
              class="size-2.5 shrink-0 rounded-full outline outline-1 outline-black/10 dark:outline-white/10"
              :style="{ backgroundColor: item.color || fallbackStageColor }"
            />
          </template>
        </DropdownMenu>
      </Teleport>
    </OnClickOutside>
  </div>
</template>
