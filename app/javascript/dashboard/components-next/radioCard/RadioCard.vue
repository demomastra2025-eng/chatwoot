<script setup>
import { ref, useId } from 'vue';
import Label from 'dashboard/components-next/label/Label.vue';

const props = defineProps({
  id: {
    type: String,
    required: true,
  },
  name: {
    type: String,
    default: '',
  },
  label: {
    type: String,
    required: true,
  },
  description: {
    type: String,
    required: true,
  },
  isActive: {
    type: Boolean,
    default: false,
  },
  disabled: {
    type: Boolean,
    default: false,
  },
  disabledLabel: {
    type: String,
    default: '',
  },
  disabledMessage: {
    type: String,
    default: '',
  },
});

const emit = defineEmits(['select']);
const inputId = useId();
const radioRef = ref(null);

const handleChange = () => {
  if (!props.isActive && !props.disabled) {
    radioRef.value?.focus();
    emit('select', props.id);
  }
};
</script>

<template>
  <div
    class="cursor-pointer rounded-xl outline outline-1 p-4 transition-all duration-200 bg-n-solid-1 py-4 ltr:pl-4 rtl:pr-4 ltr:pr-6 rtl:pl-6"
    :class="[
      disabled ? 'opacity-50 cursor-not-allowed' : 'cursor-pointer',
      isActive ? 'outline-n-blue-9' : 'outline-n-weak',
      !disabled && !isActive ? 'hover:outline-n-strong' : '',
    ]"
    @click="handleChange"
  >
    <div class="flex flex-col gap-2 items-start">
      <div class="flex items-center justify-between w-full gap-3">
        <div class="flex items-center gap-2">
          <h3 :id="`${inputId}-label`" class="text-heading-3 text-n-slate-12">
            {{ label }}
          </h3>
          <Label v-if="disabled" :label="disabledLabel" color="amber" compact />
        </div>
        <input
          :id="inputId"
          ref="radioRef"
          :aria-labelledby="`${inputId}-label`"
          :aria-describedby="`${inputId}-description`"
          :checked="isActive"
          :value="id"
          :name="name || id"
          :disabled="disabled"
          type="radio"
          class="h-4 w-4 border-n-slate-6 text-n-brand focus:ring-n-brand focus:ring-offset-0 flex-shrink-0"
          @click.stop
          @change="handleChange"
        />
      </div>
      <p :id="`${inputId}-description`" class="text-body-main text-n-slate-11">
        {{ disabled && disabledMessage ? disabledMessage : description }}
      </p>
      <slot />
    </div>
  </div>
</template>
