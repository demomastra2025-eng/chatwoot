<script setup>
import { computed, onMounted, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';

import { useAccount } from 'dashboard/composables/useAccount';
import { useAlert } from 'dashboard/composables';
import SchedulingAppointmentsAPI from 'dashboard/api/scheduling/appointments';
import Button from 'dashboard/components-next/button/Button.vue';
import TagMultiSelectComboBox from 'dashboard/components-next/combobox/TagMultiSelectComboBox.vue';
import CrmDealConversationPanel from 'dashboard/components-next/CRM/CrmDealConversationPanel.vue';
import CrmCustomFieldsSection from 'dashboard/components-next/CRM/CrmCustomFieldsSection.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import PhoneNumberInput from 'dashboard/components-next/phonenumberinput/PhoneNumberInput.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import SchedulingCalendarGrid from 'dashboard/components-next/Scheduling/SchedulingCalendarGrid.vue';
import SchedulingCustomFieldAdvancedFilter from 'dashboard/components-next/Scheduling/SchedulingCustomFieldAdvancedFilter.vue';
import SchedulingDateTimeField from 'dashboard/components-next/Scheduling/SchedulingDateTimeField.vue';
import SchedulingErrorState from 'dashboard/components-next/Scheduling/SchedulingErrorState.vue';
import SchedulingFormFieldGroup from 'dashboard/components-next/Scheduling/SchedulingFormFieldGroup.vue';
import SchedulingMoneyInput from 'dashboard/components-next/Scheduling/SchedulingMoneyInput.vue';
import SchedulingMultiSelectFilter from 'dashboard/components-next/Scheduling/SchedulingMultiSelectFilter.vue';
import SchedulingResourceFilter from 'dashboard/components-next/Scheduling/SchedulingResourceFilter.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import SchedulingToolbar from 'dashboard/components-next/Scheduling/SchedulingToolbar.vue';
import SchedulingViewSwitcher from 'dashboard/components-next/Scheduling/SchedulingViewSwitcher.vue';

import PaymentActionButton from 'dashboard/components/widgets/PaymentActionButton.vue';
import {
  APPOINTMENT_STATUS_ICONS,
  APPOINTMENT_STATUS_ICON_CLASSES,
  APPOINTMENT_STATUS_VALUES,
  PAYMENT_STATUS_VALUES,
} from '../constants';
import {
  formatSchedulingErrorMessage,
  normalizePayload,
} from 'dashboard/stores/scheduling/shared';
import { formatCalendarTitle } from '../helpers';
import {
  appointmentMatchesCustomFieldFilters,
  buildSchedulingAdvancedCustomFieldOperatorOptions,
  buildSchedulingCustomFieldFilterSummary,
  buildSchedulingCustomFieldFilterOptions,
  isAdvancedFilterableCustomFieldDefinition,
  isDiscreteFilterableCustomFieldDefinition,
  isFilterableCustomFieldDefinition,
  normalizeSchedulingCustomFieldFilters,
} from '../customFieldFilters';
import { useCrmReferencesStore } from 'dashboard/stores/crm/references';
import {
  buildDefaultCustomAttributes,
  mergeMissingDefaultCustomAttributes,
} from 'dashboard/stores/crm/customFieldDefaults';
import {
  APPOINTMENT_BOOKING_INTAKE_CONTEXT,
  fieldDefinitionHasContext,
} from 'dashboard/stores/crm/fieldContexts';
import { useSchedulingAppointmentFormStore } from 'dashboard/stores/scheduling/appointmentForm';
import { useSchedulingCalendarStore } from 'dashboard/stores/scheduling/calendar';
import { useSchedulingReferencesStore } from 'dashboard/stores/scheduling/references';

const { t, locale } = useI18n();
const calendarStore = useSchedulingCalendarStore();
const crmReferencesStore = useCrmReferencesStore();
const referencesStore = useSchedulingReferencesStore();
const formStore = useSchedulingAppointmentFormStore();
const { currentAccount } = useAccount();
const route = useRoute();
const router = useRouter();
const currentPresentation = ref('calendar');
const contactEditorMode = ref(null);
const customFieldFilters = ref({});
const filterDialogRef = ref(null);
const appointmentFilterDraft = reactive({
  customFieldFilters: {},
  paymentStatusFilters: [],
  statusFilters: [],
});
const pendingCreateCustomFieldDefaultsHydration = ref(false);
const appointmentDeleteDialogRef = ref(null);
const showAppointmentConversationPanel = ref(false);

const inlineContactForm = reactive({
  birthDate: '',
  fullName: '',
  gender: '',
  id: null,
  iin: '',
  phone: '',
});

const appointmentPrefillKeys = [
  'action',
  'contactId',
  'contactName',
  'contactPhone',
  'conversationId',
  'source',
];

const queryValue = key => {
  const value = route.query[key];
  return Array.isArray(value) ? value[0] : value;
};

const numericQueryValue = key => {
  const value = Number(queryValue(key));
  return Number.isFinite(value) && value > 0 ? value : '';
};

const viewLabels = computed(() => ({
  day: t('SCHEDULING.VIEWS.DAY'),
  month: t('SCHEDULING.VIEWS.MONTH'),
  week: t('SCHEDULING.VIEWS.WEEK'),
}));

const presentationLabels = computed(() => ({
  calendar: t('SCHEDULING.VIEWS.CALENDAR'),
  list: t('SCHEDULING.VIEWS.LIST'),
}));

const appointmentStatusLabels = computed(() => ({
  cancelled: t('SCHEDULING.APPOINTMENT_STATUS.cancelled'),
  completed: t('SCHEDULING.DIALOGS.APPOINTMENT_STATUS_SHORT.completed'),
  confirmed: t('SCHEDULING.DIALOGS.APPOINTMENT_STATUS_SHORT.confirmed'),
  no_show: t('SCHEDULING.APPOINTMENT_STATUS.no_show'),
  scheduled: t('SCHEDULING.DIALOGS.APPOINTMENT_STATUS_SHORT.scheduled'),
}));

const formatErrorMessage = error => formatSchedulingErrorMessage(error, t);

const calendarErrorDescription = computed(() =>
  formatErrorMessage(calendarStore.ui.error)
);

const formErrorMessage = computed(() => formatErrorMessage(formStore.ui.error));

const validationErrorMessage = key => {
  const labels = {
    'SCHEDULING.APPOINTMENT_FORM.ERRORS.CLIENT_NAME_REQUIRED': t(
      'SCHEDULING.APPOINTMENT_FORM.ERRORS.CLIENT_NAME_REQUIRED'
    ),
    'SCHEDULING.APPOINTMENT_FORM.ERRORS.CONTACT_REQUIRED': t(
      'SCHEDULING.APPOINTMENT_FORM.ERRORS.CONTACT_REQUIRED'
    ),
    'SCHEDULING.APPOINTMENT_FORM.ERRORS.END_BEFORE_START': t(
      'SCHEDULING.APPOINTMENT_FORM.ERRORS.END_BEFORE_START'
    ),
    'SCHEDULING.APPOINTMENT_FORM.ERRORS.RESOURCE_REQUIRED': t(
      'SCHEDULING.APPOINTMENT_FORM.ERRORS.RESOURCE_REQUIRED'
    ),
    'SCHEDULING.APPOINTMENT_FORM.ERRORS.START_REQUIRED': t(
      'SCHEDULING.APPOINTMENT_FORM.ERRORS.START_REQUIRED'
    ),
  };

  return labels[key] || '';
};

const calendarTypeViews = computed(() =>
  ['day', 'week', 'month'].map(value => ({
    label: viewLabels.value[value],
    value,
  }))
);

const presentationOptions = computed(() =>
  ['calendar', 'list'].map(value => ({
    label: presentationLabels.value[value],
    value,
  }))
);

const pageTitle = computed(() =>
  formatCalendarTitle(
    calendarStore.currentView,
    calendarStore.anchorDate,
    locale.value
  )
);

const appointmentRemainingAmount = appointment => {
  if (!appointment) return Number(formStore.form.serviceAmount || 0);

  return Math.max(
    Number(appointment.serviceAmount || 0) -
      Number(appointment.prepaidAmount || 0) -
      Number(appointment.settlementAmount || 0),
    0
  );
};

const appointmentPaymentAmount = computed(() =>
  appointmentRemainingAmount(formStore.selectedAppointment)
);

const filterableResources = computed(() =>
  referencesStore.resources.filter(
    resource => !resource.customAttributes?.deletedFromScheduling
  )
);

const selectableResources = computed(() => referencesStore.activeResources);

const selectedFormResource = computed(() => {
  const selectedResourceId = Number(formStore.form.resourceId);
  if (!selectedResourceId) return null;

  return (
    referencesStore.resources.find(
      resource => resource.id === selectedResourceId
    ) ||
    calendarStore.resources.find(
      resource => resource.id === selectedResourceId
    ) ||
    null
  );
});

const resourceOptions = computed(() =>
  [
    ...selectableResources.value,
    ...(selectedFormResource.value &&
    !selectableResources.value.some(
      resource => resource.id === selectedFormResource.value.id
    )
      ? [selectedFormResource.value]
      : []),
  ].map(resource => ({
    label: resource.specialty
      ? `${resource.name} · ${resource.specialty}`
      : resource.name,
    value: resource.id,
  }))
);

const serviceOptions = computed(() =>
  (referencesStore.activeServices || referencesStore.services || []).map(
    service => ({
      label: service.name,
      value: service.id,
    })
  )
);
const hasServiceOptions = computed(() => serviceOptions.value.length > 0);

const companySelectionEnabled = computed(
  () => currentAccount.value?.settings?.scheduling_company_enabled !== false
);

const contactSelectionRequired = computed(
  () => currentAccount.value?.settings?.scheduling_contact_required !== false
);

const contactOptions = computed(() => {
  const options = formStore.contacts.map(contact => ({
    label: [contact.fullName, contact.phone].filter(Boolean).join(' '),
    value: contact.id,
  }));

  if (!formStore.form.contactId) {
    return options;
  }

  const hasSelectedOption = options.some(
    option => Number(option.value) === Number(formStore.form.contactId)
  );

  if (hasSelectedOption) {
    return options;
  }

  const fallbackLabel = [
    formStore.selectedContact?.fullName || formStore.form.clientName,
    formStore.selectedContact?.phone || formStore.form.clientPhone,
  ]
    .filter(Boolean)
    .join(' ');

  if (!fallbackLabel) {
    return options;
  }

  return [
    {
      label: fallbackLabel,
      value: formStore.form.contactId,
    },
    ...options,
  ];
});

const appointmentStatusOptions = computed(() =>
  APPOINTMENT_STATUS_VALUES.map(value => ({
    icon: APPOINTMENT_STATUS_ICONS[value],
    iconClass: APPOINTMENT_STATUS_ICON_CLASSES[value],
    label: appointmentStatusLabels.value[value] || value,
    labelClass: APPOINTMENT_STATUS_ICON_CLASSES[value],
    value,
  }))
);

const appointmentPaymentStatusOptions = computed(() =>
  PAYMENT_STATUS_VALUES.map(value => ({
    label: t(`SCHEDULING.PAYMENT_STATUS.${value}`),
    value,
  }))
);

const genderOptions = computed(() => [
  { label: t('SCHEDULING.CONTACT.GENDER.MALE'), value: 'male' },
  { label: t('SCHEDULING.CONTACT.GENDER.FEMALE'), value: 'female' },
  { label: t('SCHEDULING.CONTACT.GENDER.OTHER'), value: 'other' },
  { label: t('SCHEDULING.CONTACT.GENDER.UNKNOWN'), value: 'unknown' },
]);

const hasSelectedResources = computed(
  () => calendarStore.selectedResourceIds.length > 0
);
const isContactEditorOpen = computed(() => !!contactEditorMode.value);
const isEditingContact = computed(() => contactEditorMode.value === 'edit');
const appointmentFieldDefinitions = computed(
  () => crmReferencesStore.appointmentFieldDefinitions
);
const intakeAppointmentFieldDefinitions = computed(() =>
  appointmentFieldDefinitions.value.filter(definition =>
    fieldDefinitionHasContext(definition, APPOINTMENT_BOOKING_INTAKE_CONTEXT)
  )
);
const generalAppointmentFieldDefinitions = computed(() =>
  appointmentFieldDefinitions.value.filter(
    definition =>
      !fieldDefinitionHasContext(definition, APPOINTMENT_BOOKING_INTAKE_CONTEXT)
  )
);
const filterableAppointmentFieldDefinitions = computed(() =>
  appointmentFieldDefinitions.value.filter(isFilterableCustomFieldDefinition)
);
const discreteAppointmentFieldDefinitions = computed(() =>
  appointmentFieldDefinitions.value.filter(
    isDiscreteFilterableCustomFieldDefinition
  )
);
const advancedAppointmentFieldDefinitions = computed(() =>
  appointmentFieldDefinitions.value.filter(
    isAdvancedFilterableCustomFieldDefinition
  )
);
const calendarEmptyMessage = computed(() => {
  if (filterableResources.value.length && !hasSelectedResources.value) {
    return t('SCHEDULING.TOOLBAR.RESOURCES_SELECTED', { count: 0 });
  }

  return t('SCHEDULING.CALENDAR.NO_RESOURCES');
});
const visibleAppointments = computed(() => {
  if (!hasSelectedResources.value) return [];

  return calendarStore.appointments.filter(appointment =>
    appointmentMatchesCustomFieldFilters(
      appointment,
      filterableAppointmentFieldDefinitions.value,
      customFieldFilters.value
    )
  );
});

function fetchCalendar() {
  return calendarStore.fetchCalendar();
}

const currentView = computed({
  get: () => calendarStore.currentView,
  set: async value => {
    calendarStore.setView(value);
    await fetchCalendar();
  },
});

const drawerTitle = computed(() =>
  formStore.mode === 'edit'
    ? t('SCHEDULING.APPOINTMENT_FORM.EDIT_TITLE')
    : t('SCHEDULING.APPOINTMENT_FORM.CREATE_TITLE')
);

const drawerConfirmLabel = computed(() =>
  formStore.mode === 'edit'
    ? t('SCHEDULING.GENERAL.UPDATE')
    : t('SCHEDULING.GENERAL.CREATE')
);

const appointmentChatConversationId = computed(() => {
  const conversationId = Number(
    formStore.selectedAppointment?.chatConversationId ||
      formStore.selectedAppointment?.chat_conversation_id ||
      formStore.form.conversationId
  );
  return Number.isFinite(conversationId) && conversationId > 0
    ? conversationId
    : 0;
});

const appointmentChatConversationDisplayId = computed(() =>
  String(
    formStore.selectedAppointment?.chatConversationDisplayId ||
      formStore.selectedAppointment?.chat_conversation_display_id ||
      formStore.selectedAppointment?.conversationDisplayId ||
      formStore.selectedAppointment?.conversation_display_id ||
      ''
  ).replace(/[^\d]/g, '')
);

const appointmentCommunicationThreadId = computed(() =>
  String(
    formStore.selectedAppointment?.communicationThreadId ||
      formStore.selectedAppointment?.communication_thread_id ||
      ''
  ).replace(/[^\d]/g, '')
);

const appointmentCommunicationThreadDisplayId = computed(() =>
  String(
    formStore.selectedAppointment?.communicationThreadDisplayId ||
      formStore.selectedAppointment?.communication_thread_display_id ||
      ''
  ).replace(/[^\d]/g, '')
);

const canOpenAppointmentConversation = computed(
  () =>
    formStore.mode === 'edit' &&
    !!(
      appointmentCommunicationThreadDisplayId.value ||
      appointmentChatConversationDisplayId.value
    )
);

const shouldShowAppointmentConversationPanel = computed(
  () =>
    formStore.mode === 'edit' &&
    showAppointmentConversationPanel.value &&
    canOpenAppointmentConversation.value
);

const appointmentDrawerModalClass = computed(() => [
  'mx-auto flex h-full w-full overflow-hidden rounded-2xl border border-n-weak bg-n-solid-2 shadow-2xl',
  shouldShowAppointmentConversationPanel.value
    ? 'max-w-[min(96rem,calc(100vw-1.5rem))] flex-col md:flex-row'
    : 'max-w-[min(30rem,calc(100vw-1.5rem))] flex-col',
]);

const contactEditorActionLabel = computed(() =>
  isEditingContact.value
    ? t('SCHEDULING.CONTACT.EDIT_ACTION')
    : t('SCHEDULING.CONTACT.CREATE_ACTION')
);

const customFieldFilterLabels = computed(() => ({
  noLabel: t('SCHEDULING.GENERAL.NO'),
  operators: {
    after: t('SCHEDULING.CUSTOM_FIELD_FILTERS.OPERATORS.AFTER'),
    before: t('SCHEDULING.CUSTOM_FIELD_FILTERS.OPERATORS.BEFORE'),
    contains: t('SCHEDULING.CUSTOM_FIELD_FILTERS.OPERATORS.CONTAINS'),
    equals: t('SCHEDULING.CUSTOM_FIELD_FILTERS.OPERATORS.EQUALS'),
    greater_than: t('SCHEDULING.CUSTOM_FIELD_FILTERS.OPERATORS.GREATER_THAN'),
    is_not_present: t(
      'SCHEDULING.CUSTOM_FIELD_FILTERS.OPERATORS.IS_NOT_PRESENT'
    ),
    is_present: t('SCHEDULING.CUSTOM_FIELD_FILTERS.OPERATORS.IS_PRESENT'),
    less_than: t('SCHEDULING.CUSTOM_FIELD_FILTERS.OPERATORS.LESS_THAN'),
    on: t('SCHEDULING.CUSTOM_FIELD_FILTERS.OPERATORS.ON'),
  },
  yesLabel: t('SCHEDULING.GENERAL.YES'),
}));

const normalizeIin = value =>
  String(value || '')
    .replace(/\D/g, '')
    .slice(0, 12);

const parseIinMetadata = iinValue => {
  const normalizedIin = normalizeIin(iinValue);
  if (!normalizedIin) {
    return { reason: '', valid: true };
  }

  if (normalizedIin.length !== 12) {
    return { reason: 'length', valid: false };
  }

  const centuryCode = Number(normalizedIin[6]);
  const centuryMap = {
    1: { century: 1800, gender: 'male' },
    2: { century: 1800, gender: 'female' },
    3: { century: 1900, gender: 'male' },
    4: { century: 1900, gender: 'female' },
    5: { century: 2000, gender: 'male' },
    6: { century: 2000, gender: 'female' },
  };

  if (centuryCode === 0) {
    return { reason: 'foreign', valid: false };
  }

  const metadata = centuryMap[centuryCode];
  if (!metadata) {
    return { reason: 'format', valid: false };
  }

  const year = metadata.century + Number(normalizedIin.slice(0, 2));
  const month = Number(normalizedIin.slice(2, 4));
  const day = Number(normalizedIin.slice(4, 6));
  const parsedDate = new Date(year, month - 1, day);

  if (
    Number.isNaN(parsedDate.getTime()) ||
    parsedDate.getFullYear() !== year ||
    parsedDate.getMonth() !== month - 1 ||
    parsedDate.getDate() !== day
  ) {
    return { reason: 'date', valid: false };
  }

  return {
    birthDate: `${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`,
    gender: metadata.gender,
    reason: '',
    valid: true,
  };
};

const inlineContactIinState = computed(() =>
  parseIinMetadata(inlineContactForm.iin)
);

const inlineContactIinMessage = computed(() => {
  if (!inlineContactForm.iin) return '';
  if (inlineContactIinState.value.valid) return '';

  if (inlineContactIinState.value.reason === 'length') {
    return t('SCHEDULING.CONTACT.IIN_ERROR_LENGTH');
  }

  return t('SCHEDULING.CONTACT.IIN_ERROR_INVALID');
});

const resetInlineContactForm = () => {
  Object.assign(inlineContactForm, {
    birthDate: '',
    fullName: '',
    gender: '',
    id: null,
    iin: '',
    phone: '',
  });
};

const customFieldFilterOptions = definition =>
  buildSchedulingCustomFieldFilterOptions(
    definition,
    customFieldFilterLabels.value
  );

const customFieldAdvancedOperatorOptions = definition =>
  buildSchedulingAdvancedCustomFieldOperatorOptions(
    definition,
    customFieldFilterLabels.value
  );

const customFieldAdvancedFilterSummary = (
  definition,
  filterState = customFieldFilters.value
) =>
  buildSchedulingCustomFieldFilterSummary(
    definition,
    filterState?.[definition.key],
    customFieldFilterLabels.value
  );

const updateAppointmentFilterDraft = (definitionKey, values) => {
  const nextFilters = normalizeSchedulingCustomFieldFilters(
    filterableAppointmentFieldDefinitions.value,
    {
      ...appointmentFilterDraft.customFieldFilters,
      [definitionKey]: values,
    },
    customFieldFilterLabels.value
  );

  appointmentFilterDraft.customFieldFilters = nextFilters;
};

const cloneAppointmentFilterValue = value => {
  if (Array.isArray(value)) return [...value];
  if (value && typeof value === 'object') return { ...value };
  return value;
};

const cloneAppointmentCustomFieldFilters = filters =>
  Object.fromEntries(
    Object.entries(filters || {}).map(([key, value]) => [
      key,
      cloneAppointmentFilterValue(value),
    ])
  );

const syncAppointmentFilterDraft = () => {
  appointmentFilterDraft.statusFilters = [...calendarStore.statusFilters];
  appointmentFilterDraft.paymentStatusFilters = [
    ...calendarStore.paymentStatusFilters,
  ];
  appointmentFilterDraft.customFieldFilters =
    cloneAppointmentCustomFieldFilters(customFieldFilters.value);
};

const openAppointmentFilterDialog = () => {
  syncAppointmentFilterDraft();
  filterDialogRef.value?.open();
};

const applyAppointmentFilters = async () => {
  const nextCustomFieldFilters = normalizeSchedulingCustomFieldFilters(
    filterableAppointmentFieldDefinitions.value,
    appointmentFilterDraft.customFieldFilters,
    customFieldFilterLabels.value
  );

  calendarStore.setStatusFilters(appointmentFilterDraft.statusFilters);
  calendarStore.setPaymentStatusFilters(
    appointmentFilterDraft.paymentStatusFilters
  );
  customFieldFilters.value = nextCustomFieldFilters;
  calendarStore.setCustomAttributeFilters(nextCustomFieldFilters);
  filterDialogRef.value?.close();
  await fetchCalendar();
};

const syncSelectedResources = () => {
  const activeResourceIds = filterableResources.value.map(
    resource => resource.id
  );
  const nextSelectedResourceIds = calendarStore.selectedResourceIds.filter(id =>
    activeResourceIds.includes(id)
  );

  if (
    nextSelectedResourceIds.length === calendarStore.selectedResourceIds.length
  ) {
    return;
  }

  calendarStore.setSelectedResources(nextSelectedResourceIds);
};

const loadPage = async () => {
  await Promise.all([
    crmReferencesStore.loadFieldDefinitions('appointment'),
    referencesStore.loadResources({ include_inactive: true }),
    referencesStore.loadServices({ include_inactive: true }),
  ]);
  syncSelectedResources();
  await fetchCalendar();
};

const openCreateAppointment = (slot, defaults = {}) => {
  pendingCreateCustomFieldDefaultsHydration.value = true;
  showAppointmentConversationPanel.value = false;
  formStore.openCreate(slot, {
    customAttributes: buildDefaultCustomAttributes(
      appointmentFieldDefinitions.value
    ),
    ...defaults,
  });
};

const openEditAppointment = appointment => {
  formStore.openEdit(appointment);
  showAppointmentConversationPanel.value = !!(
    appointment?.communicationThreadDisplayId ||
    appointment?.communication_thread_display_id ||
    appointment?.chatConversationDisplayId ||
    appointment?.chat_conversation_display_id ||
    appointment?.conversationDisplayId ||
    appointment?.conversation_display_id
  );
};

const handleAnchorDateSelect = async nextDate => {
  if (!nextDate) return;

  calendarStore.setAnchorDate(nextDate.toISOString());
  await fetchCalendar();
};

const openNewAppointment = (defaults = {}) => {
  const primaryResource = hasSelectedResources.value
    ? calendarStore.visibleResources[0] || null
    : null;
  const primaryResourceId = primaryResource?.id || '';
  const primaryDurationMin = Math.max(
    5,
    Number(primaryResource?.slotDurationMin) || 30
  );
  const now = new Date();

  const nextSlot = primaryResourceId
    ? calendarStore.slots
        .filter(slot => {
          return (
            Number(slot.resourceId) === Number(primaryResourceId) &&
            new Date(slot.endsAt) > now
          );
        })
        .sort(
          (left, right) => new Date(left.startsAt) - new Date(right.startsAt)
        )[0] || null
    : null;

  const startsAt = nextSlot ? new Date(nextSlot.startsAt) : new Date(now);
  if (!nextSlot) {
    startsAt.setMinutes(Math.ceil(startsAt.getMinutes() / 5) * 5, 0, 0);
  }

  const endsAt = nextSlot ? new Date(nextSlot.endsAt) : new Date(startsAt);
  if (!nextSlot) {
    endsAt.setMinutes(endsAt.getMinutes() + primaryDurationMin);
  }

  openCreateAppointment(
    {
      endsAt: endsAt.toISOString(),
      resourceId: nextSlot?.resourceId || primaryResourceId,
      startsAt: startsAt.toISOString(),
    },
    defaults
  );
};

const clearAppointmentPrefillQuery = async () => {
  const nextQuery = { ...route.query };
  appointmentPrefillKeys.forEach(key => {
    delete nextQuery[key];
  });

  await router.replace({ query: nextQuery });
};

const consumeAppointmentPrefillQuery = async () => {
  if (queryValue('action') !== 'new') return;

  openNewAppointment({
    clientName: queryValue('contactName') || '',
    clientPhone: queryValue('contactPhone') || '',
    contactId: numericQueryValue('contactId'),
    conversationId: numericQueryValue('conversationId'),
  });

  await clearAppointmentPrefillQuery();
};

const handleDrawerClose = () => {
  appointmentDeleteDialogRef.value?.close();
  showAppointmentConversationPanel.value = false;
  formStore.close();
  formStore.reset();
  contactEditorMode.value = null;
  resetInlineContactForm();
};

const fillInlineContactForm = source => {
  Object.assign(inlineContactForm, {
    birthDate: source?.birthDate || source?.clientBirthDate || '',
    fullName: source?.fullName || source?.clientName || '',
    gender: source?.gender || source?.clientGender || '',
    id: source?.id || null,
    iin: source?.customAttributes?.iin || '',
    phone: source?.phone || source?.clientPhone || '',
  });
};

const closeInlineContactEditor = () => {
  contactEditorMode.value = null;
  resetInlineContactForm();
};

const openInlineContactCreate = () => {
  contactEditorMode.value = 'create';
  if (formStore.form.contactId) {
    resetInlineContactForm();
    return;
  }

  fillInlineContactForm(formStore.form);
};

const openInlineContactEdit = () => {
  if (!formStore.form.contactId) return;

  contactEditorMode.value = 'edit';
  fillInlineContactForm(
    formStore.selectedContact || {
      ...formStore.form,
      id: formStore.form.contactId,
    }
  );
};

const handleInlineContactSave = async () => {
  if (inlineContactForm.iin && !inlineContactIinState.value.valid) {
    useAlert(inlineContactIinMessage.value);
    return;
  }

  const contactPayload = {
    ...inlineContactForm,
    fullName: formStore.form.clientName,
    phone: formStore.form.clientPhone,
  };

  try {
    if (isEditingContact.value) {
      await formStore.updateInlineContact(
        formStore.form.contactId,
        contactPayload
      );
      useAlert(t('SCHEDULING.CONTACT.SUCCESS_UPDATE'));
    } else {
      await formStore.createInlineContact(contactPayload);
      useAlert(t('SCHEDULING.CONTACT.SUCCESS_CREATE'));
    }

    closeInlineContactEditor();
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

watch(
  appointmentFieldDefinitions,
  definitions => {
    if (
      !formStore.isOpen ||
      formStore.mode !== 'create' ||
      !pendingCreateCustomFieldDefaultsHydration.value ||
      !definitions.length
    ) {
      return;
    }

    formStore.form.customAttributes = mergeMissingDefaultCustomAttributes(
      formStore.form.customAttributes,
      definitions
    );
    pendingCreateCustomFieldDefaultsHydration.value = false;
  },
  { immediate: true }
);

watch(
  filterableAppointmentFieldDefinitions,
  definitions => {
    const nextFilters = normalizeSchedulingCustomFieldFilters(
      definitions,
      customFieldFilters.value,
      customFieldFilterLabels.value
    );

    customFieldFilters.value = nextFilters;
    calendarStore.setCustomAttributeFilters(nextFilters);
  },
  { immediate: true, deep: true }
);

watch(
  () => inlineContactForm.iin,
  nextValue => {
    const normalizedIin = normalizeIin(nextValue);
    if (normalizedIin !== nextValue) {
      inlineContactForm.iin = normalizedIin;
      return;
    }

    const metadata = parseIinMetadata(normalizedIin);
    if (!metadata.valid) return;

    if (
      metadata.birthDate &&
      inlineContactForm.birthDate !== metadata.birthDate
    ) {
      inlineContactForm.birthDate = metadata.birthDate;
    }

    if (metadata.gender && inlineContactForm.gender !== metadata.gender) {
      inlineContactForm.gender = metadata.gender;
    }
  }
);

const handleContactSelect = contactId => {
  if (!contactId) {
    formStore.selectedContact = null;
    closeInlineContactEditor();
    return;
  }

  const selectedContact = formStore.contacts.find(
    contact => Number(contact.id) === Number(contactId)
  );

  if (selectedContact) {
    formStore.applyContact(selectedContact);
    closeInlineContactEditor();
  }
};

const handleContactDropdownOpen = async () => {
  if (formStore.ui.isLoadingContacts) return;

  try {
    await formStore.searchContacts('');
  } catch {
    // Surface API errors through the existing form store error state.
  }
};

const resetAppointmentFilters = async () => {
  calendarStore.resetFilters();
  customFieldFilters.value = {};
  calendarStore.setCustomAttributeFilters({});
  calendarStore.setSelectedResources(
    filterableResources.value.map(resource => resource.id)
  );
  syncAppointmentFilterDraft();
  await fetchCalendar();
};

const handleAppointmentSubmit = async () => {
  try {
    await formStore.submit(calendarStore);
    useAlert(t('SCHEDULING.APPOINTMENT_FORM.SUCCESS_SAVE'));
    handleDrawerClose();
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const handleAppointmentCancel = async () => {
  try {
    await formStore.cancel(calendarStore);
    useAlert(t('SCHEDULING.APPOINTMENT_FORM.SUCCESS_CANCEL'));
    handleDrawerClose();
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const openAppointmentDeleteDialog = () => {
  appointmentDeleteDialogRef.value?.open();
};

const handleAppointmentDelete = async () => {
  try {
    await formStore.destroy(calendarStore);
    appointmentDeleteDialogRef.value?.close();
    useAlert(t('SCHEDULING.APPOINTMENT_FORM.SUCCESS_DELETE'));
    handleDrawerClose();
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const updateAppointmentMutation = async (
  appointment,
  patch,
  { refresh = false } = {}
) => {
  try {
    const { data } = await SchedulingAppointmentsAPI.update(
      appointment.id,
      patch
    );
    const updatedAppointment = normalizePayload(data);
    calendarStore.syncAppointment(updatedAppointment);

    if (refresh || calendarStore.currentView === 'month') {
      await calendarStore.refresh();
    }
  } catch (error) {
    try {
      await calendarStore.refresh();
    } catch {
      // Keep the original mutation error as the user-facing failure.
    }

    useAlert(formatErrorMessage(error));
  }
};

watch(
  [() => formStore.form.serviceIds, () => formStore.form.resourceId],
  ([serviceIds, resourceId]) => {
    if (!serviceIds?.length || !resourceId) return;
    formStore.syncServicePricing(referencesStore.services);
  },
  { deep: true }
);

watch(
  [() => formStore.isOpen, hasServiceOptions],
  ([isOpen, hasServices]) => {
    if (!isOpen || hasServices) return;

    formStore.updateField('serviceIds', []);
  },
  { immediate: true }
);

watch(
  [contactSelectionRequired, companySelectionEnabled],
  ([contactRequired, companyEnabled]) => {
    formStore.setRequirements({ contactRequired, companyEnabled });
  },
  { immediate: true }
);

onMounted(async () => {
  calendarStore.hydratePreferences();
  currentPresentation.value = 'calendar';
  await loadPage();
  await consumeAppointmentPrefillQuery();
});
</script>

<template>
  <section class="flex flex-col flex-1 min-h-0 overflow-hidden bg-n-surface-1">
    <SchedulingToolbar
      v-model="currentView"
      :anchor-date="calendarStore.anchorDate"
      :current-label="pageTitle"
      :views="calendarTypeViews"
      :show-today="false"
      show-view-switcher
      @previous="
        calendarStore.shiftAnchor(-1);
        fetchCalendar();
      "
      @next="
        calendarStore.shiftAnchor(1);
        fetchCalendar();
      "
      @today="
        calendarStore.setAnchorDate(new Date().toISOString());
        fetchCalendar();
      "
      @select-date="handleAnchorDateSelect"
    >
      <template #actions>
        <SchedulingResourceFilter
          compact
          :resources="filterableResources"
          :model-value="calendarStore.selectedResourceIds"
          @update:model-value="
            calendarStore.setSelectedResources($event);
            fetchCalendar();
          "
        />
        <Button
          size="sm"
          color="slate"
          variant="ghost"
          icon="i-lucide-filter"
          :aria-label="$t('SCHEDULING.TOOLBAR.FILTERS')"
          @click="openAppointmentFilterDialog"
        />
        <SchedulingViewSwitcher
          v-model="currentPresentation"
          :views="presentationOptions"
        />
        <Button
          size="sm"
          :label="$t('SCHEDULING.CALENDAR.NEW_APPOINTMENT')"
          icon="i-lucide-plus"
          @click="openNewAppointment"
        />
      </template>
    </SchedulingToolbar>

    <div
      class="flex-1"
      :class="
        ['calendar', 'kanban'].includes(currentPresentation) &&
        !calendarStore.ui.isLoading &&
        !calendarStore.ui.error
          ? 'min-h-0 overflow-hidden'
          : 'overflow-y-auto'
      "
    >
      <div
        :class="
          ['calendar', 'kanban'].includes(currentPresentation) &&
          !calendarStore.ui.isLoading &&
          !calendarStore.ui.error
            ? 'flex h-full min-h-0 flex-col px-5 pb-4 pt-2'
            : 'flex flex-col gap-4 px-5 pb-4 pt-2'
        "
      >
        <div
          v-if="calendarStore.ui.isLoading"
          class="flex items-center justify-center py-16"
        >
          <Spinner class="!w-8 !h-8" />
        </div>

        <SchedulingErrorState
          v-else-if="calendarStore.ui.error"
          :title="$t('SCHEDULING.GENERAL.ERROR_TITLE')"
          :description="calendarErrorDescription"
          @retry="loadPage"
        />

        <SchedulingCalendarGrid
          v-else
          class="min-h-0 flex-1"
          :anchor-date="calendarStore.anchorDate"
          :appointments="visibleAppointments"
          :break-rules="calendarStore.breakRules"
          :custom-field-definitions="appointmentFieldDefinitions"
          :empty-message="calendarEmptyMessage"
          :holidays="calendarStore.holidays"
          :presentation="currentPresentation"
          :resources="calendarStore.visibleResources"
          :slots="calendarStore.slots"
          :time-offs="calendarStore.timeOffs"
          :view="calendarStore.currentView"
          :work-rules="calendarStore.workRules"
          :workday-overrides="calendarStore.workdayOverrides"
          @change-status="
            updateAppointmentMutation($event.appointment, {
              status: $event.status,
            })
          "
          @create-appointment="openCreateAppointment($event)"
          @move-appointment="
            updateAppointmentMutation($event.appointment, {
              ends_at: $event.endsAt,
              resource_id: $event.resourceId,
              starts_at: $event.startsAt,
            })
          "
          @resize-appointment="
            updateAppointmentMutation($event.appointment, {
              ends_at: $event.endsAt,
              starts_at: $event.startsAt,
            })
          "
          @select-appointment="openEditAppointment($event)"
        />
      </div>
    </div>

    <Transition
      enter-active-class="transition-opacity duration-200 ease-out"
      enter-from-class="opacity-0"
      enter-to-class="opacity-100"
      leave-active-class="transition-opacity duration-150 ease-in"
      leave-from-class="opacity-100"
      leave-to-class="opacity-0"
    >
      <div
        v-if="formStore.isOpen"
        class="modal-mask fixed inset-0 z-[110] bg-black/35 p-3 backdrop-blur-[4px]"
      >
        <div :class="appointmentDrawerModalClass">
          <aside
            class="flex h-full w-full flex-col overflow-hidden bg-n-solid-2 md:w-[28rem] md:min-w-[28rem] xl:w-[30rem] xl:min-w-[30rem]"
            :class="{
              'md:border-r md:border-n-weak':
                shouldShowAppointmentConversationPanel,
            }"
          >
            <header
              class="flex items-center gap-2 border-b border-n-weak bg-n-surface-1 px-4 py-2"
            >
              <input
                id="scheduling-appointment-drawer-title"
                class="reset-base min-w-0 flex-1 border-none bg-transparent text-base font-semibold text-n-slate-12 outline-none placeholder:text-n-slate-10"
                :aria-label="$t('SCHEDULING.APPOINTMENT_FORM.CLIENT_NAME')"
                :placeholder="drawerTitle"
                :value="formStore.form.clientName"
                @input="
                  formStore.updateField('clientName', $event.target.value)
                "
              />

              <Button
                v-if="
                  canOpenAppointmentConversation &&
                  !shouldShowAppointmentConversationPanel
                "
                size="sm"
                color="slate"
                variant="ghost"
                icon="i-lucide-message-circle"
                @click="showAppointmentConversationPanel = true"
              />
              <Button
                size="sm"
                :is-loading="formStore.ui.isSaving"
                :disabled="formStore.isFormInvalid || formStore.ui.isSaving"
                :label="drawerConfirmLabel"
                @click="handleAppointmentSubmit"
              />
              <Button
                size="sm"
                color="slate"
                variant="ghost"
                icon="i-lucide-x"
                @click="handleDrawerClose"
              />
            </header>

            <div class="min-h-0 flex-1 overflow-y-auto px-4 py-3">
              <div class="appointment-drawer-form">
                <div
                  v-if="formStore.ui.error"
                  class="px-4 py-3 text-sm rounded-xl bg-n-ruby-3/70 text-n-ruby-11"
                >
                  {{ formErrorMessage }}
                </div>

                <div class="appointment-contact-section">
                  <div class="appointment-contact-section-heading">
                    <h3 class="mb-0 text-sm font-semibold text-n-slate-12">
                      {{ $t('SCHEDULING.APPOINTMENT_FORM.CONTACT_TITLE') }}
                    </h3>
                    <div class="flex items-center gap-2">
                      <Button
                        v-if="!formStore.form.contactId"
                        size="sm"
                        variant="link"
                        color="blue"
                        icon="i-lucide-plus"
                        :label="$t('SCHEDULING.CONTACT.CREATE_ACTION')"
                        @click="openInlineContactCreate"
                      />
                      <Button
                        v-else
                        size="sm"
                        variant="link"
                        color="blue"
                        icon="i-lucide-pencil"
                        :label="$t('SCHEDULING.CONTACT.EDIT_ACTION')"
                        @click="openInlineContactEdit"
                      />
                    </div>
                  </div>

                  <div class="appointment-contact-accordion">
                    <div class="appointment-contact-accordion-summary">
                      <div
                        class="grid min-w-0 flex-1 gap-2 md:grid-cols-[2rem_minmax(0,1fr)_15rem]"
                      >
                        <div class="mb-1 flex items-center">
                          <SchedulingSelectField
                            class="appointment-contact-select-control w-full"
                            :model-value="formStore.form.contactId"
                            :options="contactOptions"
                            use-api-results
                            trigger-icon="i-lucide-users-round"
                            dropdown-min-width="240"
                            placeholder=" "
                            :aria-label="
                              $t('SCHEDULING.APPOINTMENT_FORM.CONTACT')
                            "
                            :has-error="!!formStore.validationErrors.contactId"
                            :search-placeholder="
                              $t('SCHEDULING.APPOINTMENT_FORM.CONTACT_SEARCH')
                            "
                            :empty-state="
                              $t('SCHEDULING.APPOINTMENT_FORM.CONTACT_EMPTY')
                            "
                            @open="handleContactDropdownOpen"
                            @search="formStore.searchContacts($event)"
                            @update:model-value="
                              formStore.updateField('contactId', $event);
                              handleContactSelect($event);
                            "
                          />
                        </div>
                        <Input
                          v-model="formStore.form.clientName"
                          :label="$t('SCHEDULING.APPOINTMENT_FORM.CLIENT_NAME')"
                          :message="
                            formStore.validationErrors.clientName
                              ? validationErrorMessage(
                                  formStore.validationErrors.clientName
                                )
                              : formStore.validationErrors.contactId
                                ? validationErrorMessage(
                                    formStore.validationErrors.contactId
                                  )
                                : ''
                          "
                          :message-type="
                            formStore.validationErrors.clientName ||
                            formStore.validationErrors.contactId
                              ? 'error'
                              : 'info'
                          "
                        />
                        <PhoneNumberInput
                          v-model="formStore.form.clientPhone"
                          class="appointment-drawer-phone-control"
                          default-country="KZ"
                          :show-country-flag="false"
                          :max-digits="11"
                          :label="
                            $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_PHONE')
                          "
                          size="md"
                        />
                      </div>
                    </div>

                    <div v-if="isContactEditorOpen" class="grid gap-4 pt-3">
                      <div class="grid gap-4 md:grid-cols-3">
                        <Input
                          v-model="inlineContactForm.iin"
                          inputmode="numeric"
                          maxlength="12"
                          custom-input-class="tabular-nums"
                          :label="$t('SCHEDULING.CONTACT.IIN')"
                          :message="inlineContactIinMessage"
                          :message-type="
                            inlineContactIinMessage ? 'error' : 'info'
                          "
                        />
                        <SchedulingDateTimeField
                          v-model="inlineContactForm.birthDate"
                          type="date"
                          :label="$t('SCHEDULING.CONTACT.BIRTH_DATE')"
                        />
                        <SchedulingSelectField
                          class="appointment-drawer-select-control"
                          :model-value="inlineContactForm.gender"
                          :options="genderOptions"
                          :label="$t('SCHEDULING.CONTACT.GENDER_LABEL')"
                          :placeholder="$t('SCHEDULING.CONTACT.GENDER_LABEL')"
                          @update:model-value="
                            inlineContactForm.gender = $event
                          "
                        />
                      </div>

                      <div class="flex justify-end gap-2">
                        <Button
                          size="sm"
                          variant="ghost"
                          color="slate"
                          :label="$t('SCHEDULING.GENERAL.CANCEL')"
                          @click="closeInlineContactEditor"
                        />
                        <Button
                          size="sm"
                          variant="faded"
                          color="slate"
                          :is-loading="formStore.ui.isCreatingContact"
                          :label="contactEditorActionLabel"
                          @click="handleInlineContactSave"
                        />
                      </div>
                    </div>
                  </div>
                </div>

                <SchedulingFormFieldGroup
                  class="appointment-details-section"
                  :framed="false"
                  :title="$t('SCHEDULING.APPOINTMENT_FORM.APPOINTMENT_TITLE')"
                  :description="
                    $t('SCHEDULING.APPOINTMENT_FORM.APPOINTMENT_DESCRIPTION')
                  "
                >
                  <div class="grid gap-4 md:grid-cols-2">
                    <SchedulingSelectField
                      class="appointment-drawer-select-control"
                      :model-value="formStore.form.resourceId"
                      :options="resourceOptions"
                      :label="$t('SCHEDULING.APPOINTMENT_FORM.RESOURCE')"
                      :placeholder="$t('SCHEDULING.APPOINTMENT_FORM.RESOURCE')"
                      :message="
                        formStore.validationErrors.resourceId
                          ? validationErrorMessage(
                              formStore.validationErrors.resourceId
                            )
                          : ''
                      "
                      :has-error="!!formStore.validationErrors.resourceId"
                      @update:model-value="
                        formStore.updateField('resourceId', $event)
                      "
                    />
                    <div class="grid gap-1">
                      <span class="mb-0.5 text-sm font-medium text-n-slate-12">
                        {{ $t('SCHEDULING.APPOINTMENT_FORM.SERVICE') }}
                      </span>
                      <TagMultiSelectComboBox
                        v-if="hasServiceOptions"
                        class="appointment-drawer-multi-control"
                        :model-value="formStore.form.serviceIds"
                        :options="serviceOptions"
                        use-api-results
                        :placeholder="$t('SCHEDULING.APPOINTMENT_FORM.SERVICE')"
                        :search-placeholder="
                          $t('SCHEDULING.APPOINTMENT_FORM.SERVICE_SEARCH')
                        "
                        :empty-state="
                          $t('SCHEDULING.APPOINTMENT_FORM.SERVICE_EMPTY')
                        "
                        @update:model-value="
                          formStore.updateField('serviceIds', $event)
                        "
                      />
                      <Input
                        v-else
                        :model-value="formStore.form.serviceNameSnapshot"
                        :placeholder="$t('SCHEDULING.APPOINTMENT_FORM.SERVICE')"
                        @update:model-value="
                          value => {
                            formStore.updateField('serviceIds', []);
                            formStore.updateField('serviceNameSnapshot', value);
                          }
                        "
                      />
                    </div>
                    <div
                      class="appointment-money-grid grid gap-4 md:col-span-2 md:grid-cols-3"
                    >
                      <SchedulingSelectField
                        class="appointment-drawer-select-control"
                        :model-value="formStore.form.status"
                        :options="appointmentStatusOptions"
                        :label="$t('SCHEDULING.APPOINTMENT_FORM.STATUS')"
                        :placeholder="$t('SCHEDULING.APPOINTMENT_FORM.STATUS')"
                        @update:model-value="
                          formStore.updateField('status', $event)
                        "
                      />
                      <SchedulingMoneyInput
                        v-model="formStore.form.serviceAmount"
                        class="appointment-drawer-money-control"
                        min="0"
                        :label="
                          $t('SCHEDULING.APPOINTMENT_FORM.SERVICE_AMOUNT')
                        "
                      />
                      <SchedulingMoneyInput
                        v-model="formStore.form.prepaidAmount"
                        class="appointment-drawer-money-control"
                        min="0"
                        :label="
                          $t('SCHEDULING.APPOINTMENT_FORM.PREPAID_AMOUNT')
                        "
                        :message="
                          formStore.validationErrors.prepaidAmount
                            ? validationErrorMessage(
                                formStore.validationErrors.prepaidAmount
                              )
                            : ''
                        "
                        :message-type="
                          formStore.validationErrors.prepaidAmount
                            ? 'error'
                            : 'info'
                        "
                      />
                    </div>
                    <div class="grid gap-4 md:col-span-2 md:grid-cols-2">
                      <SchedulingDateTimeField
                        v-model="formStore.form.startsAt"
                        type="datetime"
                        :label="$t('SCHEDULING.APPOINTMENT_FORM.STARTS_AT')"
                        :message="
                          formStore.validationErrors.startsAt
                            ? validationErrorMessage(
                                formStore.validationErrors.startsAt
                              )
                            : ''
                        "
                        :message-type="
                          formStore.validationErrors.startsAt ? 'error' : 'info'
                        "
                      />
                      <SchedulingDateTimeField
                        v-model="formStore.form.endsAt"
                        type="datetime"
                        :label="$t('SCHEDULING.APPOINTMENT_FORM.ENDS_AT')"
                        :message="
                          formStore.validationErrors.endsAt
                            ? validationErrorMessage(
                                formStore.validationErrors.endsAt
                              )
                            : ''
                        "
                        :message-type="
                          formStore.validationErrors.endsAt ? 'error' : 'info'
                        "
                      />
                    </div>
                  </div>
                </SchedulingFormFieldGroup>

                <CrmCustomFieldsSection
                  v-model="formStore.form.customAttributes"
                  :definitions="intakeAppointmentFieldDefinitions"
                  :title="$t('SCHEDULING.APPOINTMENT_FORM.INTAKE_FIELDS_TITLE')"
                  :description="
                    $t('SCHEDULING.APPOINTMENT_FORM.INTAKE_FIELDS_DESCRIPTION')
                  "
                  :framed="false"
                />

                <SchedulingFormFieldGroup :framed="false">
                  <TextArea
                    v-model="formStore.form.clientComment"
                    auto-height
                    custom-text-area-wrapper-class="!rounded-md !border-n-weak !bg-n-alpha-black2 !px-2 !py-1"
                    :label="$t('SCHEDULING.APPOINTMENT_FORM.COMMENT')"
                    :placeholder="
                      $t('SCHEDULING.APPOINTMENT_FORM.COMMENT_PLACEHOLDER')
                    "
                    min-height="3rem"
                  />
                </SchedulingFormFieldGroup>

                <CrmCustomFieldsSection
                  v-model="formStore.form.customAttributes"
                  :definitions="generalAppointmentFieldDefinitions"
                  :title="$t('SCHEDULING.APPOINTMENT_FORM.CUSTOM_FIELDS_TITLE')"
                  :description="
                    $t('SCHEDULING.APPOINTMENT_FORM.CUSTOM_FIELDS_DESCRIPTION')
                  "
                  :framed="false"
                />

                <div
                  v-if="formStore.mode === 'edit'"
                  class="appointment-drawer-section"
                >
                  <div class="flex flex-wrap items-center gap-2">
                    <Button
                      size="sm"
                      variant="faded"
                      color="ruby"
                      :is-loading="formStore.ui.isSaving"
                      :label="
                        $t('SCHEDULING.APPOINTMENT_FORM.CANCEL_APPOINTMENT')
                      "
                      @click="handleAppointmentCancel"
                    />
                    <PaymentActionButton
                      :appointment-id="formStore.recordId"
                      :default-amount="appointmentPaymentAmount"
                      :require-amount-input="false"
                      delivery-mode="copy"
                      :label="
                        $t('SCHEDULING.APPOINTMENT_FORM.KASPI_PAYMENT_LINK')
                      "
                    />
                    <Button
                      v-if="formStore.form.status === 'cancelled'"
                      size="sm"
                      variant="ghost"
                      color="ruby"
                      :is-loading="formStore.ui.isSaving"
                      :label="
                        $t('SCHEDULING.APPOINTMENT_FORM.DELETE_APPOINTMENT')
                      "
                      @click="openAppointmentDeleteDialog"
                    />
                  </div>
                </div>
              </div>
            </div>
          </aside>

          <CrmDealConversationPanel
            :communication-thread-id="appointmentCommunicationThreadId"
            :communication-thread-display-id="
              appointmentCommunicationThreadDisplayId
            "
            :conversation-id="appointmentChatConversationId"
            :conversation-display-id="appointmentChatConversationDisplayId"
            :visible="
              formStore.isOpen && shouldShowAppointmentConversationPanel
            "
            @close="showAppointmentConversationPanel = false"
          />
        </div>
      </div>
    </Transition>

    <Dialog
      ref="filterDialogRef"
      width="5xl"
      :title="$t('SCHEDULING.TOOLBAR.FILTERS')"
      :confirm-button-label="$t('SCHEDULING.GENERAL.APPLY')"
      @confirm="applyAppointmentFilters"
    >
      <div class="grid gap-4">
        <div class="grid gap-4 md:grid-cols-2">
          <SchedulingMultiSelectFilter
            :model-value="appointmentFilterDraft.statusFilters"
            :options="appointmentStatusOptions"
            :placeholder="$t('SCHEDULING.TOOLBAR.STATUS')"
            @update:model-value="appointmentFilterDraft.statusFilters = $event"
          />
          <SchedulingMultiSelectFilter
            :model-value="appointmentFilterDraft.paymentStatusFilters"
            :options="appointmentPaymentStatusOptions"
            :placeholder="$t('SCHEDULING.TOOLBAR.PAYMENT_STATUS')"
            @update:model-value="
              appointmentFilterDraft.paymentStatusFilters = $event
            "
          />
        </div>

        <div class="grid gap-4 md:grid-cols-3">
          <SchedulingMultiSelectFilter
            v-for="definition in discreteAppointmentFieldDefinitions"
            :key="definition.key"
            :model-value="
              appointmentFilterDraft.customFieldFilters[definition.key] || []
            "
            :options="customFieldFilterOptions(definition)"
            :placeholder="definition.label"
            :show-trigger-icon="false"
            @update:model-value="
              updateAppointmentFilterDraft(definition.key, $event)
            "
          />
          <SchedulingCustomFieldAdvancedFilter
            v-for="definition in advancedAppointmentFieldDefinitions"
            :key="definition.key"
            :definition="definition"
            :model-value="
              appointmentFilterDraft.customFieldFilters[definition.key] || null
            "
            :operator-options="customFieldAdvancedOperatorOptions(definition)"
            :placeholder="definition.label"
            :summary-label="
              customFieldAdvancedFilterSummary(
                definition,
                appointmentFilterDraft.customFieldFilters
              )
            "
            :apply-label="$t('SCHEDULING.GENERAL.APPLY')"
            :clear-label="$t('SCHEDULING.GENERAL.CLEAR')"
            :value-placeholder="$t('SCHEDULING.GENERAL.VALUE')"
            @update:model-value="
              updateAppointmentFilterDraft(definition.key, $event)
            "
          />
        </div>
      </div>

      <template #footer>
        <div class="flex w-full flex-wrap items-center justify-between gap-3">
          <Button
            type="button"
            color="slate"
            variant="ghost"
            :label="$t('SCHEDULING.TOOLBAR.RESET_FILTERS')"
            @click="resetAppointmentFilters"
          />
          <div class="flex items-center gap-3">
            <Button
              type="button"
              color="slate"
              variant="faded"
              :label="$t('SCHEDULING.GENERAL.CANCEL')"
              @click="filterDialogRef?.close()"
            />
            <Button
              type="button"
              :label="$t('SCHEDULING.GENERAL.APPLY')"
              @click="applyAppointmentFilters"
            />
          </div>
        </div>
      </template>
    </Dialog>

    <Dialog
      ref="appointmentDeleteDialogRef"
      width="md"
      type="alert"
      :title="$t('SCHEDULING.APPOINTMENT_FORM.DELETE_TITLE')"
      :description="
        $t('SCHEDULING.APPOINTMENT_FORM.DELETE_DESCRIPTION', {
          name: formStore.form.clientName || '',
        })
      "
      :confirm-button-label="$t('SCHEDULING.APPOINTMENT_FORM.DELETE_CONFIRM')"
      :is-loading="formStore.ui.isSaving"
      @confirm="handleAppointmentDelete"
    />
  </section>
</template>

<style scoped>
.appointment-contact-accordion {
  @apply grid gap-2;
}

.appointment-contact-accordion-summary {
  @apply flex items-center gap-3 rounded-lg px-1 py-1;
}

.appointment-contact-section {
  @apply grid gap-2;
}

.appointment-contact-section-heading {
  @apply flex items-center justify-between gap-3;
}

.appointment-drawer-form {
  @apply grid gap-3;
}

.appointment-drawer-form :deep(section:not(.appointment-contact-accordion)),
.appointment-drawer-section {
  @apply grid gap-2 border-t border-n-weak pt-3;
}

.appointment-drawer-form > :first-child:not(.appointment-contact-section),
.appointment-drawer-form
  :deep(
    section:first-of-type:not(.appointment-contact-accordion):not(
        .appointment-details-section
      )
  ) {
  @apply border-t-0 pt-0;
}

.appointment-drawer-form
  :deep(section:not(.appointment-contact-accordion) > div:first-child) {
  @apply gap-0;
}

.appointment-drawer-form
  :deep(section:not(.appointment-contact-accordion) > div:first-child p) {
  @apply hidden;
}

.appointment-drawer-form
  :deep(section:not(.appointment-contact-accordion) > div:last-child) {
  @apply gap-2 pt-1;
}

.appointment-drawer-form :deep(label),
.appointment-drawer-form :deep(.text-heading-3),
.appointment-drawer-form :deep(.mb-0\.5.text-sm.font-medium) {
  @apply mb-0 min-w-0 text-[13px] leading-4 text-n-slate-12;
  font-weight: 500;
}

.appointment-drawer-form :deep(input),
.appointment-drawer-form :deep(select),
.appointment-drawer-form :deep(.reka-date-time-picker__trigger) {
  @apply border border-n-weak bg-n-alpha-black2 text-sm font-normal text-n-slate-12 shadow-none outline outline-1 outline-transparent transition-colors duration-150 !important;
  border-radius: 0.375rem !important;
  min-height: 2rem !important;
}

.appointment-drawer-form :deep(input),
.appointment-drawer-form :deep(select),
.appointment-drawer-form :deep(.reka-date-time-picker__trigger) {
  height: 2rem !important;
}

.appointment-drawer-form :deep(input:not([type='tel'])) {
  @apply px-2 py-1 !important;
}

.appointment-drawer-form :deep(.appointment-drawer-phone-control > div > div),
.appointment-drawer-form
  :deep(.appointment-drawer-phone-control > div > input) {
  @apply !h-8 !min-h-8;
}

.appointment-drawer-form :deep(.appointment-drawer-phone-control > div > div) {
  @apply !rounded-r-none !px-2;
}

.appointment-drawer-form
  :deep(.appointment-drawer-phone-control > div > input) {
  @apply !rounded-l-none;
}

.appointment-drawer-form
  :deep(.appointment-drawer-money-control .pointer-events-none) {
  @apply !h-8 !items-center;
}

.appointment-drawer-form :deep(.reka-date-time-picker__trigger),
.appointment-drawer-form :deep(.appointment-drawer-select-control button) {
  @apply justify-start py-1 !important;
}

.appointment-drawer-form :deep(.appointment-drawer-select-control button) {
  @apply !h-8 !min-h-8 !rounded-md !py-1 !text-sm !font-normal !text-n-slate-12;
}

.appointment-drawer-form :deep(.appointment-drawer-multi-control button) {
  @apply !min-h-8 !rounded-md !px-2 !py-1 !text-sm !font-normal !text-n-slate-12;
}

.appointment-drawer-form :deep(.appointment-contact-select-control button) {
  @apply !h-8 !min-h-8 !w-8 !justify-center !rounded-md !px-0 !py-1;
}

.appointment-drawer-form
  :deep(.appointment-contact-select-control button > span > span.min-w-0),
.appointment-drawer-form
  :deep(
    .appointment-contact-select-control
      button
      > span
      > span.i-lucide-chevron-down
  ),
.appointment-drawer-form
  :deep(
    .appointment-contact-select-control button > span > span.i-lucide-chevron-up
  ) {
  @apply hidden;
}

@media (min-width: 768px) {
  .appointment-money-grid {
    grid-template-columns: minmax(0, 1.1fr) minmax(0, 0.9fr) minmax(0, 0.85fr);
  }
}

.appointment-drawer-form :deep(input:hover),
.appointment-drawer-form :deep(select:hover),
.appointment-drawer-form :deep(.reka-date-time-picker__trigger:hover),
.appointment-drawer-form :deep(.appointment-drawer-select-control button:hover),
.appointment-drawer-form :deep(.appointment-drawer-multi-control button:hover) {
  @apply border-n-slate-6 bg-n-alpha-black2 outline-transparent !important;
}

.appointment-drawer-form :deep(input:focus),
.appointment-drawer-form :deep(select:focus),
.appointment-drawer-form :deep(.reka-date-time-picker__trigger:focus),
.appointment-drawer-form
  :deep(.reka-date-time-picker__trigger[data-state='open']),
.appointment-drawer-form :deep(.appointment-drawer-select-control button:focus),
.appointment-drawer-form :deep(.appointment-drawer-multi-control button:focus) {
  @apply border-n-weak bg-n-alpha-black2 outline-n-brand !important;
}
</style>
