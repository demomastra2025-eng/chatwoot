<script setup>
import { computed, ref } from 'vue';
import { vOnClickOutside } from '@vueuse/components';
import { useI18n } from 'vue-i18n';

import Input from 'dashboard/components-next/input/Input.vue';
import TemplateContextFieldPicker from './TemplateContextFieldPicker.vue';
import {
  buildTemplateFieldReference,
  extractSingleTemplateFieldReference,
} from 'dashboard/helper/templateFieldReferences';

const props = defineProps({
  modelValue: {
    type: String,
    default: '',
  },
  placeholder: {
    type: String,
    default: '',
  },
  type: {
    type: String,
    default: 'text',
  },
});

const emit = defineEmits(['update:modelValue']);

const { t } = useI18n();

const showPicker = ref(false);
const searchKey = ref('');

const selectedFieldReference = computed(() =>
  extractSingleTemplateFieldReference(props.modelValue)
);

const openPicker = () => {
  showPicker.value = true;
};

const closePicker = () => {
  showPicker.value = false;
  searchKey.value = '';
};

const updateValue = value => {
  emit('update:modelValue', value);
};

const clearSelectedField = () => {
  emit('update:modelValue', '');
};

const applyField = field => {
  emit('update:modelValue', buildTemplateFieldReference(field));
  closePicker();
};
</script>

<template>
  <div v-on-click-outside="closePicker" class="relative flex-1">
    <div
      v-if="selectedFieldReference"
      class="flex items-center gap-2 px-3 py-2 rounded-lg outline outline-1 outline-offset-[-1px] outline-n-weak bg-n-alpha-black2"
    >
      <span class="i-lucide-link size-4 text-n-slate-11" />
      <div class="min-w-0 flex-1">
        <p class="text-sm truncate text-n-slate-12">
          {{ selectedFieldReference.label }}
        </p>
        <p class="text-[11px] truncate text-n-slate-11">
          {{ selectedFieldReference.fieldId }}
        </p>
      </div>
      <button
        type="button"
        class="p-1 rounded-md transition-colors hover:bg-n-alpha-black2 text-n-slate-11"
        :title="t('WHATSAPP_TEMPLATES.PARSER.CHANGE_ATTRIBUTE')"
        @click="openPicker"
      >
        <span class="i-lucide-pencil-line size-4" />
      </button>
      <button
        type="button"
        class="p-1 rounded-md transition-colors hover:bg-n-alpha-black2 text-n-slate-11"
        :title="t('WHATSAPP_TEMPLATES.PARSER.CLEAR_ATTRIBUTE')"
        @click="clearSelectedField"
      >
        <span class="i-lucide-x size-4" />
      </button>
    </div>

    <Input
      v-else
      :model-value="modelValue"
      :type="type"
      class="flex-1"
      :placeholder="placeholder"
      @update:model-value="updateValue"
    >
      <template #suffix>
        <button
          type="button"
          class="absolute top-1/2 right-2 p-1 -translate-y-1/2 rounded-md transition-colors text-n-slate-11 hover:bg-n-alpha-black2"
          :title="t('WHATSAPP_TEMPLATES.PARSER.INSERT_ATTRIBUTE')"
          @click="openPicker"
        >
          <span class="i-lucide-scan-search size-4" />
        </button>
      </template>
    </Input>

    <div
      v-if="showPicker"
      class="absolute z-20 top-full right-0 mt-2 w-[22rem] rounded-xl border border-n-weak bg-n-solid-1 shadow-lg p-3"
    >
      <Input
        v-model="searchKey"
        size="sm"
        :placeholder="
          t('WHATSAPP_TEMPLATES.PARSER.FIELD_PICKER_SEARCH_PLACEHOLDER')
        "
      />
      <div class="mt-2">
        <TemplateContextFieldPicker
          :search-key="searchKey"
          @select-field="applyField"
        />
      </div>
    </div>
  </div>
</template>
