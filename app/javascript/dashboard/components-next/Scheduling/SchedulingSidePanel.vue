<script setup>
import { computed } from 'vue';
import { OnClickOutside } from '@vueuse/components';
import { useEventListener } from '@vueuse/core';

import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  closeOnClickOutside: {
    type: Boolean,
    default: true,
  },
  confirmLabel: {
    type: String,
    default: '',
  },
  description: {
    type: String,
    default: '',
  },
  disableConfirm: {
    type: Boolean,
    default: false,
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
    validator: value => ['xs', 'sm', 'md', 'lg', 'xl'].includes(value),
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

const desktopWidthClass = computed(() => {
  const widthMap = {
    xs: 'md:w-[22rem] md:min-w-[22rem] xl:w-[28rem] xl:min-w-[28rem]',
    sm: 'md:w-[30rem] md:min-w-[30rem]',
    md: 'md:w-[34rem] md:min-w-[34rem] xl:w-[40rem] xl:min-w-[40rem]',
    lg: 'md:w-[36rem] md:min-w-[36rem] xl:w-[46rem] xl:min-w-[46rem]',
    xl: 'md:w-[38rem] md:min-w-[38rem] xl:w-[54rem] xl:min-w-[54rem]',
  };

  return widthMap[props.width] || widthMap.lg;
});

const mobileWidthClass = computed(() => {
  const widthMap = {
    xs: 'max-w-[22rem] sm:max-w-[24rem]',
    sm: 'max-w-md',
    md: 'max-w-xl',
    lg: 'max-w-2xl',
    xl: 'max-w-4xl',
  };

  return widthMap[props.width] || widthMap.lg;
});

const close = () => {
  emit('update:modelValue', false);
  emit('close');
};

const confirm = () => emit('confirm');

const handleClickOutside = () => {
  if (!props.closeOnClickOutside) {
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
  <Transition
    enter-active-class="transition-opacity duration-200 ease-out"
    enter-from-class="opacity-0"
    enter-to-class="opacity-100"
    leave-active-class="transition-opacity duration-150 ease-in"
    leave-from-class="opacity-100"
    leave-to-class="opacity-0"
  >
    <div
      v-if="modelValue"
      class="fixed inset-0 z-[110] flex justify-end bg-black/35 p-2 backdrop-blur-[4px] sm:p-3 md:hidden"
    >
      <Transition
        enter-active-class="transition-transform duration-200 ease-out"
        enter-from-class="translate-x-full"
        enter-to-class="translate-x-0"
        leave-active-class="transition-transform duration-150 ease-in"
        leave-from-class="translate-x-0"
        leave-to-class="translate-x-full"
      >
        <OnClickOutside
          class="flex w-full justify-end"
          :options="{ ignore: clickOutsideIgnore }"
          @trigger="handleClickOutside"
        >
          <aside
            class="flex h-full w-full flex-col overflow-hidden border border-n-weak bg-n-solid-2 shadow-2xl sm:rounded-[1.75rem]"
            :class="mobileWidthClass"
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

            <div class="min-h-0 flex-1 overflow-y-auto">
              <div class="px-6 py-5">
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

  <Transition
    enter-active-class="transition-all duration-200 ease-out"
    enter-from-class="translate-x-8 opacity-0"
    enter-to-class="translate-x-0 opacity-100"
    leave-active-class="transition-all duration-150 ease-in"
    leave-from-class="translate-x-0 opacity-100"
    leave-to-class="translate-x-8 opacity-0"
  >
    <aside
      v-if="modelValue"
      class="hidden h-full min-h-0 flex-col overflow-hidden border-l border-n-weak bg-n-solid-2 shadow-[-24px_0_48px_rgba(15,23,42,0.08)] md:flex"
      :class="desktopWidthClass"
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

      <div class="min-h-0 flex-1 overflow-y-auto">
        <div class="px-6 py-5">
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
  </Transition>
</template>
