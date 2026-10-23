<script setup>
import { ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import Draggable from 'vuedraggable';
import ToggleSwitch from 'dashboard/components-next/switch/Switch.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import { isPhoneField } from 'dashboard/helper/preChat';

const props = defineProps({
  preChatFields: {
    type: Array,
    default: () => [],
  },
  // Display names of custom attributes by attribute key.
  fieldTitles: {
    type: Object,
    default: () => ({}),
  },
});

const emit = defineEmits(['update', 'dragEnd']);

const { t } = useI18n();

const FIELD_NAME_KEYS = {
  emailAddress: 'INBOX_MGMT.PRE_CHAT_FORM.FIELD_NAMES.EMAIL_ADDRESS',
  fullName: 'INBOX_MGMT.PRE_CHAT_FORM.FIELD_NAMES.FULL_NAME',
  phoneNumber: 'INBOX_MGMT.PRE_CHAT_FORM.FIELD_NAMES.PHONE_NUMBER',
};

const FIELD_TYPE_KEYS = {
  text: 'INBOX_MGMT.PRE_CHAT_FORM.FIELD_TYPES.TEXT',
  tel: 'INBOX_MGMT.PRE_CHAT_FORM.FIELD_TYPES.TEL',
  email: 'INBOX_MGMT.PRE_CHAT_FORM.FIELD_TYPES.EMAIL',
  number: 'INBOX_MGMT.PRE_CHAT_FORM.FIELD_TYPES.NUMBER',
  link: 'INBOX_MGMT.PRE_CHAT_FORM.FIELD_TYPES.LINK',
  date: 'INBOX_MGMT.PRE_CHAT_FORM.FIELD_TYPES.DATE',
  list: 'INBOX_MGMT.PRE_CHAT_FORM.FIELD_TYPES.LIST',
  checkbox: 'INBOX_MGMT.PRE_CHAT_FORM.FIELD_TYPES.CHECKBOX',
  currency: 'INBOX_MGMT.PRE_CHAT_FORM.FIELD_TYPES.CURRENCY',
  percent: 'INBOX_MGMT.PRE_CHAT_FORM.FIELD_TYPES.PERCENT',
};

// «company_name» / «companyName» -> «Company name»
const humanize = value => {
  const text = String(value || '')
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .replace(/[_-]+/g, ' ')
    .trim()
    .toLowerCase();
  return text.charAt(0).toUpperCase() + text.slice(1);
};

// The raw key («emailAddress») and type («tel») are never shown to a manager.
const getFieldTitle = item => {
  const key = FIELD_NAME_KEYS[item.name];
  if (key) return t(key);
  return props.fieldTitles[item.name] || humanize(item.name);
};

const getFieldTypeLabel = item => {
  const key = FIELD_TYPE_KEYS[String(item.type || '').toLowerCase()];
  return key ? t(key) : humanize(item.type);
};

const preChatFieldOptions = ref(props.preChatFields);

const isFieldEditable = item => {
  return !item.enabled;
};

const handlePreChatFieldOptions = (event, type, item) => {
  if (isPhoneField(item) && ['enabled', 'required'].includes(type)) return;

  emit('update', event, type, item);
};

const onDragEnd = () => {
  emit('dragEnd', preChatFieldOptions.value);
};

watch(
  () => props.preChatFields,
  newFields => {
    preChatFieldOptions.value = newFields;
  }
);
</script>

<template>
  <Draggable
    v-model="preChatFieldOptions"
    tag="tbody"
    item-key="name"
    @end="onDragEnd"
  >
    <template #item="{ element: item }">
      <tr>
        <td class="py-4 ltr:pl-4 ltr:pr-3 rtl:pl-3 rtl:pr-4 text-body-main">
          <Icon
            icon="i-woot-drag-indicator"
            class="size-4 text-n-slate-11 mt-1 cursor-move"
          />
        </td>
        <td class="py-4 ltr:pr-3 rtl:pl-3 text-body-main">
          <ToggleSwitch
            :model-value="item['enabled']"
            :disabled="isPhoneField(item)"
            @change="handlePreChatFieldOptions($event, 'enabled', item)"
          />
        </td>
        <td
          class="py-4 ltr:pr-3 rtl:pl-3 text-body-main"
          :class="{ 'text-n-slate-11': !item['enabled'] }"
        >
          {{ getFieldTitle(item) }}
        </td>
        <td
          class="py-4 ltr:pr-3 rtl:pl-3 text-body-main"
          :class="{ 'text-n-slate-11': !item['enabled'] }"
        >
          {{ getFieldTypeLabel(item) }}
        </td>
        <td class="py-4 ltr:pr-3 rtl:pl-3 text-body-main">
          <input
            v-model="item['required']"
            type="checkbox"
            :value="`${item.name}-required`"
            :disabled="!item['enabled'] || isPhoneField(item)"
            class="m-0"
            @change="handlePreChatFieldOptions($event, 'required', item)"
          />
        </td>
        <td
          class="py-4 ltr:pr-3 rtl:pl-3 text-body-main"
          :class="{ 'text-n-slate-11': !item['enabled'] }"
        >
          <input
            v-model="item.label"
            type="text"
            :disabled="isFieldEditable(item)"
            class="w-full text-sm !mb-0 px-2 py-1 border border-n-weak rounded"
          />
        </td>
        <td
          class="py-4 ltr:pr-4 rtl:pl-4 text-body-main"
          :class="{ 'text-n-slate-11': !item['enabled'] }"
        >
          <input
            v-model="item.placeholder"
            type="text"
            :disabled="isFieldEditable(item)"
            class="w-full text-sm !mb-0 px-2 py-1 border border-n-weak rounded"
          />
        </td>
      </tr>
    </template>
  </Draggable>
</template>
