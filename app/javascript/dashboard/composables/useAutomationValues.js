import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import languages from 'dashboard/components/widgets/conversation/advancedFilterItems/languages';
import countries from 'shared/constants/countries';
import { useStoreGetters, useMapGetter } from 'dashboard/composables/store';
import { useCrmReferencesStore } from 'dashboard/stores/crm/references';
import { useSchedulingReferencesStore } from 'dashboard/stores/scheduling/references';

import {
  getActionOptions,
  getConditionOptions,
} from 'dashboard/helper/automationHelper';
import {
  MESSAGE_CONDITION_VALUES,
  PRIORITY_CONDITION_VALUES,
} from 'dashboard/constants/automation';

/**
 * This is a shared composables that holds utilities used to build dropdown and file options
 * @returns {Object} An object containing various automation-related functions and computed properties.
 */
export default function useAutomationValues() {
  const getters = useStoreGetters();
  const crmReferencesStore = useCrmReferencesStore();
  const schedulingReferencesStore = useSchedulingReferencesStore();
  const { t } = useI18n();
  const agents = useMapGetter('agents/getVerifiedAgents');
  const campaigns = useMapGetter('campaigns/getAllCampaigns');
  const contacts = useMapGetter('contacts/getContacts');
  const inboxes = useMapGetter('inboxes/getInboxes');
  const labels = useMapGetter('labels/getLabels');
  const teams = useMapGetter('teams/getTeams');
  const slaPolicies = useMapGetter('sla/getSLA');

  const booleanFilterOptions = computed(() => [
    { id: true, name: t('FILTER.ATTRIBUTE_LABELS.TRUE') },
    { id: false, name: t('FILTER.ATTRIBUTE_LABELS.FALSE') },
  ]);

  const statusFilterItems = computed(() => {
    return {
      open: {
        TEXT: t('CHAT_LIST.CHAT_STATUS_FILTER_ITEMS.open.TEXT'),
      },
      resolved: {
        TEXT: t('CHAT_LIST.CHAT_STATUS_FILTER_ITEMS.resolved.TEXT'),
      },
      pending: {
        TEXT: t('CHAT_LIST.CHAT_STATUS_FILTER_ITEMS.pending.TEXT'),
      },
      snoozed: {
        TEXT: t('CHAT_LIST.CHAT_STATUS_FILTER_ITEMS.snoozed.TEXT'),
      },
      all: {
        TEXT: t('CHAT_LIST.CHAT_STATUS_FILTER_ITEMS.all.TEXT'),
      },
    };
  });

  const statusFilterOptions = computed(() => {
    const statusFilters = statusFilterItems.value;
    return [
      ...Object.keys(statusFilters).map(status => ({
        id: status,
        name: statusFilters[status].TEXT,
      })),
      { id: 'all', name: t('CHAT_LIST.FILTER_ALL') },
    ];
  });

  const messageTypeOptions = computed(() =>
    MESSAGE_CONDITION_VALUES.map(item => {
      const translatedLabels = {
        INCOMING: t('AUTOMATION.MESSAGE_TYPES.INCOMING'),
        OUTGOING: t('AUTOMATION.MESSAGE_TYPES.OUTGOING'),
      };

      return {
        id: item.id,
        name: translatedLabels[item.i18nKey] || item.name,
      };
    })
  );

  const priorityOptions = computed(() =>
    PRIORITY_CONDITION_VALUES.map(item => {
      const translatedLabels = {
        NONE: t('AUTOMATION.PRIORITY_TYPES.NONE'),
        LOW: t('AUTOMATION.PRIORITY_TYPES.LOW'),
        MEDIUM: t('AUTOMATION.PRIORITY_TYPES.MEDIUM'),
        HIGH: t('AUTOMATION.PRIORITY_TYPES.HIGH'),
        URGENT: t('AUTOMATION.PRIORITY_TYPES.URGENT'),
      };

      return {
        id: item.id,
        name: translatedLabels[item.i18nKey] || item.name,
      };
    })
  );

  const appointmentStatusOptions = computed(() =>
    ['scheduled', 'confirmed', 'completed', 'cancelled', 'no_show'].map(
      status => {
        const translatedLabels = {
          scheduled: t('SCHEDULING.APPOINTMENT_STATUS.scheduled'),
          confirmed: t('SCHEDULING.APPOINTMENT_STATUS.confirmed'),
          completed: t('SCHEDULING.APPOINTMENT_STATUS.completed'),
          cancelled: t('SCHEDULING.APPOINTMENT_STATUS.cancelled'),
          no_show: t('SCHEDULING.APPOINTMENT_STATUS.no_show'),
        };

        return {
          id: status,
          name: translatedLabels[status] || status,
        };
      }
    )
  );

  const appointmentPaymentStatusOptions = computed(() =>
    ['awaiting_payment', 'prepaid', 'paid', 'cancelled'].map(status => {
      const translatedLabels = {
        awaiting_payment: t('SCHEDULING.PAYMENT_STATUS.awaiting_payment'),
        prepaid: t('SCHEDULING.PAYMENT_STATUS.prepaid'),
        paid: t('SCHEDULING.PAYMENT_STATUS.paid'),
        cancelled: t('SCHEDULING.PAYMENT_STATUS.cancelled'),
      };

      return {
        id: status,
        name: translatedLabels[status] || status,
      };
    })
  );

  const appointmentTypeOptions = computed(() =>
    ['primary', 'secondary', 'other'].map(typeKey => {
      const translatedLabels = {
        primary: t('SCHEDULING.APPOINTMENT_TYPE.primary'),
        secondary: t('SCHEDULING.APPOINTMENT_TYPE.secondary'),
        other: t('SCHEDULING.APPOINTMENT_TYPE.other'),
      };

      return {
        id: typeKey,
        name: translatedLabels[typeKey] || typeKey,
      };
    })
  );

  const appointmentServiceOptions = computed(() =>
    (schedulingReferencesStore.services || []).map(service => ({
      id: service.id,
      name: service.name,
    }))
  );

  const appointmentWeekdayOptions = computed(() => [
    { id: '1', name: t('AUTOMATION.WEEKDAYS.1') },
    { id: '2', name: t('AUTOMATION.WEEKDAYS.2') },
    { id: '3', name: t('AUTOMATION.WEEKDAYS.3') },
    { id: '4', name: t('AUTOMATION.WEEKDAYS.4') },
    { id: '5', name: t('AUTOMATION.WEEKDAYS.5') },
    { id: '6', name: t('AUTOMATION.WEEKDAYS.6') },
    { id: '0', name: t('AUTOMATION.WEEKDAYS.0') },
  ]);

  const appointmentFieldDefinitions = computed(
    () => crmReferencesStore.appointmentFieldDefinitions || []
  );
  const dealFieldDefinitions = computed(
    () => crmReferencesStore.dealFieldDefinitions || []
  );
  const taskFieldDefinitions = computed(
    () => crmReferencesStore.taskFieldDefinitions || []
  );
  const isActiveRecord = record => record?.active !== false;

  const crmPipelineOptions = computed(() =>
    (crmReferencesStore.pipelines || [])
      .filter(isActiveRecord)
      .map(pipeline => ({
        id: pipeline.id,
        name: pipeline.name,
      }))
  );
  const crmStageOptions = computed(() =>
    (crmReferencesStore.pipelines || [])
      .filter(isActiveRecord)
      .flatMap(pipeline =>
        (pipeline.stages || []).filter(isActiveRecord).map(stage => ({
          id: stage.id,
          name: `${pipeline.name} / ${stage.name}`,
        }))
      )
  );
  const crmTaskStatusOptions = computed(() =>
    (crmReferencesStore.taskStatuses || []).map(status => ({
      id: status.id,
      name: status.name,
    }))
  );

  /**
   * Adds a translated "None" option to the beginning of a list
   * @param {Array} list - The list to add "None" to
   * @returns {Array} A new array with "None" option at the beginning
   */
  const addNoneToList = list => [
    {
      id: 'nil',
      name: t('AUTOMATION.NONE_OPTION') || 'None',
    },
    ...(list || []),
  ];

  /**
   * Gets the condition dropdown values for a given type.
   * @param {string} type - The type of condition.
   * @returns {Array} An array of condition dropdown values.
   */
  const getConditionDropdownValues = (type, eventName = null) => {
    return getConditionOptions({
      agents: agents.value,
      appointmentFieldDefinitions: appointmentFieldDefinitions.value,
      appointmentPaymentStatusOptions: appointmentPaymentStatusOptions.value,
      appointmentServiceOptions: appointmentServiceOptions.value,
      appointmentStatusOptions: appointmentStatusOptions.value,
      appointmentTypeOptions: appointmentTypeOptions.value,
      appointmentWeekdayOptions: appointmentWeekdayOptions.value,
      booleanFilterOptions: booleanFilterOptions.value,
      campaigns: campaigns.value,
      crmDealOwnerOptions: agents.value,
      crmPipelineOptions: crmPipelineOptions.value,
      crmStageOptions: crmStageOptions.value,
      crmTaskStatusOptions: crmTaskStatusOptions.value,
      dealFieldDefinitions: dealFieldDefinitions.value,
      contacts: contacts.value,
      customAttributes: getters['attributes/getAttributes'].value,
      eventName,
      inboxes: inboxes.value,
      labels: labels.value,
      statusFilterOptions: statusFilterOptions.value,
      priorityOptions: priorityOptions.value,
      messageTypeOptions: messageTypeOptions.value,
      taskFieldDefinitions: taskFieldDefinitions.value,
      teams: teams.value,
      languages,
      countries,
      type,
    });
  };

  /**
   * Gets the action dropdown values for a given type.
   * @param {string} type - The type of action.
   * @returns {Array} An array of action dropdown values.
   */
  const getActionDropdownValues = type => {
    const agentsList =
      type === 'assign_agent'
        ? [
            {
              id: 'last_responding_agent',
              name: t('AUTOMATION.LAST_RESPONDING_AGENT'),
            },
            ...agents.value,
          ]
        : agents.value;

    return getActionOptions({
      agents: agentsList,
      appointmentStatusOptions: appointmentStatusOptions.value,
      crmDealOwnerOptions: agents.value,
      crmStageOptions: crmStageOptions.value,
      crmTaskStatusOptions: crmTaskStatusOptions.value,
      labels: labels.value,
      teams: teams.value,
      slaPolicies: slaPolicies.value,
      statusFilterOptions: statusFilterOptions.value,
      languages,
      type,
      addNoneToListFn: addNoneToList,
      priorityOptions: priorityOptions.value,
    });
  };

  return {
    booleanFilterOptions,
    statusFilterItems,
    statusFilterOptions,
    appointmentStatusOptions,
    appointmentPaymentStatusOptions,
    appointmentServiceOptions,
    appointmentTypeOptions,
    appointmentWeekdayOptions,
    appointmentFieldDefinitions,
    dealFieldDefinitions,
    taskFieldDefinitions,
    crmPipelineOptions,
    crmStageOptions,
    crmTaskStatusOptions,
    priorityOptions,
    messageTypeOptions,
    getConditionDropdownValues,
    getActionDropdownValues,
    agents,
    campaigns,
    contacts,
    inboxes,
    labels,
    teams,
    slaPolicies,
  };
}
