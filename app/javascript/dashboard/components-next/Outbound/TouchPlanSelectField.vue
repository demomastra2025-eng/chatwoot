<script setup>
import { computed } from 'vue';
import SingleSelect from 'dashboard/components-next/filter/inputs/SingleSelect.vue';

const props = defineProps({
  description: {
    type: String,
    default: '',
  },
  disabled: {
    type: Boolean,
    default: false,
  },
  label: {
    type: String,
    required: true,
  },
  modelValue: {
    type: [String, Number, null],
    default: null,
  },
  options: {
    type: Array,
    default: () => [],
  },
  placeholder: {
    type: String,
    default: '',
  },
});

const emit = defineEmits(['update:modelValue']);

const selectedOption = computed({
  get() {
    return props.options.find(
      option => String(option.id) === String(props.modelValue)
    );
  },
  set(value) {
    emit('update:modelValue', value?.id || null);
  },
});
</script>

<template>
  <div class="grid gap-2">
    <div class="min-w-0">
      <p class="mb-1 text-sm font-medium text-n-slate-12">
        {{ label }}
      </p>
      <p v-if="description" class="text-sm text-n-slate-11">
        {{ description }}
      </p>
    </div>

    <SingleSelect
      v-model="selectedOption"
      :options="options"
      :placeholder="placeholder"
      :disabled="disabled"
      class="w-full"
    />
  </div>
</template>
