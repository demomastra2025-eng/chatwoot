<script setup>
import { computed } from 'vue';
import { OnClickOutside } from '@vueuse/components';
import { useEventListener } from '@vueuse/core';

import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  bodyClass: {
    type: [String, Array, Object],
    default: '',
  },
  confirmLabel: {
    type: String,
    default: '',
  },
  contentClass: {
    type: [String, Array, Object],
    default: 'px-6 py-5',
  },
  description: {
    type: String,
    default: '',
  },
  disableConfirm: {
    type: Boolean,
    default: false,
  },
  closeOnOutside: {
    type: Boolean,
    default: true,
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
    default: 'lg',
    validator: value => ['sm', 'md', 'lg', 'xl'].includes(value),
  },
  panelClass: {
    type: [String, Array, Object],
    default: '',
  },
  placement: {
    type: String,
    default: 'right',
    validator: value => ['center', 'right'].includes(value),
  },
});

const emit = defineEmits(['close', 'confirm', 'update:modelValue']);

const clickOutsideIgnore = [
  '[data-modal-safe-interaction]',
  'dialog[open]',
  '.dashboard-combobox-dropdown',
  '.reka-date-time-picker__content',
  '.reka-color-picker__content',
];

const widthClass = computed(() => {
  const widthMap = {
    sm: 'max-w-md',
    lg: 'max-w-2xl',
    md: 'max-w-xl',
    xl: 'max-w-4xl',
  };

  return widthMap[props.width] || widthMap.lg;
});

const isCentered = computed(() => props.placement === 'center');

const overlayClass = computed(() => [
  'fixed inset-0 z-[110] bg-black/35 p-2 backdrop-blur-[4px] sm:p-3',
  isCentered.value ? 'flex items-center justify-center' : 'flex justify-end',
]);

const clickOutsideClass = computed(() => [
  'flex h-full w-full',
  isCentered.value ? 'items-center justify-center' : 'justify-end',
]);

const panelTransitionClasses = computed(() => {
  if (isCentered.value) {
    return {
      enterActive: 'transition-all duration-200 ease-out',
      enterFrom: 'scale-[0.98] opacity-0',
      enterTo: 'scale-100 opacity-100',
      leaveActive: 'transition-all duration-150 ease-in',
      leaveFrom: 'scale-100 opacity-100',
      leaveTo: 'scale-[0.98] opacity-0',
    };
  }

  return {
    enterActive: 'transition-transform duration-200 ease-out',
    enterFrom: 'translate-x-full',
    enterTo: 'translate-x-0',
    leaveActive: 'transition-transform duration-150 ease-in',
    leaveFrom: 'translate-x-0',
    leaveTo: 'translate-x-full',
  };
});

const close = () => {
  emit('update:modelValue', false);
  emit('close');
};

const confirm = () => emit('confirm');
const handleOutsideTrigger = () => {
  if (!props.closeOnOutside) {
    return;
  }

  close();
};

useEventListener(document, 'keydown', event => {
  if (event.key === 'Escape' && props.modelValue) {
    close();
  }
});
</script>

<template>
  <Teleport to="body">
    <Transition
      enter-active-class="transition-opacity duration-200 ease-out"
      enter-from-class="opacity-0"
      enter-to-class="opacity-100"
      leave-active-class="transition-opacity duration-150 ease-in"
      leave-from-class="opacity-100"
      leave-to-class="opacity-0"
    >
      <div v-if="modelValue" :class="overlayClass">
        <Transition
          :enter-active-class="panelTransitionClasses.enterActive"
          :enter-from-class="panelTransitionClasses.enterFrom"
          :enter-to-class="panelTransitionClasses.enterTo"
          :leave-active-class="panelTransitionClasses.leaveActive"
          :leave-from-class="panelTransitionClasses.leaveFrom"
          :leave-to-class="panelTransitionClasses.leaveTo"
        >
          <OnClickOutside
            :class="clickOutsideClass"
            :options="{ ignore: clickOutsideIgnore }"
            @trigger="handleOutsideTrigger"
          >
            <aside
              class="flex h-full w-full flex-col overflow-hidden border border-n-weak bg-n-solid-2 shadow-2xl sm:rounded-[1.75rem]"
              :class="[widthClass, panelClass]"
            >
              <header
                class="flex items-start justify-between gap-4 border-b border-n-weak bg-n-surface-1 px-6 py-4"
              >
                <div class="flex flex-col gap-1">
                  <h3 class="mb-0 text-lg font-semibold text-n-slate-12">
                    {{ title }}
                  </h3>
                  <p v-if="description" class="mb-0 text-sm text-n-slate-11">
                    {{ description }}
                  </p>
                </div>
                <Button
                  size="sm"
                  variant="ghost"
                  color="slate"
                  icon="i-lucide-x"
                  @click="close"
                />
              </header>

              <div class="flex-1 min-h-0 overflow-y-auto" :class="[bodyClass]">
                <div :class="contentClass">
                  <slot />
                </div>
              </div>

              <footer
                class="flex items-center justify-between gap-3 border-t border-n-weak bg-n-surface-1 px-6 py-4"
              >
                <slot name="footer">
                  <Button
                    size="sm"
                    variant="faded"
                    color="slate"
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
              </footer>
            </aside>
          </OnClickOutside>
        </Transition>
      </div>
    </Transition>
  </Teleport>
</template>
