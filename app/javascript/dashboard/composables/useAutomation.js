import { ref, reactive, computed } from 'vue';
import { useStoreGetters } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import { useCrmReferencesStore } from 'dashboard/stores/crm/references';

import {
  generateCustomAttributeTypes,
  generateManagedCustomAttributeTypes,
  getDefaultConditions,
  getDefaultActions,
  generateCustomAttributes,
} from 'dashboard/helper/automationHelper';
import useAutomationValues from './useAutomationValues';

import {
  // AUTOMATION_RULE_EVENTS,
  // AUTOMATION_ACTION_TYPES,
  AUTOMATIONS,
} from 'dashboard/routes/dashboard/settings/automation/constants.js';

/**
 * Composable for handling automation-related functionality.
 * @returns {Object} An object containing various automation-related functions and computed properties.
 */
export function useAutomation(startValue = null) {
  const getters = useStoreGetters();
  const crmReferencesStore = useCrmReferencesStore();
  const { t } = useI18n();

  const {
    booleanFilterOptions,
    statusFilterOptions,
    getConditionDropdownValues,
    getActionDropdownValues,
    agents,
    campaigns,
    contacts,
    inboxes,
    labels,
    teams,
    slaPolicies,
  } = useAutomationValues();

  const automation = ref(startValue);
  const automationTypes = reactive(structuredClone(AUTOMATIONS));
  const eventName = computed(() => automation.value?.event_name);
  const currentAccountId = computed(() => getters.getCurrentAccountId.value);
  const isSchedulingEnabled = computed(() =>
    getters['accounts/isFeatureEnabledonAccount'].value(
      currentAccountId.value,
      'scheduling'
    )
  );
  const isCrmDealsEnabled = computed(() =>
    getters['accounts/isFeatureEnabledonAccount'].value(
      currentAccountId.value,
      'crm_deals'
    )
  );
  const isCrmTasksEnabled = computed(() =>
    getters['accounts/isFeatureEnabledonAccount'].value(
      currentAccountId.value,
      'crm_tasks'
    )
  );

  const appointmentFieldDefinitions = computed(
    () => crmReferencesStore.appointmentFieldDefinitions || []
  );
  const dealFieldDefinitions = computed(
    () => crmReferencesStore.dealFieldDefinitions || []
  );
  const taskFieldDefinitions = computed(
    () => crmReferencesStore.taskFieldDefinitions || []
  );

  /**
   * Handles the event change for an automation.value.
   */
  const onEventChange = () => {
    automation.value.conditions = getDefaultConditions(eventName.value);
    automation.value.actions = getDefaultActions(eventName.value);
  };

  /**
   * Appends a new condition to the automation.value.
   */
  const appendNewCondition = () => {
    const defaultCondition = getDefaultConditions(eventName.value);
    automation.value.conditions = [
      ...automation.value.conditions,
      ...defaultCondition,
    ];
  };

  /**
   * Appends a new action to the automation.value.
   */
  const appendNewAction = () => {
    const defaultAction = getDefaultActions(eventName.value);
    automation.value.actions = [...automation.value.actions, ...defaultAction];
  };

  /**
   * Removes a filter from the automation.value.
   * @param {number} index - The index of the filter to remove.
   */
  const removeFilter = index => {
    if (automation.value.conditions.length <= 1) {
      useAlert(t('AUTOMATION.CONDITION.DELETE_MESSAGE'));
    } else {
      automation.value.conditions = automation.value.conditions.filter(
        (_, i) => i !== index
      );
    }
  };

  /**
   * Removes an action from the automation.value.
   * @param {number} index - The index of the action to remove.
   */
  const removeAction = index => {
    if (automation.value.actions.length <= 1) {
      useAlert(t('AUTOMATION.ACTION.DELETE_MESSAGE'));
    } else {
      automation.value.actions = automation.value.actions.filter(
        (_, i) => i !== index
      );
    }
  };

  /**
   * Resets a filter in the automation.value.
   * @param {Object} automationTypes - The automation types object.
   * @param {number} index - The index of the filter to reset.
   * @param {Object} currentCondition - The current condition object.
   */
  const resetFilter = (index, currentCondition) => {
    const newConditions = [...automation.value.conditions];

    newConditions[index] = {
      ...newConditions[index],
      filter_operator: automationTypes[eventName.value].conditions.find(
        condition => condition.key === currentCondition.attribute_key
      ).filterOperators[0].value,
      values: '',
    };

    automation.value.conditions = newConditions;
  };

  /**
   * Resets an action in the automation.value.
   * @param {number} index - The index of the action to reset.
   */
  const resetAction = index => {
    const newActions = [...automation.value.actions];
    newActions[index] = {
      ...newActions[index],
      action_params: [],
    };

    automation.value.actions = newActions;
  };

  /**
   * This function formats the custom attributes for automation types.
   * It retrieves custom attributes for conversations and contacts,
   * generates custom attribute types, and adds them to the relevant automation types.
   */
  const manifestCustomAttributes = () => {
    const conversationCustomAttributesRaw = getters[
      'attributes/getAttributesByModel'
    ].value('conversation_attribute');
    const contactCustomAttributesRaw =
      getters['attributes/getAttributesByModel'].value('contact_attribute');

    const conversationCustomAttributeTypes = generateCustomAttributeTypes(
      conversationCustomAttributesRaw,
      'conversation_attribute'
    );
    const contactCustomAttributeTypes = generateCustomAttributeTypes(
      contactCustomAttributesRaw,
      'contact_attribute'
    );

    const manifestedCustomAttributes = generateCustomAttributes(
      conversationCustomAttributeTypes,
      contactCustomAttributeTypes,
      t('AUTOMATION.CONDITION.CONVERSATION_CUSTOM_ATTR_LABEL'),
      t('AUTOMATION.CONDITION.CONTACT_CUSTOM_ATTR_LABEL')
    );

    const CUSTOM_ATTR_HEADER_KEYS = new Set([
      'conversation_custom_attribute',
      'contact_custom_attribute',
      'appointment_custom_attribute',
      'deal_custom_attribute',
      'task_custom_attribute',
    ]);

    const appointmentCustomAttributeTypes = generateManagedCustomAttributeTypes(
      appointmentFieldDefinitions.value,
      'appointment_attribute'
    );
    const appointmentCustomAttributes = appointmentCustomAttributeTypes.length
      ? [
          {
            key: 'appointment_custom_attribute',
            name: t('AUTOMATION.CONDITION.APPOINTMENT_CUSTOM_ATTR_LABEL'),
            disabled: true,
          },
          ...appointmentCustomAttributeTypes,
        ]
      : [];
    const dealCustomAttributeTypes = generateManagedCustomAttributeTypes(
      dealFieldDefinitions.value,
      'deal_attribute'
    );
    const dealCustomAttributes = dealCustomAttributeTypes.length
      ? [
          {
            key: 'deal_custom_attribute',
            name: t('AUTOMATION.CONDITION.DEAL_CUSTOM_ATTR_LABEL'),
            disabled: true,
          },
          ...dealCustomAttributeTypes,
        ]
      : [];
    const taskCustomAttributeTypes = generateManagedCustomAttributeTypes(
      taskFieldDefinitions.value,
      'task_attribute'
    );
    const taskCustomAttributes = taskCustomAttributeTypes.length
      ? [
          {
            key: 'task_custom_attribute',
            name: t('AUTOMATION.CONDITION.TASK_CUSTOM_ATTR_LABEL'),
            disabled: true,
          },
          ...taskCustomAttributeTypes,
        ]
      : [];

    [
      'message_created',
      'conversation_created',
      'conversation_updated',
      'conversation_opened',
    ].forEach(eventToUpdate => {
      const standardConditions = automationTypes[
        eventToUpdate
      ].conditions.filter(
        c => !c.customAttributeType && !CUSTOM_ATTR_HEADER_KEYS.has(c.key)
      );
      automationTypes[eventToUpdate].conditions = [
        ...standardConditions,
        ...manifestedCustomAttributes,
      ];
    });

    [
      'appointment_created',
      'appointment_updated',
      'appointment_cancelled',
      'appointment_completed',
    ].forEach(eventToUpdate => {
      const standardConditions = automationTypes[
        eventToUpdate
      ].conditions.filter(
        c => !c.customAttributeType && !CUSTOM_ATTR_HEADER_KEYS.has(c.key)
      );
      automationTypes[eventToUpdate].conditions = [
        ...standardConditions,
        ...appointmentCustomAttributes,
      ];
    });

    [
      'deal_created',
      'deal_updated',
      'deal_stage_changed',
      'deal_archived',
      'deal_unarchived',
    ].forEach(eventToUpdate => {
      const standardConditions = automationTypes[
        eventToUpdate
      ].conditions.filter(
        c => !c.customAttributeType && !CUSTOM_ATTR_HEADER_KEYS.has(c.key)
      );
      automationTypes[eventToUpdate].conditions = [
        ...standardConditions,
        ...dealCustomAttributes,
      ];
    });

    [
      'task_created',
      'task_updated',
      'task_status_changed',
      'task_archived',
      'task_unarchived',
    ].forEach(eventToUpdate => {
      const standardConditions = automationTypes[
        eventToUpdate
      ].conditions.filter(
        c => !c.customAttributeType && !CUSTOM_ATTR_HEADER_KEYS.has(c.key)
      );
      automationTypes[eventToUpdate].conditions = [
        ...standardConditions,
        ...taskCustomAttributes,
      ];
    });
  };

  const loadFieldDefinitions = async entityKind => {
    try {
      return await crmReferencesStore.loadFieldDefinitions(entityKind);
    } catch (_error) {
      return crmReferencesStore.fieldDefinitions[entityKind] || [];
    }
  };

  const loadAutomationReferences = async eventNameToLoad => {
    const jobs = [];

    if (
      isSchedulingEnabled.value ||
      eventNameToLoad?.startsWith('appointment_')
    ) {
      jobs.push(loadFieldDefinitions('appointment'));
    }

    if (isCrmDealsEnabled.value || eventNameToLoad?.startsWith('deal_')) {
      jobs.push(loadFieldDefinitions('deal'));
      jobs.push(
        crmReferencesStore
          .loadPipelines()
          .catch(() => crmReferencesStore.pipelines || [])
      );
    }

    if (isCrmTasksEnabled.value || eventNameToLoad?.startsWith('task_')) {
      jobs.push(loadFieldDefinitions('task'));
      jobs.push(
        crmReferencesStore
          .loadTaskStatuses()
          .catch(() => crmReferencesStore.taskStatuses || [])
      );
    }

    return Promise.all(jobs);
  };

  return {
    automation,
    automationTypes,
    agents,
    campaigns,
    contacts,
    inboxes,
    labels,
    teams,
    slaPolicies,
    booleanFilterOptions,
    statusFilterOptions,
    onEventChange,
    getConditionDropdownValues,
    appendNewCondition,
    appendNewAction,
    removeFilter,
    removeAction,
    resetFilter,
    resetAction,
    getActionDropdownValues,
    manifestCustomAttributes,
    loadAutomationReferences,
    appointmentFieldDefinitions,
    dealFieldDefinitions,
    taskFieldDefinitions,
    isSchedulingEnabled,
    isCrmDealsEnabled,
    isCrmTasksEnabled,
  };
}
