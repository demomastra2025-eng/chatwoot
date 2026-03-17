<script setup>
import { computed } from 'vue';
import { OnClickOutside } from '@vueuse/components';
import { useEventListener } from '@vueuse/core';

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
    validator: value => ['md', 'lg', 'xl'].includes(value),
  },
});

const emit = defineEmits(['close', 'confirm', 'update:modelValue']);

const widthClass = computed(() => {
  const widthMap = {
    lg: 'max-w-2xl',
    md: 'max-w-xl',
    xl: 'max-w-4xl',
  };

  return widthMap[props.width] || widthMap.lg;
});

const close = () => {
  emit('update:modelValue', false);
  emit('close');
};

const confirm = () => emit('confirm');

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
      <div
        v-if="modelValue"
        class="fixed inset-0 z-[110] flex justify-end bg-black/35 p-2 backdrop-blur-[4px] sm:p-3"
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
            class="flex justify-end w-full"
            :options="{
              ignore: [
                '.dashboard-combobox-dropdown',
                '.reka-date-time-picker__content',
                '.reka-color-picker__content',
              ],
            }"
            @trigger="close"
          >
            <aside
              class="flex h-full w-full flex-col overflow-hidden border border-n-weak bg-n-solid-2 shadow-2xl sm:rounded-[1.75rem]"
              :class="widthClass"
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

              <div class="flex-1 min-h-0 overflow-y-auto">
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
  </Teleport>
</template>
