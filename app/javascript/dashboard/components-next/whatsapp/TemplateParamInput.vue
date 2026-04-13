<script setup>
import { computed, nextTick, ref } from 'vue';
import { OnClickOutside } from '@vueuse/components';
import { useEventListener } from '@vueuse/core';
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
const containerRef = ref(null);
const dropdownStyle = ref({});
const teleportTarget = ref('body');

const selectedFieldReference = computed(() =>
  extractSingleTemplateFieldReference(props.modelValue)
);

const resolveTeleportTarget = () => {
  const overlayElement = containerRef.value?.closest(
    'dialog[open], .modal-mask'
  );
  teleportTarget.value = overlayElement || 'body';
};

const updateDropdownPosition = () => {
  if (!showPicker.value || !containerRef.value) return;

  const rect = containerRef.value.getBoundingClientRect();
  const viewportPadding = 8;
  const dropdownGap = 8;
  const width = Math.min(
    Math.max(rect.width, 320),
    window.innerWidth - viewportPadding * 2
  );
  const left = Math.min(
    Math.max(rect.left, viewportPadding),
    window.innerWidth - width - viewportPadding
  );
  const top = Math.max(rect.bottom + dropdownGap, viewportPadding);
  const maxHeight = Math.max(window.innerHeight - top - viewportPadding, 160);

  dropdownStyle.value = {
    left: `${Math.round(left)}px`,
    maxHeight: `${Math.round(maxHeight)}px`,
    top: `${Math.round(top)}px`,
    width: `${Math.round(width)}px`,
  };
};

const openPicker = () => {
  showPicker.value = true;
  resolveTeleportTarget();
  nextTick(() => {
    updateDropdownPosition();
  });
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

useEventListener(window, 'resize', updateDropdownPosition);
useEventListener(window, 'scroll', updateDropdownPosition, {
  capture: true,
  passive: true,
});
</script>

<template>
  <OnClickOutside
    :options="{ ignore: ['.whatsapp-template-field-picker'] }"
    @trigger="closePicker"
  >
    <div ref="containerRef" class="relative flex-1">
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

      <Teleport :to="teleportTarget">
        <div
          v-if="showPicker"
          data-modal-safe-interaction
          class="whatsapp-template-field-picker fixed z-[240] rounded-xl border border-n-weak bg-n-solid-1 p-3 shadow-lg"
          :style="dropdownStyle"
          @mousedown.stop
          @mouseup.stop
          @click.stop
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
      </Teleport>
    </div>
  </OnClickOutside>
</template>
