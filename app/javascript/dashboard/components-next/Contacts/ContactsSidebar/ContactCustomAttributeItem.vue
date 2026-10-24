<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';
import { useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { serverErrorMessage } from 'dashboard/helper/providerOwnedAttributes';

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
  // A value another system owns (MedElement): shown with the reason instead
  // of an editor that the server would refuse.
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
    <div class="flex items-center justify-between truncate">
      <span class="text-sm font-medium truncate text-n-slate-12">
        {{ attribute.attributeDisplayName }}
      </span>
    </div>

    <div
      v-if="readOnly"
      class="flex flex-col min-w-0 gap-0.5"
      data-testid="contact-attribute-read-only"
    >
      <span class="text-sm break-words text-n-slate-12">
        {{ readOnlyValue }}
      </span>
      <span class="flex items-center gap-1 text-xs text-n-slate-11">
        <span class="i-lucide-lock size-3 shrink-0" aria-hidden="true" />
        {{ t('CUSTOM_ATTRIBUTES.READ_ONLY.PROVIDER_OWNED') }}
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
