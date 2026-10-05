<script setup>
import { computed, ref } from 'vue';
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
  compact: {
    type: Boolean,
    default: false,
  },
  disabled: {
    type: Boolean,
    default: false,
  },
  modelValue: {
    type: String,
    default: '#0EA5E9',
  },
  palette: {
    type: Array,
    default: () => [],
  },
  triggerLabel: {
    type: String,
    default: '',
  },
});

const emit = defineEmits(['update:modelValue']);
const hexLabel = 'HEX';
const popoverOpen = ref(false);

const colorValue = computed({
  get: () => props.modelValue || '#0EA5E9',
  set: value => {
    emit('update:modelValue', value?.toUpperCase?.() || '#0EA5E9');
  },
});

const selectPaletteColor = color => {
  colorValue.value = color;
  popoverOpen.value = false;
};
</script>

<template>
  <PopoverRoot v-model:open="popoverOpen">
    <PopoverTrigger as-child>
      <button
        type="button"
        :disabled="disabled"
        :aria-label="compact ? triggerLabel : undefined"
        :title="compact ? triggerLabel : undefined"
        :class="
          compact
            ? 'flex size-5 shrink-0 items-center justify-center rounded-full outline outline-1 outline-n-strong transition-transform hover:scale-110 focus-visible:outline-2 focus-visible:outline-n-brand disabled:cursor-not-allowed disabled:opacity-50'
            : 'flex w-full items-center justify-between gap-3 rounded-xl bg-n-alpha-black2 px-3 py-2 text-left outline outline-1 outline-n-weak transition-all duration-150 hover:outline-n-slate-6 focus-visible:outline-n-brand disabled:cursor-not-allowed disabled:opacity-50'
        "
        :style="compact ? { backgroundColor: colorValue } : undefined"
      >
        <template v-if="!compact">
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
        </template>
      </button>
    </PopoverTrigger>

    <PopoverPortal>
      <PopoverContent
        align="start"
        :side-offset="8"
        :class="
          compact
            ? 'reka-color-picker__content z-[140] w-44 rounded-xl bg-n-alpha-3 p-2.5 shadow-md backdrop-blur-[100px] outline outline-1 outline-n-container'
            : 'reka-color-picker__content z-[140] w-[20rem] rounded-2xl bg-n-alpha-3 p-4 shadow-md backdrop-blur-[100px] outline outline-1 outline-n-container'
        "
      >
        <div v-if="compact" class="grid grid-cols-5 gap-2">
          <button
            v-for="color in palette"
            :key="color"
            type="button"
            class="size-6 rounded-full outline outline-1 outline-black/10 transition-transform hover:scale-110 focus-visible:outline-2 focus-visible:outline-n-brand dark:outline-white/10"
            :class="
              colorValue.toUpperCase() === String(color).toUpperCase()
                ? 'ring-2 ring-n-slate-8 ring-offset-2 ring-offset-n-surface-1'
                : ''
            "
            :style="{ backgroundColor: color }"
            :aria-label="color"
            @click="selectPaletteColor(color)"
          />
        </div>

        <div v-else class="flex flex-col gap-4">
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
