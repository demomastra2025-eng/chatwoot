<script setup>
import { computed, onMounted, reactive, ref, watch } from 'vue';
import { useToggle } from '@vueuse/core';
import { picoSearch } from '@scmmishra/pico-search';
import { useAlert } from 'dashboard/composables';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { useI18n } from 'vue-i18n';

import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import AddAttribute from './AddAttribute.vue';
import EditAttribute from './EditAttribute.vue';
import SettingsLayout from '../SettingsLayout.vue';
import AttributeListItem from 'dashboard/components-next/ConversationWorkflow/AttributeListItem.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import TabBar from 'dashboard/components-next/tabbar/TabBar.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import {
  useStoreGetters,
  useStore,
  useMapGetter,
} from 'dashboard/composables/store';
import { useAccount } from 'dashboard/composables/useAccount';
import { usePolicy } from 'dashboard/composables/usePolicy';
import {
  buildCrmFieldContextOptions,
  filterCrmFieldContexts,
} from 'dashboard/stores/crm/fieldContexts';
import { useCrmReferencesStore } from 'dashboard/stores/crm/references';
import { formatCrmErrorMessage } from 'dashboard/stores/crm/shared';

const { t } = useI18n();
const getters = useStoreGetters();
const store = useStore();
const { currentAccount } = useAccount();
const { checkPermissions } = usePolicy();
const referencesStore = useCrmReferencesStore();

const inboxes = useMapGetter('inboxes/getInboxes');
const accountId = useMapGetter('getCurrentAccountId');
const isFeatureEnabledonAccount = useMapGetter(
  'accounts/isFeatureEnabledonAccount'
);

const [showAddPopup, toggleAddPopup] = useToggle(false);
const [showEditPopup, toggleEditPopup] = useToggle(false);
const [showDeletePopup, toggleDeletePopup] = useToggle(false);

const crmFieldDialogRef = ref(null);
const searchQuery = ref('');
const selectedAttribute = ref({});
const selectedTabKey = ref('conversation_attribute');

const crmFieldForm = reactive({
  active: true,
  contexts: [],
  defaultValue: '',
  description: '',
  entityKind: 'deal',
  fieldType: 'text',
  id: null,
  key: '',
  label: '',
  max: '',
  min: '',
  optionsText: '',
  position: '',
  regex: '',
  required: false,
  system: false,
});

const legacyUiFlags = computed(() => getters['attributes/getUIFlags'].value);
const isLoading = computed(
  () =>
    legacyUiFlags.value.isFetching ||
    referencesStore.ui.isLoadingFieldDefinitions
);
const isSavingCrmField = computed(() => referencesStore.ui.isSaving);

const legacyAttributesEnabled = computed(() =>
  isFeatureEnabledonAccount.value(
    accountId.value,
    FEATURE_FLAGS.CUSTOM_ATTRIBUTES
  )
);
const canViewLegacy = computed(
  () => legacyAttributesEnabled.value && checkPermissions(['administrator'])
);
const canManageLegacy = computed(
  () => legacyAttributesEnabled.value && checkPermissions(['administrator'])
);
const canViewCrm = computed(() =>
  checkPermissions([
    'administrator',
    'crm_settings_view',
    'crm_settings_manage',
  ])
);
const canManageCrm = computed(() =>
  checkPermissions(['administrator', 'crm_settings_manage'])
);

const dealsEnabled = computed(
  () =>
    canViewCrm.value &&
    isFeatureEnabledonAccount.value(accountId.value, FEATURE_FLAGS.CRM_DEALS)
);
const tasksEnabled = computed(
  () =>
    canViewCrm.value &&
    isFeatureEnabledonAccount.value(accountId.value, FEATURE_FLAGS.CRM_TASKS)
);
const appointmentsEnabled = computed(
  () =>
    canViewCrm.value &&
    isFeatureEnabledonAccount.value(accountId.value, FEATURE_FLAGS.SCHEDULING)
);

const availableTabs = computed(() => {
  const tabs = [];

  if (canViewLegacy.value) {
    tabs.push({
      key: 'conversation_attribute',
      name: t('ATTRIBUTES_MGMT.TABS.CONVERSATION'),
    });
    tabs.push({
      key: 'contact_attribute',
      name: t('ATTRIBUTES_MGMT.TABS.CONTACT'),
    });
  }

  if (dealsEnabled.value) {
    tabs.push({
      key: 'deal',
      name: t('CRM.SETTINGS.FIELD_TABS.DEALS'),
    });
  }

  if (tasksEnabled.value) {
    tabs.push({
      key: 'task',
      name: t('CRM.SETTINGS.FIELD_TABS.TASKS'),
    });
  }

  if (appointmentsEnabled.value) {
    tabs.push({
      key: 'appointment',
      name: t('CRM.SETTINGS.FIELD_TABS.APPOINTMENTS'),
    });
  }

  return tabs;
});

watch(
  availableTabs,
  tabs => {
    if (!tabs.some(tab => tab.key === selectedTabKey.value)) {
      selectedTabKey.value = tabs[0]?.key || '';
    }
  },
  { immediate: true }
);

watch(selectedTabKey, () => {
  searchQuery.value = '';
});

watch(
  () => crmFieldForm.entityKind,
  entityKind => {
    crmFieldForm.contexts = filterCrmFieldContexts(
      crmFieldForm.contexts,
      entityKind,
      t
    );
  }
);

const selectedTabIndex = computed(() =>
  Math.max(
    0,
    availableTabs.value.findIndex(tab => tab.key === selectedTabKey.value)
  )
);

const tabsForTabBar = computed(() =>
  availableTabs.value.map(tab => ({ label: tab.name, key: tab.key }))
);

const isLegacyTab = computed(() =>
  ['conversation_attribute', 'contact_attribute'].includes(selectedTabKey.value)
);
const isCrmTab = computed(() =>
  ['deal', 'task', 'appointment'].includes(selectedTabKey.value)
);

const canManageCurrentTab = computed(() => {
  if (isLegacyTab.value) return canManageLegacy.value;
  if (isCrmTab.value) return canManageCrm.value;
  return false;
});

const addButtonLabel = computed(() =>
  isCrmTab.value
    ? t('CRM.SETTINGS.FIELDS.ADD')
    : t('ATTRIBUTES_MGMT.HEADER_BTN_TXT')
);

const headerLinkText = computed(() =>
  isLegacyTab.value ? t('ATTRIBUTES_MGMT.LEARN_MORE') : ''
);
const headerFeatureName = computed(() =>
  isLegacyTab.value ? 'custom_attributes' : ''
);

const legacyTypeLabels = computed(() => ({
  text: t('ATTRIBUTES_MGMT.ATTRIBUTE_TYPES.TEXT'),
  number: t('ATTRIBUTES_MGMT.ATTRIBUTE_TYPES.NUMBER'),
  link: t('ATTRIBUTES_MGMT.ATTRIBUTE_TYPES.LINK'),
  date: t('ATTRIBUTES_MGMT.ATTRIBUTE_TYPES.DATE'),
  list: t('ATTRIBUTES_MGMT.ATTRIBUTE_TYPES.LIST'),
  checkbox: t('ATTRIBUTES_MGMT.ATTRIBUTE_TYPES.CHECKBOX'),
}));

const crmFieldTypeLabels = computed(() => ({
  text: t('ATTRIBUTES_MGMT.CRM.FIELD_TYPES.TEXT'),
  textarea: t('ATTRIBUTES_MGMT.CRM.FIELD_TYPES.TEXTAREA'),
  number: t('ATTRIBUTES_MGMT.CRM.FIELD_TYPES.NUMBER'),
  currency: t('ATTRIBUTES_MGMT.CRM.FIELD_TYPES.CURRENCY'),
  percent: t('ATTRIBUTES_MGMT.CRM.FIELD_TYPES.PERCENT'),
  checkbox: t('ATTRIBUTES_MGMT.CRM.FIELD_TYPES.CHECKBOX'),
  date: t('ATTRIBUTES_MGMT.CRM.FIELD_TYPES.DATE'),
  datetime: t('ATTRIBUTES_MGMT.CRM.FIELD_TYPES.DATETIME'),
  select: t('ATTRIBUTES_MGMT.CRM.FIELD_TYPES.SELECT'),
  multiselect: t('ATTRIBUTES_MGMT.CRM.FIELD_TYPES.MULTISELECT'),
  url: t('ATTRIBUTES_MGMT.CRM.FIELD_TYPES.URL'),
}));

const crmFieldTypeOptions = computed(() => [
  { label: crmFieldTypeLabels.value.text, value: 'text' },
  { label: crmFieldTypeLabels.value.textarea, value: 'textarea' },
  { label: crmFieldTypeLabels.value.number, value: 'number' },
  { label: crmFieldTypeLabels.value.currency, value: 'currency' },
  { label: crmFieldTypeLabels.value.percent, value: 'percent' },
  { label: crmFieldTypeLabels.value.checkbox, value: 'checkbox' },
  { label: crmFieldTypeLabels.value.date, value: 'date' },
  { label: crmFieldTypeLabels.value.datetime, value: 'datetime' },
  { label: crmFieldTypeLabels.value.select, value: 'select' },
  { label: crmFieldTypeLabels.value.multiselect, value: 'multiselect' },
  { label: crmFieldTypeLabels.value.url, value: 'url' },
]);

const crmEntityOptions = computed(() =>
  [
    dealsEnabled.value
      ? { label: t('CRM.SETTINGS.FIELD_TABS.DEALS'), value: 'deal' }
      : null,
    tasksEnabled.value
      ? { label: t('CRM.SETTINGS.FIELD_TABS.TASKS'), value: 'task' }
      : null,
    appointmentsEnabled.value
      ? {
          label: t('CRM.SETTINGS.FIELD_TABS.APPOINTMENTS'),
          value: 'appointment',
        }
      : null,
  ].filter(Boolean)
);

const crmFieldContextOptions = computed(() =>
  buildCrmFieldContextOptions(crmFieldForm.entityKind, t)
);

const currentAttributes = computed(() => {
  if (selectedTabKey.value === 'deal') {
    return referencesStore.dealFieldDefinitions;
  }

  if (selectedTabKey.value === 'task') {
    return referencesStore.taskFieldDefinitions;
  }

  if (selectedTabKey.value === 'appointment') {
    return referencesStore.appointmentFieldDefinitions;
  }

  return getters['attributes/getAttributesByModel'].value(selectedTabKey.value);
});

const countLabel = computed(() =>
  isCrmTab.value
    ? t('ATTRIBUTES_MGMT.CRM.COUNT', { n: currentAttributes.value.length })
    : t('ATTRIBUTES_MGMT.COUNT', { n: currentAttributes.value.length })
);

const requiredAttributeKeys = computed(
  () => currentAccount.value?.settings?.conversation_required_attributes || []
);

const hasPreChatBadge = attribute => {
  return (inboxes.value || []).some(inbox => {
    const fields =
      inbox?.pre_chat_form_options?.pre_chat_fields ||
      inbox?.channel?.pre_chat_form_options?.pre_chat_fields ||
      [];

    return fields.some(field => field.name === attribute.attribute_key);
  });
};

const buildLegacyBadges = attribute => {
  const badges = [];

  if (hasPreChatBadge(attribute)) {
    badges.push({ type: 'pre-chat' });
  }

  if (
    attribute.attribute_model === 'conversation_attribute' &&
    requiredAttributeKeys.value.includes(attribute.attribute_key)
  ) {
    badges.push({ type: 'resolution' });
  }

  return badges;
};

const humanizeValue = value => {
  return String(value || '')
    .replace(/_/g, ' ')
    .replace(/\b\w/g, character => character.toUpperCase());
};

const describeCrmField = definition => {
  const details = [];
  const contextOptions = buildCrmFieldContextOptions(definition.entityKind, t);

  if (definition.required) {
    details.push(t('ATTRIBUTES_MGMT.CRM.METADATA.REQUIRED'));
  }

  if (definition.active === false) {
    details.push(t('ATTRIBUTES_MGMT.CRM.METADATA.INACTIVE'));
  }

  if (contextOptions.length && definition.rules?.contexts?.length) {
    details.push(
      definition.rules.contexts
        .map(context => {
          return (
            contextOptions.find(option => option.value === context)?.label ||
            humanizeValue(context)
          );
        })
        .join(', ')
    );
  }

  return [definition.description, details.join(' · ')]
    .filter(Boolean)
    .join(' · ');
};

const derivedLegacyAttributes = computed(() =>
  currentAttributes.value.map(attribute => ({
    ...attribute,
    badges: buildLegacyBadges(attribute),
    kind: 'legacy',
    label: attribute.attribute_display_name,
    type: attribute.attribute_display_type,
    typeIconKey: attribute.attribute_display_type,
    typeLabel:
      legacyTypeLabels.value[attribute.attribute_display_type] ||
      humanizeValue(attribute.attribute_display_type),
    value: attribute.attribute_key,
  }))
);

const derivedCrmAttributes = computed(() =>
  currentAttributes.value.map(fieldDefinition => ({
    ...fieldDefinition,
    badges: fieldDefinition.system ? [{ type: 'system' }] : [],
    deleteDisabled: Boolean(fieldDefinition.system),
    description: describeCrmField(fieldDefinition),
    kind: 'crm',
    label: fieldDefinition.label,
    sourceRecord: fieldDefinition,
    type: fieldDefinition.fieldType,
    typeIconKey: fieldDefinition.fieldType,
    typeLabel:
      crmFieldTypeLabels.value[fieldDefinition.fieldType] ||
      humanizeValue(fieldDefinition.fieldType),
    value: fieldDefinition.key,
  }))
);

const displayedAttributes = computed(() =>
  isLegacyTab.value ? derivedLegacyAttributes.value : derivedCrmAttributes.value
);

const filteredAttributes = computed(() => {
  const query = searchQuery.value.trim();

  if (!query) {
    return displayedAttributes.value;
  }

  return picoSearch(displayedAttributes.value, query, [
    'label',
    'value',
    'description',
  ]);
});

const emptyStateMessage = computed(() => {
  if (!availableTabs.value.length) {
    return t('ATTRIBUTES_MGMT.EMPTY_STATE.NO_ACCESS');
  }

  if (searchQuery.value.trim()) {
    return isCrmTab.value
      ? t('ATTRIBUTES_MGMT.CRM.NO_RESULTS')
      : t('ATTRIBUTES_MGMT.NO_RESULTS');
  }

  return isCrmTab.value
    ? t('ATTRIBUTES_MGMT.CRM.EMPTY')
    : t('ATTRIBUTES_MGMT.LIST.EMPTY_RESULT.404');
});

const selectedLegacyTabIndex = computed(() =>
  selectedTabKey.value === 'contact_attribute' ? 1 : 0
);

const crmDialogTitle = computed(() =>
  crmFieldForm.id
    ? t('CRM.SETTINGS.FIELDS.EDIT_TITLE')
    : t('CRM.SETTINGS.FIELDS.CREATE_TITLE')
);

const crmFieldSupportsOptions = computed(() =>
  ['select', 'multiselect'].includes(crmFieldForm.fieldType)
);
const crmFieldSupportsRegex = computed(() =>
  ['text', 'textarea', 'url'].includes(crmFieldForm.fieldType)
);
const crmFieldIsSystem = computed(() => Boolean(crmFieldForm.system));
const crmFieldSupportsNumericRules = computed(() =>
  ['number', 'currency', 'percent'].includes(crmFieldForm.fieldType)
);

const crmDefaultValuePlaceholder = computed(() => {
  if (crmFieldForm.fieldType === 'multiselect') {
    return t('ATTRIBUTES_MGMT.CRM.DEFAULT_VALUE_PLACEHOLDER_MULTI');
  }

  if (crmFieldForm.fieldType === 'checkbox') {
    return t('ATTRIBUTES_MGMT.CRM.DEFAULT_VALUE_PLACEHOLDER_BOOLEAN');
  }

  return t('ATTRIBUTES_MGMT.CRM.DEFAULT_VALUE_PLACEHOLDER');
});

const crmDialogDisableConfirm = computed(() => {
  if (!crmFieldForm.label.trim() || !crmFieldForm.key.trim()) {
    return true;
  }

  if (crmFieldSupportsOptions.value && !crmFieldForm.optionsText.trim()) {
    return true;
  }

  return false;
});

const openAddPopup = () => {
  toggleAddPopup(true);
};

const hideAddPopup = () => {
  toggleAddPopup(false);
};

const hideEditPopup = () => {
  toggleEditPopup(false);
  selectedAttribute.value = {};
};

const closeDelete = () => {
  toggleDeletePopup(false);
  selectedAttribute.value = {};
};

const onClickTabChange = tab => {
  selectedTabKey.value = tab.key;
};

const confirmDeleteAttribute = async () => {
  try {
    await store.dispatch('attributes/delete', selectedAttribute.value.id);
    useAlert(t('ATTRIBUTES_MGMT.DELETE.API.SUCCESS_MESSAGE'));
    closeDelete();
  } catch (error) {
    const errorMessage =
      error?.response?.message || t('ATTRIBUTES_MGMT.DELETE.API.ERROR_MESSAGE');
    useAlert(errorMessage);
  }
};

const defaultCrmEntityKind = () => {
  if (['deal', 'task', 'appointment'].includes(selectedTabKey.value)) {
    return selectedTabKey.value;
  }

  return crmEntityOptions.value[0]?.value || 'deal';
};

const resetCrmFieldForm = (entityKind = defaultCrmEntityKind()) => {
  Object.assign(crmFieldForm, {
    active: true,
    contexts: [],
    defaultValue: '',
    description: '',
    entityKind,
    fieldType: 'text',
    id: null,
    key: '',
    label: '',
    max: '',
    min: '',
    optionsText: '',
    position: '',
    regex: '',
    required: false,
    system: false,
  });
};

const handleCrmDialogClose = () => {
  resetCrmFieldForm();
};

function openCrmFieldDialog(fieldDefinition) {
  if (fieldDefinition) {
    const rawDefaultValue = fieldDefinition.defaultValue;
    let defaultValue = '';

    if (Array.isArray(rawDefaultValue)) {
      defaultValue = rawDefaultValue.join(', ');
    } else if (typeof rawDefaultValue === 'boolean') {
      defaultValue = rawDefaultValue ? 'true' : 'false';
    } else if (
      rawDefaultValue !== null &&
      rawDefaultValue !== undefined &&
      rawDefaultValue !== ''
    ) {
      defaultValue = String(rawDefaultValue);
    }

    Object.assign(crmFieldForm, {
      active: fieldDefinition.active,
      contexts: filterCrmFieldContexts(
        fieldDefinition.rules?.contexts || [],
        fieldDefinition.entityKind,
        t
      ),
      defaultValue,
      description: fieldDefinition.description || '',
      entityKind: fieldDefinition.entityKind,
      fieldType: fieldDefinition.fieldType,
      id: fieldDefinition.id,
      key: fieldDefinition.key,
      label: fieldDefinition.label,
      max: fieldDefinition.rules?.max ?? '',
      min: fieldDefinition.rules?.min ?? '',
      optionsText: (fieldDefinition.options || [])
        .map(option => option.label || option.value || option)
        .join('\n'),
      position:
        fieldDefinition.position === null ||
        fieldDefinition.position === undefined
          ? ''
          : String(fieldDefinition.position),
      regex: fieldDefinition.rules?.regex || '',
      required: fieldDefinition.required,
      system: Boolean(fieldDefinition.system),
    });
  } else {
    resetCrmFieldForm();
  }

  crmFieldDialogRef.value?.open();
}

const parseCrmFieldOptions = () =>
  crmFieldForm.optionsText
    .split('\n')
    .map(option => option.trim())
    .filter(Boolean)
    .map(option => ({ label: option, value: option }));

const parseCrmDefaultValue = () => {
  if (crmFieldForm.defaultValue === '') {
    return undefined;
  }

  if (crmFieldForm.fieldType === 'checkbox') {
    return ['true', '1', 'yes'].includes(
      String(crmFieldForm.defaultValue).toLowerCase()
    );
  }

  if (
    ['currency', 'number', 'percent'].includes(crmFieldForm.fieldType) &&
    crmFieldForm.defaultValue !== ''
  ) {
    return Number(crmFieldForm.defaultValue);
  }

  if (crmFieldForm.fieldType === 'multiselect') {
    return crmFieldForm.defaultValue
      .split(',')
      .map(value => value.trim())
      .filter(Boolean);
  }

  return crmFieldForm.defaultValue;
};

const findCrmFieldDefinitionById = fieldId => {
  return [
    ...referencesStore.dealFieldDefinitions,
    ...referencesStore.taskFieldDefinitions,
    ...referencesStore.appointmentFieldDefinitions,
  ].find(definition => Number(definition.id) === Number(fieldId));
};

const saveCrmFieldDefinition = async () => {
  try {
    const normalizedContexts = filterCrmFieldContexts(
      crmFieldForm.contexts,
      crmFieldForm.entityKind,
      t
    );
    const previousEntityKind = crmFieldForm.id
      ? findCrmFieldDefinitionById(crmFieldForm.id)?.entityKind
      : null;

    const savedField = await referencesStore.saveFieldDefinition({
      active: crmFieldForm.active,
      default_value: parseCrmDefaultValue(),
      description: crmFieldForm.description || undefined,
      entity_kind: crmFieldForm.entityKind,
      field_type: crmFieldForm.fieldType,
      id: crmFieldForm.id,
      key: crmFieldForm.key,
      label: crmFieldForm.label.trim(),
      options: crmFieldSupportsOptions.value ? parseCrmFieldOptions() : [],
      position:
        crmFieldForm.position === ''
          ? undefined
          : Number(crmFieldForm.position),
      required: crmFieldForm.required,
      rules: {
        ...(crmFieldForm.min !== '' ? { min: Number(crmFieldForm.min) } : {}),
        ...(crmFieldForm.max !== '' ? { max: Number(crmFieldForm.max) } : {}),
        ...(crmFieldForm.regex ? { regex: crmFieldForm.regex } : {}),
        ...(normalizedContexts.length ? { contexts: normalizedContexts } : {}),
      },
    });

    const entityKindsToRefresh = [
      previousEntityKind,
      savedField.entityKind,
      selectedTabKey.value,
    ].filter((value, index, values) => {
      return (
        ['deal', 'task', 'appointment'].includes(value) &&
        values.indexOf(value) === index
      );
    });

    await Promise.all(
      entityKindsToRefresh.map(entityKind =>
        referencesStore.loadFieldDefinitions(entityKind)
      )
    );

    selectedTabKey.value = savedField.entityKind;
    crmFieldDialogRef.value?.close();
    useAlert(t('CRM.SETTINGS.FIELDS.SUCCESS_SAVE'));
  } catch (error) {
    useAlert(formatCrmErrorMessage(error, t));
  }
};

async function removeCrmFieldDefinition(fieldDefinition) {
  if (fieldDefinition.system) {
    return;
  }

  // eslint-disable-next-line no-alert
  if (!window.confirm(t('CRM.SETTINGS.FIELDS.DELETE_CONFIRM'))) {
    return;
  }

  try {
    await referencesStore.deleteFieldDefinition(fieldDefinition);
    useAlert(t('CRM.SETTINGS.FIELDS.SUCCESS_DELETE'));
  } catch (error) {
    useAlert(formatCrmErrorMessage(error, t));
  }
}

const handlePrimaryAction = () => {
  if (!canManageCurrentTab.value) {
    return;
  }

  if (isLegacyTab.value) {
    openAddPopup();
    return;
  }

  openCrmFieldDialog();
};

const handleEditAttribute = attribute => {
  if (!canManageCurrentTab.value) {
    return;
  }

  if (attribute.kind === 'legacy') {
    selectedAttribute.value = attribute;
    toggleEditPopup(true);
    return;
  }

  openCrmFieldDialog(attribute.sourceRecord || attribute);
};

const handleDeleteAttribute = attribute => {
  if (!canManageCurrentTab.value) {
    return;
  }

  if (attribute.kind === 'legacy') {
    selectedAttribute.value = attribute;
    toggleDeletePopup(true);
    return;
  }

  if (attribute.deleteDisabled) {
    return;
  }

  removeCrmFieldDefinition(attribute.sourceRecord || attribute);
};

onMounted(async () => {
  const requests = [];

  if (canViewLegacy.value) {
    requests.push(store.dispatch('attributes/get'));
  }

  if (dealsEnabled.value) {
    requests.push(referencesStore.loadFieldDefinitions('deal'));
  }

  if (tasksEnabled.value) {
    requests.push(referencesStore.loadFieldDefinitions('task'));
  }

  if (appointmentsEnabled.value) {
    requests.push(referencesStore.loadFieldDefinitions('appointment'));
  }

  try {
    await Promise.all(requests);
  } catch (error) {
    useAlert(formatCrmErrorMessage(error, t));
  }

  resetCrmFieldForm();
});
</script>

<template>
  <SettingsLayout
    :is-loading="isLoading"
    :loading-message="$t('ATTRIBUTES_MGMT.LOADING')"
  >
    <template #header>
      <BaseSettingsHeader
        v-model:search-query="searchQuery"
        :title="$t('ATTRIBUTES_MGMT.HEADER')"
        :description="$t('ATTRIBUTES_MGMT.DESCRIPTION')"
        :link-text="headerLinkText"
        :feature-name="headerFeatureName"
        :search-placeholder="$t('ATTRIBUTES_MGMT.SEARCH_PLACEHOLDER')"
      >
        <template v-if="currentAttributes.length" #count>
          <span class="text-body-main text-n-slate-11 truncate min-w-0">
            {{ countLabel }}
          </span>
        </template>
        <template v-if="availableTabs.length" #tabs>
          <TabBar
            :tabs="tabsForTabBar"
            :initial-active-tab="selectedTabIndex"
            @tab-changed="onClickTabChange"
          />
        </template>
        <template #actions>
          <Button
            v-if="canManageCurrentTab"
            :label="addButtonLabel"
            size="sm"
            @click="handlePrimaryAction"
          />
        </template>
      </BaseSettingsHeader>
    </template>

    <template #body>
      <div class="flex flex-col gap-4">
        <span
          v-if="!filteredAttributes.length && searchQuery"
          class="flex flex-1 items-center justify-center py-20 text-center text-body-main !text-base text-n-slate-11"
        >
          {{ emptyStateMessage }}
        </span>

        <div
          v-else-if="filteredAttributes.length"
          class="flex flex-col divide-y divide-n-weak border-t border-n-weak"
        >
          <AttributeListItem
            v-for="attribute in filteredAttributes"
            :key="`${attribute.kind}-${attribute.id}`"
            :attribute="attribute"
            :badges="attribute.badges"
            :read-only="!canManageCurrentTab"
            :delete-disabled="attribute.deleteDisabled"
            @edit="handleEditAttribute"
            @delete="handleDeleteAttribute"
          />
        </div>

        <p
          v-else
          class="flex flex-1 items-center justify-center py-20 text-base text-center text-n-slate-12"
        >
          {{ emptyStateMessage }}
        </p>
      </div>
    </template>

    <AddAttribute
      v-if="showAddPopup && isLegacyTab"
      v-model:show="showAddPopup"
      :on-close="hideAddPopup"
      :selected-attribute-model-tab="selectedLegacyTabIndex"
    />

    <woot-modal v-model:show="showEditPopup" @close="hideEditPopup">
      <EditAttribute
        :selected-attribute="selectedAttribute"
        :is-updating="legacyUiFlags.isUpdating"
        @on-close="hideEditPopup"
      />
    </woot-modal>

    <woot-confirm-delete-modal
      v-if="showDeletePopup"
      v-model:show="showDeletePopup"
      :title="
        $t('ATTRIBUTES_MGMT.DELETE.CONFIRM.TITLE', {
          attributeName: selectedAttribute.attribute_display_name,
        })
      "
      :message="$t('ATTRIBUTES_MGMT.DELETE.CONFIRM.MESSAGE')"
      :confirm-text="`${$t('ATTRIBUTES_MGMT.DELETE.CONFIRM.YES')} ${
        selectedAttribute.attribute_display_name || ''
      }`"
      :reject-text="$t('ATTRIBUTES_MGMT.DELETE.CONFIRM.NO')"
      :confirm-value="selectedAttribute.attribute_display_name"
      :confirm-place-holder-text="
        $t('ATTRIBUTES_MGMT.DELETE.CONFIRM.PLACE_HOLDER', {
          attributeName: selectedAttribute.attribute_display_name,
        })
      "
      @on-confirm="confirmDeleteAttribute"
      @on-close="closeDelete"
    />

    <Dialog
      ref="crmFieldDialogRef"
      width="xl"
      position="top"
      overflow-y-auto
      :title="crmDialogTitle"
      :confirm-button-label="$t('CRM.GENERAL.SAVE')"
      :disable-confirm-button="crmDialogDisableConfirm"
      :is-loading="isSavingCrmField"
      @confirm="saveCrmFieldDefinition"
      @close="handleCrmDialogClose"
    >
      <div class="grid max-h-[calc(100vh-14rem)] gap-4 overflow-y-auto pr-1">
        <div class="grid gap-4 md:grid-cols-2">
          <div class="grid gap-1">
            <label class="text-sm font-medium text-n-slate-12">
              {{ $t('CRM.SETTINGS.FIELDS.FORM.ENTITY') }}
            </label>
            <Select
              v-model="crmFieldForm.entityKind"
              :options="crmEntityOptions"
              :disabled="crmFieldIsSystem || crmEntityOptions.length <= 1"
            />
          </div>

          <div class="grid gap-1">
            <label class="text-sm font-medium text-n-slate-12">
              {{ $t('CRM.SETTINGS.FIELDS.FORM.TYPE') }}
            </label>
            <Select
              v-model="crmFieldForm.fieldType"
              :options="crmFieldTypeOptions"
              :disabled="crmFieldIsSystem"
            />
          </div>
        </div>

        <div class="grid gap-4 md:grid-cols-2">
          <Input
            :label="$t('CRM.SETTINGS.FIELDS.FORM.LABEL')"
            :model-value="crmFieldForm.label"
            @update:model-value="crmFieldForm.label = $event"
          />

          <Input
            :label="$t('CRM.SETTINGS.FIELDS.FORM.KEY')"
            :model-value="crmFieldForm.key"
            :disabled="crmFieldIsSystem"
            @update:model-value="crmFieldForm.key = $event"
          />
        </div>

        <div class="grid gap-4 md:grid-cols-2">
          <Input
            :label="$t('CRM.SETTINGS.FIELDS.FORM.POSITION')"
            type="number"
            :model-value="crmFieldForm.position"
            @update:model-value="crmFieldForm.position = $event"
          />

          <Input
            :label="$t('CRM.SETTINGS.FIELDS.FORM.DEFAULT_VALUE')"
            :model-value="crmFieldForm.defaultValue"
            :placeholder="crmDefaultValuePlaceholder"
            @update:model-value="crmFieldForm.defaultValue = $event"
          />
        </div>

        <TextArea
          :label="$t('CRM.SETTINGS.FIELDS.FORM.DESCRIPTION')"
          :model-value="crmFieldForm.description"
          auto-height
          @update:model-value="crmFieldForm.description = $event"
        />

        <TextArea
          v-if="crmFieldSupportsOptions"
          :label="$t('CRM.SETTINGS.FIELDS.FORM.OPTIONS')"
          :message="$t('CRM.SETTINGS.FIELDS.FORM.OPTIONS_PLACEHOLDER')"
          :model-value="crmFieldForm.optionsText"
          auto-height
          @update:model-value="crmFieldForm.optionsText = $event"
        />

        <div
          v-if="crmFieldSupportsNumericRules"
          class="grid gap-4 md:grid-cols-2"
        >
          <Input
            :label="$t('CRM.SETTINGS.FIELDS.FORM.MIN')"
            type="number"
            :model-value="crmFieldForm.min"
            @update:model-value="crmFieldForm.min = $event"
          />

          <Input
            :label="$t('CRM.SETTINGS.FIELDS.FORM.MAX')"
            type="number"
            :model-value="crmFieldForm.max"
            @update:model-value="crmFieldForm.max = $event"
          />
        </div>

        <Input
          v-if="crmFieldSupportsRegex"
          :label="$t('CRM.SETTINGS.FIELDS.FORM.REGEX')"
          :model-value="crmFieldForm.regex"
          @update:model-value="crmFieldForm.regex = $event"
        />

        <div
          v-if="crmFieldContextOptions.length"
          class="grid gap-2 rounded-xl bg-n-alpha-black2 px-4 py-3 outline outline-1 outline-n-weak"
        >
          <span class="text-sm font-medium text-n-slate-12">
            {{ $t('CRM.SETTINGS.FIELDS.FORM.CONTEXTS') }}
          </span>
          <label
            v-for="contextOption in crmFieldContextOptions"
            :key="contextOption.value"
            class="flex items-center gap-3 text-sm text-n-slate-12"
          >
            <Checkbox
              v-model="crmFieldForm.contexts"
              :value="contextOption.value"
            />
            <span>{{ contextOption.label }}</span>
          </label>
        </div>

        <div
          class="grid gap-3 rounded-xl bg-n-alpha-black2 px-4 py-3 outline outline-1 outline-n-weak"
        >
          <label class="flex items-center gap-3 text-sm text-n-slate-12">
            <Checkbox v-model="crmFieldForm.required" />
            <span>{{ $t('CRM.SETTINGS.FIELDS.FORM.REQUIRED') }}</span>
          </label>

          <label class="flex items-center gap-3 text-sm text-n-slate-12">
            <Checkbox v-model="crmFieldForm.active" />
            <span>{{ $t('CRM.SETTINGS.FIELDS.FORM.ACTIVE') }}</span>
          </label>
        </div>
      </div>
    </Dialog>
  </SettingsLayout>
</template>
