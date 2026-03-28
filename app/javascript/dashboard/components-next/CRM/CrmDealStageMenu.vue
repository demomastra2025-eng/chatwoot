<script setup>
import { computed, ref } from 'vue';
import { OnClickOutside } from '@vueuse/components';
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

const toggleMenu = () => {
  if (props.disabled) return;
  isOpen.value = !isOpen.value;
};

const handleAction = ({ value }) => {
  const nextStageId = Number(value);

  if (nextStageId !== currentStageId.value) {
    emit('update:modelValue', nextStageId);
  }

  isOpen.value = false;
};
</script>

<template>
  <div class="relative" @click.stop>
    <OnClickOutside @trigger="isOpen = false">
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

      <DropdownMenu
        v-if="isOpen"
        :menu-items="menuItems"
        class="top-9 min-w-[11rem] ltr:right-0 rtl:left-0"
        @action="handleAction"
      >
        <template #thumbnail="{ item }">
          <span
            class="size-2.5 shrink-0 rounded-full outline outline-1 outline-black/10 dark:outline-white/10"
            :style="{ backgroundColor: item.color || fallbackStageColor }"
          />
        </template>
      </DropdownMenu>
    </OnClickOutside>
  </div>
</template>
