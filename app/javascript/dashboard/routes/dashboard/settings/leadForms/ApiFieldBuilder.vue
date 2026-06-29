<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import Draggable from 'vuedraggable';

import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import ToggleSwitch from 'dashboard/components-next/switch/Switch.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';

const props = defineProps({
  fields: {
    type: Array,
    default: () => [],
  },
});

const emit = defineEmits(['update:fields']);
const { t } = useI18n();

const localFields = ref([]);

const cloneFields = fields => fields.map(field => ({ ...field }));
const phoneFieldNames = ['phoneNumber', 'phone_number', 'phone', 'mobile'];
const isPhoneField = field => phoneFieldNames.includes(field?.name);

const typeOptions = computed(() => [
  {
    value: 'text',
    label: t('LEAD_FORMS.FIELD_TYPES.TEXT'),
    icon: 'i-lucide-type',
  },
  {
    value: 'textarea',
    label: t('LEAD_FORMS.FIELD_TYPES.TEXTAREA'),
    icon: 'i-lucide-align-left',
  },
  {
    value: 'tel',
    label: t('LEAD_FORMS.FIELD_TYPES.PHONE'),
    icon: 'i-lucide-phone',
  },
  {
    value: 'email',
    label: t('LEAD_FORMS.FIELD_TYPES.EMAIL'),
    icon: 'i-lucide-mail',
  },
  {
    value: 'number',
    label: t('LEAD_FORMS.FIELD_TYPES.NUMBER'),
    icon: 'i-lucide-hash',
  },
  {
    value: 'date',
    label: t('LEAD_FORMS.FIELD_TYPES.DATE'),
    icon: 'i-lucide-calendar',
  },
  {
    value: 'url',
    label: t('LEAD_FORMS.FIELD_TYPES.URL'),
    icon: 'i-lucide-link',
  },
  {
    value: 'select',
    label: t('LEAD_FORMS.FIELD_TYPES.SELECT'),
    icon: 'i-lucide-list-filter',
  },
]);

const emitFields = () => {
  emit('update:fields', cloneFields(localFields.value));
};

const updateField = (index, key, value) => {
  const currentField = localFields.value[index];
  if (isPhoneField(currentField) && ['enabled', 'required'].includes(key))
    return;

  localFields.value[index] = {
    ...currentField,
    [key]: value,
  };

  if (isPhoneField(localFields.value[index])) {
    localFields.value[index].enabled = true;
    localFields.value[index].required = true;
    if (localFields.value[index].type === 'text')
      localFields.value[index].type = 'tel';
  }

  emitFields();
};

const toggleField = (index, key) => {
  updateField(index, key, !localFields.value[index][key]);
};

const onDragEnd = () => emitFields();

const nextFieldName = () => {
  let index = localFields.value.length + 1;
  let name = `customField${index}`;
  const existingNames = new Set(localFields.value.map(field => field.name));

  while (existingNames.has(name)) {
    index += 1;
    name = `customField${index}`;
  }

  return name;
};

const addField = () => {
  localFields.value.push({
    name: nextFieldName(),
    label: t('LEAD_FORMS.API_FORMS.CUSTOM_FIELD_LABEL'),
    placeholder: '',
    type: 'text',
    required: false,
    enabled: true,
    custom: true,
  });
  emitFields();
};

const removeField = index => {
  if (localFields.value.length <= 1 || isPhoneField(localFields.value[index]))
    return;
  localFields.value.splice(index, 1);
  emitFields();
};

watch(
  () => props.fields,
  fields => {
    localFields.value = cloneFields(fields || []).map(field => {
      if (!isPhoneField(field)) return field;

      return {
        ...field,
        type: field.type === 'text' ? 'tel' : field.type || 'tel',
        enabled: true,
        required: true,
      };
    });
  },
  { deep: true, immediate: true }
);
</script>

<template>
  <div class="space-y-3">
    <div
      class="overflow-x-auto rounded-2xl border border-n-weak bg-n-background"
    >
      <table class="min-w-full table-auto">
        <thead>
          <tr class="border-b border-n-weak text-left text-xs text-n-slate-11">
            <th class="w-10 px-3 py-3" />
            <th class="w-16 px-3 py-3">
              {{ $t('LEAD_FORMS.API_FORMS.FIELD_ENABLED') }}
            </th>
            <th class="min-w-36 px-3 py-3">
              {{ $t('INBOX_MGMT.PRE_CHAT_FORM.SET_FIELDS_HEADER.KEY') }}
            </th>
            <th class="min-w-44 px-3 py-3">
              {{ $t('INBOX_MGMT.PRE_CHAT_FORM.SET_FIELDS_HEADER.TYPE') }}
            </th>
            <th class="w-24 px-3 py-3">
              {{ $t('INBOX_MGMT.PRE_CHAT_FORM.SET_FIELDS_HEADER.REQUIRED') }}
            </th>
            <th class="min-w-44 px-3 py-3">
              {{ $t('INBOX_MGMT.PRE_CHAT_FORM.SET_FIELDS_HEADER.LABEL') }}
            </th>
            <th class="min-w-52 px-3 py-3">
              {{
                $t('INBOX_MGMT.PRE_CHAT_FORM.SET_FIELDS_HEADER.PLACE_HOLDER')
              }}
            </th>
            <th class="w-12 px-3 py-3" />
          </tr>
        </thead>
        <Draggable
          v-model="localFields"
          tag="tbody"
          item-key="name"
          @end="onDragEnd"
        >
          <template #item="{ element: field, index }">
            <tr class="border-b border-n-weak last:border-b-0">
              <td class="px-3 py-3 align-middle">
                <Icon
                  icon="i-woot-drag-indicator"
                  class="size-4 cursor-move text-n-slate-10"
                />
              </td>
              <td class="px-3 py-3 align-middle">
                <ToggleSwitch
                  :model-value="field.enabled"
                  :disabled="isPhoneField(field)"
                  @change="toggleField(index, 'enabled')"
                />
              </td>
              <td class="px-3 py-3 align-middle">
                <input
                  :value="field.name"
                  type="text"
                  class="h-9 w-full rounded-lg border border-n-weak bg-n-solid-1 px-2 text-sm text-n-slate-12 disabled:text-n-slate-10"
                  :disabled="!field.enabled || isPhoneField(field)"
                  @input="updateField(index, 'name', $event.target.value)"
                />
              </td>
              <td class="px-3 py-3 align-middle">
                <ComboBox
                  :model-value="field.type"
                  :options="typeOptions"
                  input-like
                  :disabled="!field.enabled || isPhoneField(field)"
                  @update:model-value="updateField(index, 'type', $event)"
                />
              </td>
              <td class="px-3 py-3 text-center align-middle">
                <input
                  :checked="field.required"
                  type="checkbox"
                  class="m-0"
                  :disabled="!field.enabled || isPhoneField(field)"
                  @change="toggleField(index, 'required')"
                />
              </td>
              <td class="px-3 py-3 align-middle">
                <input
                  :value="field.label"
                  type="text"
                  class="h-9 w-full rounded-lg border border-n-weak bg-n-solid-1 px-2 text-sm text-n-slate-12 disabled:text-n-slate-10"
                  :disabled="!field.enabled || isPhoneField(field)"
                  @input="updateField(index, 'label', $event.target.value)"
                />
              </td>
              <td class="px-3 py-3 align-middle">
                <input
                  :value="field.placeholder"
                  type="text"
                  class="h-9 w-full rounded-lg border border-n-weak bg-n-solid-1 px-2 text-sm text-n-slate-12 disabled:text-n-slate-10"
                  :disabled="!field.enabled || isPhoneField(field)"
                  @input="
                    updateField(index, 'placeholder', $event.target.value)
                  "
                />
              </td>
              <td class="px-3 py-3 text-right align-middle">
                <Button
                  type="button"
                  icon="i-lucide-trash-2"
                  variant="ghost"
                  color="ruby"
                  size="sm"
                  :disabled="localFields.length <= 1 || isPhoneField(field)"
                  @click="removeField(index)"
                />
              </td>
            </tr>
          </template>
        </Draggable>
      </table>
    </div>

    <Button
      type="button"
      variant="secondary"
      size="sm"
      icon="i-lucide-plus"
      :label="$t('LEAD_FORMS.API_FORMS.ADD_FIELD')"
      @click="addField"
    />
  </div>
</template>
