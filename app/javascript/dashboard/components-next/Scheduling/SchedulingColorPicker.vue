<script setup>
import { computed } from 'vue';
import {
  ColorAreaArea,
  ColorAreaRoot,
  ColorAreaThumb,
  ColorFieldInput,
  ColorFieldRoot,
  ColorSliderRoot,
  ColorSliderThumb,
  ColorSliderTrack,
  PopoverContent,
  PopoverPortal,
  PopoverRoot,
  PopoverTrigger,
} from 'reka-ui';

const props = defineProps({
  disabled: {
    type: Boolean,
    default: false,
  },
  modelValue: {
    type: String,
    default: '#0EA5E9',
  },
});

const emit = defineEmits(['update:modelValue']);
const hexLabel = 'HEX';

const colorValue = computed({
  get: () => props.modelValue || '#0EA5E9',
  set: value => {
    emit('update:modelValue', value?.toUpperCase?.() || '#0EA5E9');
  },
});
</script>

<template>
  <PopoverRoot>
    <PopoverTrigger as-child>
      <button
        type="button"
        :disabled="disabled"
        class="flex w-full items-center justify-between gap-3 rounded-xl bg-n-alpha-black2 px-3 py-2 text-left outline outline-1 outline-n-weak transition-all duration-150 hover:outline-n-slate-6 focus-visible:outline-n-brand disabled:cursor-not-allowed disabled:opacity-50"
      >
        <span class="flex min-w-0 items-center gap-3">
          <span
            class="size-6 shrink-0 rounded-lg outline outline-1 outline-black/10 dark:outline-white/10"
            :style="{ backgroundColor: colorValue }"
          />
          <span class="truncate text-sm font-medium text-n-slate-12">
            {{ colorValue }}
          </span>
        </span>
        <span
          class="i-lucide-pipette size-4 shrink-0 text-n-slate-10"
          aria-hidden="true"
        />
      </button>
    </PopoverTrigger>

    <PopoverPortal>
      <PopoverContent
        align="start"
        :side-offset="8"
        class="reka-color-picker__content z-[140] w-[20rem] rounded-2xl bg-n-alpha-3 p-4 shadow-md backdrop-blur-[100px] outline outline-1 outline-n-container"
      >
        <div class="flex flex-col gap-4">
          <ColorAreaRoot
            v-model="colorValue"
            color-space="hsb"
            x-channel="saturation"
            y-channel="brightness"
            :disabled="disabled"
          >
            <template #default="{ style }">
              <ColorAreaArea
                :style="style"
                class="relative h-40 w-full overflow-hidden rounded-2xl outline outline-1 outline-black/10 dark:outline-white/10"
              >
                <ColorAreaThumb
                  class="size-4 rounded-full border-2 border-white shadow-[0_0_0_1px_rgba(15,23,42,0.16)]"
                />
              </ColorAreaArea>
            </template>
          </ColorAreaRoot>

          <ColorSliderRoot
            v-model="colorValue"
            channel="hue"
            color-space="hsb"
            :disabled="disabled"
          >
            <ColorSliderTrack
              class="relative h-3 w-full overflow-hidden rounded-full outline outline-1 outline-black/10 dark:outline-white/10"
            />
            <ColorSliderThumb
              class="block size-4 rounded-full border-2 border-white bg-white shadow-[0_1px_4px_rgba(15,23,42,0.2)]"
            />
          </ColorSliderRoot>

          <div class="grid gap-2 sm:grid-cols-[auto_1fr] sm:items-center">
            <span
              class="text-xs font-semibold uppercase tracking-[0.14em] text-n-slate-10"
            >
              {{ hexLabel }}
            </span>
            <ColorFieldRoot v-model="colorValue" :disabled="disabled">
              <ColorFieldInput
                class="block h-10 w-full rounded-xl bg-n-alpha-black2 px-3 text-sm font-medium text-n-slate-12 outline outline-1 outline-n-weak transition-all duration-150 hover:outline-n-slate-6 focus:outline-n-brand placeholder:text-n-slate-10"
              />
            </ColorFieldRoot>
          </div>
        </div>
      </PopoverContent>
    </PopoverPortal>
  </PopoverRoot>
</template>
