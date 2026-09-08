<script setup>
import { computed, ref, watch } from 'vue';
import WhatsAppTemplateParser from 'dashboard/components-next/whatsapp/WhatsAppTemplateParser.vue';

const props = defineProps({
  language: {
    type: String,
    required: true,
  },
  modelValue: {
    type: Object,
    default: () => ({}),
  },
  templates: {
    type: Array,
    default: () => [],
  },
});

const emit = defineEmits(['update:modelValue', 'validityChange']);
const parserRef = ref(null);

const normalizedLanguage = value =>
  String(value || '')
    .trim()
    .toLowerCase()
    .replace('-', '_')
    .split('_')[0];

const availableTemplates = computed(() =>
  props.templates.filter(
    template => normalizedLanguage(template.language) === props.language
  )
);
const selectedName = computed({
  get: () => props.modelValue?.name || '',
  set: name => {
    const template = availableTemplates.value.find(item => item.name === name);
    emit(
      'update:modelValue',
      template
        ? {
            name: template.name,
            namespace: template.namespace || '',
            category: template.category || 'UTILITY',
            language: template.language,
            processed_params: {},
          }
        : {}
    );
  },
});
const selectedTemplate = computed(() =>
  availableTemplates.value.find(
    template => template.name === selectedName.value
  )
);
const parserState = computed(() => ({
  processedParams: parserRef.value?.processedParams || {},
  valid: parserRef.value?.isFormInvalid === false,
}));

watch(
  () => JSON.stringify(parserState.value),
  payload => {
    if (!selectedTemplate.value || !parserRef.value) {
      emit('validityChange', !selectedName.value);
      return;
    }

    const state = JSON.parse(payload);
    emit('update:modelValue', {
      name: selectedTemplate.value.name,
      namespace: selectedTemplate.value.namespace || '',
      category: selectedTemplate.value.category || 'UTILITY',
      language: selectedTemplate.value.language,
      processed_params: state.processedParams,
    });
    emit('validityChange', state.valid);
  }
);

watch(
  [selectedTemplate, selectedName],
  ([template, name]) => emit('validityChange', !name || Boolean(template)),
  { immediate: true }
);
</script>

<template>
  <div class="rounded-lg border border-n-weak bg-n-solid-1 p-3">
    <label
      class="flex flex-col gap-2 text-xs font-medium uppercase text-n-slate-11"
    >
      {{ language }}
      <select
        v-model="selectedName"
        :data-testid="`follow-up-template-${language}`"
        class="h-10 rounded-lg border border-n-weak bg-n-alpha-1 px-3 text-sm font-normal normal-case text-n-slate-12 outline-none focus:border-n-brand"
      >
        <option value="">
          {{
            $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.TEMPLATE_PLACEHOLDER')
          }}
        </option>
        <option
          v-for="template in availableTemplates"
          :key="`${template.name}-${template.language}`"
          :value="template.name"
        >
          {{ template.name }}
        </option>
      </select>
    </label>

    <WhatsAppTemplateParser
      v-if="selectedTemplate"
      ref="parserRef"
      :key="`${selectedTemplate.name}-${selectedTemplate.language}`"
      class="mt-3"
      :template="selectedTemplate"
      :initial-processed-params="modelValue.processed_params || {}"
    />
  </div>
</template>
