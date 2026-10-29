<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';
import { useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { serverErrorMessage } from 'dashboard/helper/providerOwnedAttributes';

import CrmCustomFieldDescriptionHint from 'dashboard/components-next/CRM/CrmCustomFieldDescriptionHint.vue';
import ListAttribute from 'dashboard/components-next/CustomAttributes/ListAttribute.vue';
import CheckboxAttribute from 'dashboard/components-next/CustomAttributes/CheckboxAttribute.vue';
import DateAttribute from 'dashboard/components-next/CustomAttributes/DateAttribute.vue';
import OtherAttribute from 'dashboard/components-next/CustomAttributes/OtherAttribute.vue';

const props = defineProps({
  attribute: {
    type: Object,
    required: true,
  },
  isEditingView: {
    type: Boolean,
    default: false,
  },
  readOnly: {
    type: Boolean,
    default: false,
  },
});

const store = useStore();
const { t } = useI18n();
const route = useRoute();

const handleDelete = async () => {
  try {
    await store.dispatch('contacts/deleteCustomAttributes', {
      id: route.params.contactId,
      customAttributes: [props.attribute.attributeKey],
    });
    useAlert(
      t('CONTACTS_LAYOUT.SIDEBAR.ATTRIBUTES.API.DELETE_SUCCESS_MESSAGE')
    );
  } catch (error) {
    useAlert(
      serverErrorMessage(error) ||
        t('CONTACTS_LAYOUT.SIDEBAR.ATTRIBUTES.API.DELETE_ERROR')
    );
  }
};

const handleUpdate = async value => {
  try {
    await store.dispatch('contacts/update', {
      id: route.params.contactId,
      customAttributes: {
        [props.attribute.attributeKey]: value,
      },
    });
    useAlert(t('CONTACTS_LAYOUT.SIDEBAR.ATTRIBUTES.API.SUCCESS_MESSAGE'));
  } catch (error) {
    useAlert(
      serverErrorMessage(error) ||
        t('CONTACTS_LAYOUT.SIDEBAR.ATTRIBUTES.API.UPDATE_ERROR')
    );
  }
};

const componentMap = {
  list: ListAttribute,
  checkbox: CheckboxAttribute,
  date: DateAttribute,
  default: OtherAttribute,
};

const readOnlyValue = computed(() => {
  const { value, attributeDisplayType } = props.attribute;
  if (value === null || value === undefined || value === '') return '---';
  return attributeDisplayType === 'date'
    ? new Date(value).toLocaleDateString()
    : String(value);
});

const tooltipDescription = computed(() => {
  const rawDescription = String(
    props.attribute.attributeDescription ||
      props.attribute.attribute_description ||
      ''
  ).trim();
  const readOnlyReason = props.readOnly
    ? String(t('CUSTOM_ATTRIBUTES.READ_ONLY.PROVIDER_OWNED') || '').trim()
    : '';
  const parts = [];
  if (rawDescription) parts.push(rawDescription);
  if (readOnlyReason && readOnlyReason !== rawDescription) {
    parts.push(readOnlyReason);
  }
  return parts
    .map((part, idx) =>
      idx < parts.length - 1 && !/[.!?…]$/.test(part) ? `${part}.` : part
    )
    .join(' ');
});

const CurrentAttributeComponent = computed(() => {
  return (
    componentMap[props.attribute.attributeDisplayType] || componentMap.default
  );
});
</script>

<template>
  <div
    class="grid grid-cols-[140px,1fr] group/attribute items-center w-full gap-2"
    :class="isEditingView ? 'min-h-10' : 'min-h-11'"
  >
    <div class="flex items-center min-w-0 gap-1">
      <span class="text-sm font-medium truncate text-n-slate-12">
        {{ attribute.attributeDisplayName }}
      </span>
      <CrmCustomFieldDescriptionHint
        v-if="tooltipDescription"
        :description="tooltipDescription"
        :label="attribute.attributeDisplayName"
      />
    </div>

    <div
      v-if="readOnly"
      class="flex items-center w-full min-w-0"
      :class="isEditingView ? 'justify-start' : 'justify-end'"
      data-testid="contact-attribute-read-only"
    >
      <span
        class="min-w-0 text-sm break-words"
        :class="
          isEditingView ? 'text-n-slate-12' : 'text-n-slate-11 font-medium py-2'
        "
      >
        {{ readOnlyValue }}
      </span>
    </div>
    <component
      :is="CurrentAttributeComponent"
      v-else
      :attribute="attribute"
      :is-editing-view="isEditingView"
      @update="handleUpdate"
      @delete="handleDelete"
    />
  </div>
</template>
