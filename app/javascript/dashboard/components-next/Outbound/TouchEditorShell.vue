<script setup>
import { computed } from 'vue';

import SchedulingDrawer from 'dashboard/components-next/Scheduling/SchedulingDrawer.vue';
import SidebarActionsHeader from 'dashboard/components-next/SidebarActionsHeader.vue';
import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  confirmLabel: {
    type: String,
    default: '',
  },
  description: {
    type: String,
    default: '',
  },
  closeOnOutside: {
    type: Boolean,
    default: true,
  },
  disableConfirm: {
    type: Boolean,
    default: false,
  },
  displayMode: {
    type: String,
    default: 'drawer',
    validator: value => ['drawer', 'sidebar'].includes(value),
  },
  isLoading: {
    type: Boolean,
    default: false,
  },
  modelValue: {
    type: Boolean,
    default: false,
  },
  title: {
    type: String,
    default: '',
  },
  width: {
    type: String,
    default: 'sm',
  },
  panelClass: {
    type: [String, Array, Object],
    default: '',
  },
});

const emit = defineEmits(['close', 'confirm', 'update:modelValue']);

const isSidebar = computed(() => props.displayMode === 'sidebar');

const close = () => {
  emit('update:modelValue', false);
  emit('close');
};

const confirm = () => emit('confirm');
</script>

<template>
  <SchedulingDrawer
    v-if="!isSidebar"
    :model-value="modelValue"
    :title="title"
    :description="description"
    :confirm-label="confirmLabel"
    :is-loading="isLoading"
    :close-on-outside="closeOnOutside"
    :disable-confirm="disableConfirm"
    :width="width"
    :panel-class="panelClass"
    @update:model-value="emit('update:modelValue', $event)"
    @close="close"
    @confirm="confirm"
  >
    <slot />

    <template #footer>
      <slot name="footer" />
    </template>
  </SchedulingDrawer>

  <div v-else-if="modelValue" class="flex h-full w-full flex-col">
    <SidebarActionsHeader :title="title" @close="close" />

    <div class="min-h-0 flex-1 overflow-y-auto">
      <div v-if="description" class="px-4 pt-4 text-sm text-n-slate-11">
        {{ description }}
      </div>
      <div class="px-4 py-4">
        <slot />
      </div>
    </div>

    <div
      class="flex items-center justify-between gap-3 border-t border-n-weak bg-n-surface-1 px-4 py-3"
    >
      <slot name="footer">
        <Button
          size="sm"
          color="slate"
          variant="faded"
          :label="$t('SCHEDULING.GENERAL.CANCEL')"
          @click="close"
        />
        <Button
          size="sm"
          :is-loading="isLoading"
          :disabled="disableConfirm || isLoading"
          :label="confirmLabel || $t('SCHEDULING.GENERAL.SAVE')"
          @click="confirm"
        />
      </slot>
    </div>
  </div>
</template>
