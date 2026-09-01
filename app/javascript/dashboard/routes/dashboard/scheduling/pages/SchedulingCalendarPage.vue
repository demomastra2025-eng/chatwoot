<script setup>
import {
  computed,
  onBeforeUnmount,
  onMounted,
  reactive,
  ref,
  watch,
} from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';

import { useAccount } from 'dashboard/composables/useAccount';
import { useAlert } from 'dashboard/composables';
import SchedulingAppointmentsAPI from 'dashboard/api/scheduling/appointments';
import Button from 'dashboard/components-next/button/Button.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
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
import {
  buildMedelementProviderCommandDetails,
  buildMedelementProviderCommandParams,
  canCreateAppointmentConversation,
  formatCalendarTitle,
  isAppointmentProviderOwned,
  isMedelementResource,
  medelementCommandFailureMessage,
  medelementCabinetsForResource,
  resolveAppointmentMedelementCabinetCode,
  resolveAppointmentConversationTarget,
  servicesAvailableForResource,
} from '../helpers';
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
import {
  buildProviderCommandAction,
  useSchedulingProviderCommandsStore,
} from 'dashboard/stores/scheduling/providerCommands';
import { useSchedulingReferencesStore } from 'dashboard/stores/scheduling/references';
import {
  buildContactableInboxesList,
  fetchContactableInboxes,
} from 'dashboard/components-next/NewConversation/helpers/composeConversationHelper.js';

const { t, locale } = useI18n();
const calendarStore = useSchedulingCalendarStore();
const crmReferencesStore = useCrmReferencesStore();
const referencesStore = useSchedulingReferencesStore();
const formStore = useSchedulingAppointmentFormStore();
const providerCommandsStore = useSchedulingProviderCommandsStore();
const { currentAccount } = useAccount();
const route = useRoute();
const router = useRouter();
const currentPresentation = ref('calendar');
const contactEditorMode = ref(null);
const inlineContactDraftInitialized = ref(false);
const customFieldFilters = ref({});
const filterDialogRef = ref(null);
const appointmentFilterDraft = reactive({
  customFieldFilters: {},
  paymentStatusFilters: [],
  showInactiveAppointments: false,
  statusFilters: [],
});
const pendingCreateCustomFieldDefaultsHydration = ref(false);
const appointmentDeleteDialogRef = ref(null);
const providerCommandDialogRef = ref(null);
const pendingProviderAction = ref(null);
const patientCandidates = ref([]);
const selectedPatientToken = ref('');
const showAppointmentConversationPanel = ref(false);
const appointmentConversationDraft = reactive({
  contactId: '',
  contactableInboxes: [],
  contextRequestId: 0,
  isCreating: false,
  isLoadingInboxes: false,
});
const appointmentContactableInboxesByContactId = ref({});
const appointmentConversationContactCreateRequested = ref(false);
let appointmentConversationCreateRequestId = 0;
let appointmentConversationDisposed = false;

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
    'SCHEDULING.APPOINTMENT_FORM.ERRORS.MEDELEMENT_PHONE_REQUIRED': t(
      'SCHEDULING.APPOINTMENT_FORM.ERRORS.MEDELEMENT_PHONE_REQUIRED'
    ),
    'SCHEDULING.APPOINTMENT_FORM.ERRORS.MEDELEMENT_SERVICE_REQUIRED': t(
      'SCHEDULING.APPOINTMENT_FORM.ERRORS.MEDELEMENT_SERVICE_REQUIRED'
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

const appointmentClientName = () =>
  [
    formStore.form.clientFirstName,
    formStore.form.clientLastName,
    formStore.form.clientMiddleName,
  ]
    .map(value => String(value || '').trim())
    .filter(Boolean)
    .join(' ') || formStore.form.clientName;

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
const isSelectedAppointmentProviderOwned = computed(
  () =>
    formStore.mode === 'edit' &&
    isAppointmentProviderOwned(formStore.selectedAppointment)
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

const selectedFormMedelementCabinets = computed(() =>
  medelementCabinetsForResource(selectedFormResource.value)
);
const isSelectedFormResourceMedelement = computed(() =>
  isMedelementResource(selectedFormResource.value)
);
const medelementCabinetOptions = computed(() =>
  selectedFormMedelementCabinets.value.map(cabinet => ({
    label:
      [cabinet.name, cabinet.number].filter(Boolean).join(' · ') ||
      cabinet.code,
    value: cabinet.code,
  }))
);
const isMedelementCabinetMissing = computed(
  () =>
    isSelectedFormResourceMedelement.value &&
    !formStore.form.medelementCabinetCode
);
const isMedelementContactMissing = computed(
  () => isSelectedFormResourceMedelement.value && !formStore.form.contactId
);
const canCreateMedelementReception = computed(
  () =>
    formStore.mode === 'edit' &&
    !isSelectedAppointmentProviderOwned.value &&
    isSelectedFormResourceMedelement.value &&
    ['scheduled', 'confirmed'].includes(formStore.form.status)
);
const patientActionStatuses = new Set([
  'awaiting_patient_creation',
  'awaiting_patient_selection',
  'awaiting_phone_refresh',
]);

const providerCommandTitle = computed(() => {
  const status = pendingProviderAction.value?.command?.status;
  if (status === 'awaiting_patient_selection') {
    return t('SCHEDULING.MEDELEMENT.PATIENT_SELECTION_TITLE');
  }
  if (status === 'awaiting_patient_creation') {
    return t('SCHEDULING.MEDELEMENT.PATIENT_CREATION_TITLE');
  }
  if (status === 'awaiting_phone_refresh') {
    return t('SCHEDULING.MEDELEMENT.PHONE_REFRESH_TITLE');
  }

  const operation = pendingProviderAction.value?.params?.operation;
  if (operation === 'create_reception') {
    return t('SCHEDULING.MEDELEMENT.CREATE_CONFIRM_TITLE');
  }
  if (operation === 'move_reception') {
    return t('SCHEDULING.MEDELEMENT.MOVE_CONFIRM_TITLE');
  }
  if (operation === 'remove_reception') {
    return t('SCHEDULING.MEDELEMENT.REMOVE_CONFIRM_TITLE');
  }

  return t('SCHEDULING.MEDELEMENT.CONFIRM_TITLE');
});
const formatProviderCommandDateTime = value => {
  if (!value) return '—';

  return new Intl.DateTimeFormat(
    locale.value?.replace(/_/g, '-') || undefined,
    {
      dateStyle: 'medium',
      timeStyle: 'short',
    }
  ).format(new Date(value));
};
const formatProviderCommandRange = (startsAt, endsAt) => {
  const start = formatProviderCommandDateTime(startsAt);
  const end = formatProviderCommandDateTime(endsAt);
  return endsAt ? `${start} — ${end}` : start;
};
const providerCommandDescription = computed(() => {
  const action = pendingProviderAction.value || {};
  const command = action.command;
  if (command?.status === 'awaiting_patient_selection') {
    return t('SCHEDULING.MEDELEMENT.PATIENT_SELECTION_DESCRIPTION', {
      count:
        command.patientAction?.candidateCount || patientCandidates.value.length,
    });
  }
  if (command?.status === 'awaiting_patient_creation') {
    const missing = command.patientAction?.missingFields || [];
    return missing.length
      ? t('SCHEDULING.MEDELEMENT.PATIENT_CREATION_INCOMPLETE', {
          fields: missing.join(', '),
        })
      : t('SCHEDULING.MEDELEMENT.PATIENT_CREATION_DESCRIPTION');
  }
  if (command?.status === 'awaiting_phone_refresh') {
    return t('SCHEDULING.MEDELEMENT.PHONE_REFRESH_UNSUPPORTED');
  }

  const details = buildMedelementProviderCommandDetails(action);
  const price =
    details.price === null
      ? '—'
      : new Intl.NumberFormat(locale.value?.replace(/_/g, '-') || undefined, {
          currency: 'KZT',
          style: 'currency',
        }).format(details.price);
  const currentRange = formatProviderCommandRange(
    details.currentStartsAt,
    details.currentEndsAt
  );
  const time = details.desiredStartsAt
    ? `${currentRange} → ${formatProviderCommandRange(
        details.desiredStartsAt,
        details.desiredEndsAt
      )}`
    : currentRange;
  const cabinetLabel =
    medelementCabinetOptions.value.find(
      option => option.value === details.cabinetCode
    )?.label || details.cabinetCode;
  const rows = [
    `${t('SCHEDULING.MEDELEMENT.DETAIL_PATIENT')}: ${details.patientName || '—'}`,
    `${t('SCHEDULING.MEDELEMENT.DETAIL_SPECIALIST')}: ${details.specialistName || '—'}`,
    `${t('SCHEDULING.MEDELEMENT.DETAIL_SERVICE')}: ${details.serviceName || '—'}`,
    `${t('SCHEDULING.MEDELEMENT.DETAIL_CABINET')}: ${cabinetLabel || '—'}`,
    `${t('SCHEDULING.MEDELEMENT.DETAIL_PRICE')}: ${price}`,
    `${t('SCHEDULING.MEDELEMENT.DETAIL_DURATION')}: ${details.durationMin || '—'} ${t(
      'SCHEDULING.GENERAL.MINUTES'
    )}`,
    `${t('SCHEDULING.MEDELEMENT.DETAIL_TIME')}: ${time}`,
  ];

  const description = `${t('SCHEDULING.MEDELEMENT.CONFIRM_DESCRIPTION', {
    name: details.patientName || '—',
  })} ${rows.join(' · ')}`;
  return action.intentMismatch
    ? `${t('SCHEDULING.MEDELEMENT.STALE_COMMAND_DESCRIPTION')} ${description}`
    : description;
});

const providerCommandConfirmLabel = computed(() => {
  const status = pendingProviderAction.value?.command?.status;
  if (status === 'awaiting_patient_selection') {
    return t('SCHEDULING.MEDELEMENT.PATIENT_SELECT_ACTION');
  }
  if (status === 'awaiting_patient_creation') {
    return t('SCHEDULING.MEDELEMENT.PATIENT_CREATE_ACTION');
  }
  if (status === 'awaiting_phone_refresh') {
    return t('SCHEDULING.MEDELEMENT.PHONE_RETRY_ACTION');
  }

  return t('SCHEDULING.MEDELEMENT.CONFIRM_ACTION');
});
const showProviderCommandConfirm = computed(() =>
  patientActionStatuses.has(pendingProviderAction.value?.command?.status)
);
const disableProviderCommandConfirm = computed(() => {
  if (providerCommandsStore.ui.isExecuting) return true;

  if (pendingProviderAction.value?.intentMismatch) return true;

  const command = pendingProviderAction.value?.command;
  if (command?.status === 'awaiting_patient_selection') {
    return !selectedPatientToken.value;
  }
  if (command?.status === 'awaiting_patient_creation') {
    return command.patientAction?.canConfirm !== true;
  }

  return false;
});
const showProviderCommandCancel = computed(() => {
  const action = pendingProviderAction.value;
  return Boolean(
    action?.command &&
      (action.intentMismatch ||
        patientActionStatuses.has(action.command.status))
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
  servicesAvailableForResource(
    referencesStore.activeServices || referencesStore.services || [],
    selectedFormResource.value
  ).map(service => ({
    label: service.name,
    value: service.id,
  }))
);
const hasServiceOptions = computed(() => serviceOptions.value.length > 0);

const companySelectionEnabled = computed(
  () => currentAccount.value?.settings?.scheduling_company_enabled !== false
);

const contactSelectionRequired = computed(
  () => currentAccount.value?.settings?.scheduling_contact_required !== false
);

const contactOptionLabel = contact => {
  const iin =
    contact.identifier ||
    contact.customAttributes?.iin ||
    contact.customAttributes?.medelementIin ||
    contact.custom_attributes?.iin ||
    contact.custom_attributes?.medelement_iin;

  return [
    contact.fullName,
    contact.phone,
    iin ? `${t('SCHEDULING.CONTACT.IIN')}: ${iin}` : '',
  ]
    .filter(Boolean)
    .join(' · ');
};

const contactOptions = computed(() => {
  const options = formStore.contacts.map(contact => ({
    label: contactOptionLabel(contact),
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

  const fallbackLabel = contactOptionLabel({
    fullName: formStore.selectedContact?.fullName || appointmentClientName(),
    identifier:
      formStore.selectedContact?.identifier || formStore.form.clientIdentifier,
    phone: formStore.selectedContact?.phone || formStore.form.clientPhone,
  });

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

const appointmentConversationMatchesSelectedContact = computed(() => {
  const persistedContactId = Number(
    formStore.selectedAppointment?.contactId ||
      formStore.selectedAppointment?.contact_id
  );
  const selectedContactId = Number(formStore.form.contactId);

  if (!persistedContactId && !selectedContactId) return true;
  return persistedContactId === selectedContactId;
});

const appointmentConversationTarget = computed(() =>
  appointmentConversationMatchesSelectedContact.value
    ? resolveAppointmentConversationTarget(formStore.selectedAppointment)
    : resolveAppointmentConversationTarget(null)
);
const appointmentChatConversationId = computed(
  () => appointmentConversationTarget.value.conversationId
);
const appointmentChatConversationDisplayId = computed(
  () => appointmentConversationTarget.value.conversationDisplayId
);
const appointmentCommunicationThreadId = computed(
  () => appointmentConversationTarget.value.communicationThreadId
);
const appointmentCommunicationThreadDisplayId = computed(
  () => appointmentConversationTarget.value.communicationThreadDisplayId
);
const hasAppointmentConversationTarget = computed(
  () =>
    !!appointmentCommunicationThreadDisplayId.value ||
    !!appointmentCommunicationThreadId.value ||
    !!appointmentChatConversationDisplayId.value ||
    !!appointmentChatConversationId.value
);

const appointmentConversationContacts = computed(() => {
  const contactId = Number(formStore.form.contactId);
  if (!Number.isFinite(contactId) || contactId <= 0) return [];

  const contact = formStore.selectedContact;
  return [
    {
      id: contactId,
      label: [
        contact?.fullName || appointmentClientName(),
        contact?.phone || formStore.form.clientPhone,
      ]
        .filter(Boolean)
        .join(' · '),
      value: contactId,
    },
  ];
});

const canOpenAppointmentConversation = computed(
  () => formStore.mode === 'edit'
);
const canManageAppointmentConversation = computed(
  () =>
    formStore.mode === 'edit' &&
    canCreateAppointmentConversation(formStore.selectedAppointment)
);
const shouldShowAppointmentConversationPanel = computed(
  () =>
    canOpenAppointmentConversation.value &&
    showAppointmentConversationPanel.value
);

const appointmentDrawerModalClass = computed(() => [
  'mx-auto flex h-full w-full overflow-hidden rounded-2xl border border-n-weak bg-n-solid-2 shadow-2xl',
  shouldShowAppointmentConversationPanel.value
    ? 'max-w-[min(96rem,calc(100vw-1.5rem))] flex-col md:flex-row'
    : 'max-w-[min(30rem,calc(100vw-1.5rem))] flex-col',
]);

const contactEditorActionLabel = computed(() =>
  isEditingContact.value
    ? t('SCHEDULING.CONTACT.SAVE_ACTION')
    : t('SCHEDULING.CONTACT.CREATE_ACTION')
);
const requiredContactLabel = label => `${label} *`;

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

const isInlineContactMedelementContext = computed(
  () =>
    isSelectedFormResourceMedelement.value ||
    Boolean(
      formStore.selectedContact?.customAttributes?.medelementPatientCode ||
        formStore.selectedContact?.custom_attributes?.medelement_patient_code
    )
);

const inlineContactIinMessage = computed(() => {
  if (!inlineContactForm.iin) {
    return isInlineContactMedelementContext.value
      ? t('SCHEDULING.CONTACT.IIN_REQUIRED')
      : '';
  }
  if (inlineContactIinState.value.valid) return '';

  if (inlineContactIinState.value.reason === 'length') {
    return t('SCHEDULING.CONTACT.IIN_ERROR_LENGTH');
  }

  return t('SCHEDULING.CONTACT.IIN_ERROR_INVALID');
});
const inlineContactLastNameMessage = computed(() => {
  if (
    isInlineContactMedelementContext.value &&
    !String(formStore.form.clientLastName || '').trim()
  ) {
    return t('SCHEDULING.APPOINTMENT_FORM.ERRORS.CLIENT_LAST_NAME_REQUIRED');
  }

  return validationErrorMessage(formStore.validationErrors.clientLastName);
});
const inlineContactMiddleNameMessage = computed(() => {
  if (
    isInlineContactMedelementContext.value &&
    !String(formStore.form.clientMiddleName || '').trim()
  ) {
    return t('SCHEDULING.APPOINTMENT_FORM.ERRORS.CLIENT_MIDDLE_NAME_REQUIRED');
  }

  return validationErrorMessage(formStore.validationErrors.clientMiddleName);
});
const isInlineContactSaveDisabled = computed(
  () =>
    !String(formStore.form.clientFirstName || '').trim() ||
    Boolean(inlineContactLastNameMessage.value) ||
    Boolean(inlineContactMiddleNameMessage.value) ||
    Boolean(inlineContactIinMessage.value)
);

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
  appointmentFilterDraft.showInactiveAppointments =
    calendarStore.showInactiveAppointments;
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
  calendarStore.setShowInactiveAppointments(
    appointmentFilterDraft.showInactiveAppointments
  );
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

const resetAppointmentConversationDraft = () => {
  appointmentConversationDraft.contextRequestId += 1;
  appointmentConversationDraft.contactId = formStore.form.contactId || '';
  appointmentConversationDraft.contactableInboxes = [];
  appointmentConversationDraft.isCreating = false;
  appointmentConversationDraft.isLoadingInboxes = false;
};

const setAppointmentConversationContact = contactId => {
  const normalizedContactId = Number(contactId);
  appointmentConversationDraft.contextRequestId += 1;
  appointmentConversationDraft.contactId =
    Number.isFinite(normalizedContactId) && normalizedContactId > 0
      ? normalizedContactId
      : '';
  appointmentConversationDraft.contactableInboxes = [];
  appointmentConversationDraft.isLoadingInboxes = false;
  return appointmentConversationDraft.contextRequestId;
};

const loadAppointmentConversationInboxes = async contextRequestId => {
  appointmentConversationDraft.contactableInboxes = [];
  const contactId = appointmentConversationDraft.contactId;
  if (!contactId) return;

  const cachedInboxes =
    appointmentContactableInboxesByContactId.value[contactId];
  if (cachedInboxes) {
    if (contextRequestId === appointmentConversationDraft.contextRequestId) {
      appointmentConversationDraft.contactableInboxes = cachedInboxes;
    }
    return;
  }

  appointmentConversationDraft.isLoadingInboxes = true;

  try {
    const contactableInboxes = buildContactableInboxesList(
      await fetchContactableInboxes(contactId)
    );
    appointmentContactableInboxesByContactId.value = {
      ...appointmentContactableInboxesByContactId.value,
      [contactId]: contactableInboxes,
    };
    if (contextRequestId === appointmentConversationDraft.contextRequestId) {
      appointmentConversationDraft.contactableInboxes = contactableInboxes;
    }
  } catch {
    if (contextRequestId === appointmentConversationDraft.contextRequestId) {
      appointmentConversationDraft.contactableInboxes = [];
      useAlert(t('SCHEDULING.CONVERSATION_PLACEHOLDER.INBOXES_LOAD_ERROR'));
    }
  } finally {
    if (contextRequestId === appointmentConversationDraft.contextRequestId) {
      appointmentConversationDraft.isLoadingInboxes = false;
    }
  }
};

const loadAppointmentConversationContext = async contactId => {
  if (
    hasAppointmentConversationTarget.value &&
    Number(contactId) === Number(formStore.form.contactId)
  ) {
    return [];
  }

  const contextRequestId = setAppointmentConversationContact(contactId);

  if (!appointmentConversationDraft.contactId) return [];

  await loadAppointmentConversationInboxes(contextRequestId);
  return [];
};

const createAppointmentConversation = async ({ contactId, inbox }) => {
  const appointmentId = Number(formStore.recordId);
  if (
    appointmentConversationDraft.isCreating ||
    !canManageAppointmentConversation.value ||
    !Number.isFinite(appointmentId) ||
    appointmentId <= 0 ||
    !inbox
  ) {
    return;
  }

  const normalizedContactId = Number(contactId);
  const inboxId = Number(inbox.value || inbox.id);
  if (
    !Number.isFinite(normalizedContactId) ||
    normalizedContactId <= 0 ||
    !Number.isFinite(inboxId) ||
    inboxId <= 0
  ) {
    return;
  }

  const contextRequestId = appointmentConversationDraft.contextRequestId;
  const isCurrentContext = () =>
    !appointmentConversationDisposed &&
    contextRequestId === appointmentConversationDraft.contextRequestId &&
    Number(formStore.recordId) === appointmentId &&
    Number(formStore.form.contactId) === normalizedContactId;
  appointmentConversationCreateRequestId += 1;
  const createRequestId = appointmentConversationCreateRequestId;
  appointmentConversationDraft.isCreating = true;

  try {
    await formStore.createAndLinkConversation(
      {
        appointmentId,
        contactId: normalizedContactId,
        inbox,
      },
      calendarStore,
      isCurrentContext
    );
    if (!isCurrentContext()) return;
    resetAppointmentConversationDraft();
    showAppointmentConversationPanel.value = true;
    useAlert(t('SCHEDULING.CONVERSATION_PLACEHOLDER.CREATED'));
  } catch (error) {
    if (isCurrentContext()) {
      useAlert(
        error?.response
          ? formatErrorMessage(error)
          : error?.message ||
              t('SCHEDULING.CONVERSATION_PLACEHOLDER.CREATE_ERROR')
      );
    }
  } finally {
    if (createRequestId === appointmentConversationCreateRequestId) {
      appointmentConversationDraft.isCreating = false;
    }
  }
};

const openCreateAppointment = (slot, defaults = {}) => {
  pendingCreateCustomFieldDefaultsHydration.value = true;
  showAppointmentConversationPanel.value = false;
  appointmentConversationContactCreateRequested.value = false;
  contactEditorMode.value = 'create';
  inlineContactDraftInitialized.value = false;
  resetInlineContactForm();
  formStore.openCreate(slot, {
    customAttributes: buildDefaultCustomAttributes(
      appointmentFieldDefinitions.value
    ),
    ...defaults,
  });
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
  appointmentConversationContactCreateRequested.value = false;
  formStore.close();
  formStore.reset();
  resetAppointmentConversationDraft();
  contactEditorMode.value = null;
  inlineContactDraftInitialized.value = false;
  resetInlineContactForm();
};

const fillInlineContactForm = source => {
  Object.assign(inlineContactForm, {
    birthDate: source?.birthDate || source?.clientBirthDate || '',
    fullName: source?.fullName || source?.clientName || '',
    gender: source?.gender || source?.clientGender || '',
    id: source?.id || null,
    iin:
      source?.customAttributes?.iin ||
      source?.identifier ||
      source?.clientIdentifier ||
      '',
    phone: source?.phone || source?.clientPhone || '',
  });
};

const openInlineContactCreate = () => {
  contactEditorMode.value = 'create';
  if (inlineContactDraftInitialized.value) return;

  if (formStore.form.contactId) {
    resetInlineContactForm();
  } else {
    fillInlineContactForm(formStore.form);
  }

  inlineContactDraftInitialized.value = true;
};

const handleAppointmentConversationAddContact = () => {
  if (!canManageAppointmentConversation.value) return;

  appointmentConversationContactCreateRequested.value = true;
  showAppointmentConversationPanel.value = false;
  openInlineContactCreate();
};

function openInlineContactEdit() {
  if (!formStore.form.contactId) {
    return;
  }

  contactEditorMode.value = 'edit';
  fillInlineContactForm(
    formStore.selectedContact || {
      ...formStore.form,
      id: formStore.form.contactId,
    }
  );
}

const openEditAppointment = appointment => {
  formStore.openEdit(appointment);
  resetAppointmentConversationDraft();
  appointmentConversationContactCreateRequested.value = false;
  showAppointmentConversationPanel.value = true;
  if (formStore.form.contactId) {
    openInlineContactEdit();
  } else {
    openInlineContactCreate();
  }
};

const handleInlineContactSave = async () => {
  if (isInlineContactSaveDisabled.value) {
    useAlert(
      inlineContactLastNameMessage.value ||
        inlineContactMiddleNameMessage.value ||
        inlineContactIinMessage.value ||
        t('SCHEDULING.APPOINTMENT_FORM.ERRORS.CLIENT_NAME_REQUIRED')
    );
    return;
  }

  const contactPayload = {
    ...inlineContactForm,
    firstName: formStore.form.clientFirstName,
    fullName: appointmentClientName(),
    lastName: formStore.form.clientLastName,
    middleName: formStore.form.clientMiddleName,
    phone: formStore.form.clientPhone,
    resourceId: formStore.form.resourceId,
  };

  try {
    if (isEditingContact.value) {
      await formStore.updateInlineContact(
        formStore.form.contactId,
        contactPayload
      );
      useAlert(t('SCHEDULING.CONTACT.SUCCESS_UPDATE'));
      contactEditorMode.value = 'edit';
      fillInlineContactForm(formStore.selectedContact || formStore.form);
    } else {
      await formStore.createInlineContact(contactPayload);
      useAlert(t('SCHEDULING.CONTACT.SUCCESS_CREATE'));
      openInlineContactEdit();
      if (
        appointmentConversationContactCreateRequested.value &&
        formStore.mode === 'edit'
      ) {
        appointmentConversationContactCreateRequested.value = false;
        resetAppointmentConversationDraft();
        showAppointmentConversationPanel.value = true;
      }
    }
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
  const previousContactId = Number(formStore.form.contactId);
  const nextContactId = Number(contactId);
  const contactChanged = previousContactId !== nextContactId;

  formStore.updateField('contactId', contactId || '');
  if (contactChanged) {
    formStore.updateField('conversationDisplayId', '');
    formStore.updateField('conversationId', '');
    resetAppointmentConversationDraft();
  }

  if (!contactId) {
    formStore.selectedContact = null;
    formStore.updateField('clientBirthDate', '');
    formStore.updateField('clientFirstName', '');
    formStore.updateField('clientGender', '');
    formStore.updateField('clientIdentifier', '');
    formStore.updateField('clientLastName', '');
    formStore.updateField('clientMiddleName', '');
    formStore.updateField('clientPhone', '');
    inlineContactDraftInitialized.value = false;
    openInlineContactCreate();
    return;
  }

  const selectedContact = formStore.contacts.find(
    contact => Number(contact.id) === Number(contactId)
  );

  if (selectedContact) {
    formStore.applyContact(selectedContact);
    openInlineContactEdit();
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

const prepareProviderCommandAction = async (action, command) => {
  selectedPatientToken.value = '';
  patientCandidates.value = [];
  pendingProviderAction.value = { ...action, command };
  if (command?.status === 'awaiting_patient_selection') {
    const payload = await providerCommandsStore.loadPatientCandidates(command);
    patientCandidates.value = payload?.candidates || [];
  }
};

const refreshAfterProviderCommand = async action => {
  try {
    await calendarStore.refresh();
  } catch {
    // The provider result remains authoritative even if the calendar refresh fails.
  }

  if (action.closeDrawer) handleDrawerClose();
};

const showProviderCommandOutcome = async (action, command) => {
  if (patientActionStatuses.has(command.status)) {
    await prepareProviderCommandAction(action, command);
    providerCommandDialogRef.value?.open();
    return;
  }

  providerCommandDialogRef.value?.close();
  pendingProviderAction.value = null;
  await refreshAfterProviderCommand(action);

  if (command.status === 'succeeded') {
    useAlert(t('SCHEDULING.MEDELEMENT.SUCCESS'));
  } else if (command.status === 'reconciliation_required') {
    useAlert(t('SCHEDULING.MEDELEMENT.RECONCILING'));
  } else if (['cancelled', 'declined', 'failed'].includes(command.status)) {
    const failure = medelementCommandFailureMessage(command);
    if (failure.key === 'SCHEDULING.MEDELEMENT.AUTHENTICATION_FAILED') {
      useAlert(t('SCHEDULING.MEDELEMENT.AUTHENTICATION_FAILED'));
    } else if (failure.key === 'SCHEDULING.MEDELEMENT.PATIENT_CONFLICT') {
      useAlert(t('SCHEDULING.MEDELEMENT.PATIENT_CONFLICT'));
    } else {
      useAlert(t('SCHEDULING.MEDELEMENT.FAILED', failure.params));
    }
  } else {
    useAlert(t('SCHEDULING.MEDELEMENT.QUEUED'));
  }
};

const executeProviderCommandAction = async action => {
  if (action.intentMismatch) {
    await prepareProviderCommandAction(action, action.command);
    providerCommandDialogRef.value?.open();
    return;
  }

  if (patientActionStatuses.has(action.command?.status)) {
    await prepareProviderCommandAction(action, action.command);
    providerCommandDialogRef.value?.open();
    return;
  }

  if (action.command && action.command.status !== 'awaiting_confirmation') {
    useAlert(t('SCHEDULING.MEDELEMENT.QUEUED'));
    return;
  }

  const command = action.command
    ? await providerCommandsStore.confirmExisting(
        action.command,
        action.requestedParams
      )
    : await providerCommandsStore.executeConfirmed(action.params);
  await showProviderCommandOutcome(action, command);
};

const recoverConcurrentProviderCommand = async (action, error) => {
  const errorCode = error?.code || error?.response?.data?.code;
  if (errorCode !== 'MEDELEMENT_COMMAND_IN_PROGRESS') return false;

  const existing = await providerCommandsStore.findActive({
    appointmentId: action.appointment.id,
    provider: action.params.provider,
  });
  if (!existing) {
    useAlert(t('SCHEDULING.MEDELEMENT.QUEUED'));
    return true;
  }

  await executeProviderCommandAction(
    buildProviderCommandAction(action, existing)
  );
  return true;
};

const stageProviderCommand = async ({
  appointment,
  params,
  closeDrawer = false,
}) => {
  const action = { appointment, closeDrawer, params };
  try {
    const existing = await providerCommandsStore.findActive({
      appointmentId: appointment.id,
      provider: params.provider,
    });
    const stagedAction = buildProviderCommandAction(action, existing);
    await executeProviderCommandAction(stagedAction);
  } catch (error) {
    try {
      if (await recoverConcurrentProviderCommand(action, error)) return;
    } catch (recoveryError) {
      useAlert(formatErrorMessage(recoveryError));
      return;
    }
    useAlert(formatErrorMessage(error));
  }
};

const stageCreateMedelementReception = appointment => {
  const companyCabinetCode = formStore.form.medelementCabinetCode;
  if (!companyCabinetCode) {
    useAlert(t('SCHEDULING.MEDELEMENT.CABINET_REQUIRED'));
    return;
  }
  if (!formStore.form.contactId) {
    useAlert(t('SCHEDULING.MEDELEMENT.CONTACT_REQUIRED'));
    return;
  }

  stageProviderCommand({
    appointment,
    params: buildMedelementProviderCommandParams({
      appointment,
      companyCabinetCode,
      operation: 'create_reception',
    }),
  });
};

const handleProviderCommandConfirm = async () => {
  const action = pendingProviderAction.value;
  if (!action || providerCommandsStore.ui.isExecuting) return;
  if (action.intentMismatch) {
    useAlert(t('SCHEDULING.MEDELEMENT.STALE_COMMAND_DESCRIPTION'));
    return;
  }

  try {
    let command;
    if (action.command?.status === 'awaiting_patient_selection') {
      command = await providerCommandsStore.selectPatient(
        action.command,
        selectedPatientToken.value,
        action.requestedParams
      );
    } else if (action.command?.status === 'awaiting_patient_creation') {
      command = await providerCommandsStore.confirmPatientCreation(
        action.command,
        action.requestedParams
      );
    } else if (action.command?.status === 'awaiting_phone_refresh') {
      command = await providerCommandsStore.retryPhoneMismatch(
        action.command,
        action.requestedParams
      );
    } else {
      return;
    }

    await showProviderCommandOutcome(action, command);
  } catch (error) {
    providerCommandDialogRef.value?.close();
    useAlert(formatErrorMessage(error));
  }
};

const handleProviderCommandCancel = async () => {
  const command = pendingProviderAction.value?.command;
  if (!command || providerCommandsStore.ui.isExecuting) return;

  try {
    await providerCommandsStore.cancel(command);
    providerCommandDialogRef.value?.close();
  } catch (error) {
    useAlert(formatErrorMessage(error));
  } finally {
    pendingProviderAction.value = null;
  }
};

const handleProviderCommandDialogClose = () => {
  if (!providerCommandsStore.ui.isExecuting) {
    pendingProviderAction.value = null;
  }
};

const handleAppointmentSubmit = async () => {
  if (isSelectedAppointmentProviderOwned.value) return;

  if (isMedelementCabinetMissing.value) {
    useAlert(t('SCHEDULING.MEDELEMENT.CABINET_REQUIRED'));
    return;
  }
  if (isMedelementContactMissing.value) {
    useAlert(t('SCHEDULING.MEDELEMENT.CONTACT_REQUIRED'));
    return;
  }

  try {
    const shouldCreateInMedelement =
      isSelectedFormResourceMedelement.value &&
      !isSelectedAppointmentProviderOwned.value;
    const companyCabinetCode = formStore.form.medelementCabinetCode;
    const appointment = await formStore.submit(calendarStore);
    useAlert(t('SCHEDULING.APPOINTMENT_FORM.SUCCESS_SAVE'));
    handleDrawerClose();

    if (shouldCreateInMedelement) {
      stageProviderCommand({
        appointment,
        params: buildMedelementProviderCommandParams({
          appointment,
          companyCabinetCode,
          operation: 'create_reception',
        }),
      });
    }
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const handleAppointmentCancel = async () => {
  if (isSelectedAppointmentProviderOwned.value) {
    stageProviderCommand({
      appointment: formStore.selectedAppointment,
      closeDrawer: true,
      params: buildMedelementProviderCommandParams({
        appointment: formStore.selectedAppointment,
        operation: 'remove_reception',
      }),
    });
    return;
  }

  try {
    await formStore.cancel(calendarStore);
    useAlert(t('SCHEDULING.APPOINTMENT_FORM.SUCCESS_CANCEL'));
    handleDrawerClose();
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const openAppointmentDeleteDialog = () => {
  if (isSelectedAppointmentProviderOwned.value) return;

  appointmentDeleteDialogRef.value?.open();
};

const handleAppointmentDelete = async () => {
  if (isSelectedAppointmentProviderOwned.value) return;

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
  if (isAppointmentProviderOwned(appointment)) {
    const requestedResourceId = Number(
      patch.resource_id || appointment.resourceId
    );
    if (requestedResourceId !== Number(appointment.resourceId)) {
      await calendarStore.refresh();
      useAlert(t('SCHEDULING.MEDELEMENT.RESOURCE_CHANGE_UNSUPPORTED'));
      return;
    }

    const companyCabinetCode = resolveAppointmentMedelementCabinetCode(
      appointment,
      referencesStore.resources
    );
    if (!companyCabinetCode) {
      await calendarStore.refresh();
      useAlert(t('SCHEDULING.MEDELEMENT.CABINET_REQUIRED'));
      return;
    }

    stageProviderCommand({
      appointment,
      params: buildMedelementProviderCommandParams({
        appointment,
        companyCabinetCode,
        operation: 'move_reception',
        patch,
      }),
    });
    await calendarStore.refresh();
    return;
  }

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
  () => formStore.form.resourceId,
  () => {
    if (!isSelectedFormResourceMedelement.value) {
      if (formStore.form.medelementCabinetCode) {
        formStore.updateField('medelementCabinetCode', '');
      }
      return;
    }

    const currentCode = String(formStore.form.medelementCabinetCode || '');
    const validCurrentCode = selectedFormMedelementCabinets.value.some(
      cabinet => cabinet.code === currentCode
    );
    if (validCurrentCode) return;

    formStore.updateField(
      'medelementCabinetCode',
      selectedFormMedelementCabinets.value.length === 1
        ? selectedFormMedelementCabinets.value[0].code
        : ''
    );
  }
);

watch(
  [() => formStore.isOpen, serviceOptions],
  ([isOpen, options]) => {
    if (!isOpen) return;

    const availableIds = new Set(options.map(option => Number(option.value)));
    const selectedIds = formStore.form.serviceIds || [];
    const compatibleIds = selectedIds.filter(id =>
      availableIds.has(Number(id))
    );
    if (compatibleIds.length !== selectedIds.length) {
      formStore.updateField('serviceIds', compatibleIds);
    }
  },
  { immediate: true, deep: true }
);

watch(
  [
    contactSelectionRequired,
    companySelectionEnabled,
    isSelectedFormResourceMedelement,
  ],
  ([contactRequired, companyEnabled, medelementRequired]) => {
    formStore.setRequirements({
      contactRequired,
      companyEnabled,
      medelementIdentityRequired: medelementRequired,
      medelementPhoneRequired: medelementRequired,
      medelementServiceRequired: false,
    });
  },
  { immediate: true }
);

onBeforeUnmount(() => {
  appointmentConversationDisposed = true;
  appointmentConversationDraft.contextRequestId += 1;
  appointmentConversationCreateRequestId += 1;
});

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
              <h2
                id="scheduling-appointment-drawer-title"
                class="mb-0 min-w-0 flex-1 truncate text-base font-semibold text-n-slate-12"
              >
                {{ drawerTitle }}
              </h2>

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
                :disabled="
                  formStore.isFormInvalid ||
                  formStore.ui.isSaving ||
                  isMedelementCabinetMissing ||
                  isMedelementContactMissing ||
                  isSelectedAppointmentProviderOwned
                "
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
                  </div>

                  <SchedulingSelectField
                    :model-value="formStore.form.contactId"
                    :options="contactOptions"
                    use-api-results
                    search-in-trigger
                    :search-debounce-ms="250"
                    inline-dropdown
                    dropdown-align="start"
                    :dropdown-min-width="405"
                    :placeholder="
                      $t('SCHEDULING.APPOINTMENT_FORM.CONTACT_SEARCH')
                    "
                    :aria-label="
                      $t('SCHEDULING.APPOINTMENT_FORM.CONTACT_SEARCH')
                    "
                    :search-placeholder="
                      $t('SCHEDULING.APPOINTMENT_FORM.CONTACT_SEARCH')
                    "
                    :empty-state="
                      $t('SCHEDULING.APPOINTMENT_FORM.CONTACT_EMPTY')
                    "
                    @open="handleContactDropdownOpen"
                    @search="formStore.searchContacts($event)"
                    @update:model-value="handleContactSelect"
                  />

                  <div class="appointment-contact-accordion">
                    <div
                      v-if="isContactEditorOpen"
                      class="appointment-contact-accordion-summary"
                    >
                      <div class="grid min-w-0 flex-1 gap-2 md:grid-cols-3">
                        <Input
                          :model-value="formStore.form.clientFirstName"
                          :label="
                            requiredContactLabel(
                              $t(
                                'SCHEDULING.APPOINTMENT_FORM.CLIENT_FIRST_NAME'
                              )
                            )
                          "
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
                          @update:model-value="
                            formStore.updateField('clientFirstName', $event)
                          "
                        />
                        <Input
                          :model-value="formStore.form.clientLastName"
                          :label="
                            isInlineContactMedelementContext
                              ? requiredContactLabel(
                                  $t(
                                    'SCHEDULING.APPOINTMENT_FORM.CLIENT_LAST_NAME'
                                  )
                                )
                              : $t(
                                  'SCHEDULING.APPOINTMENT_FORM.CLIENT_LAST_NAME'
                                )
                          "
                          :message="inlineContactLastNameMessage"
                          :message-type="
                            inlineContactLastNameMessage ? 'error' : 'info'
                          "
                          @update:model-value="
                            formStore.updateField('clientLastName', $event)
                          "
                        />
                        <Input
                          :model-value="formStore.form.clientMiddleName"
                          :label="
                            isInlineContactMedelementContext
                              ? requiredContactLabel(
                                  $t(
                                    'SCHEDULING.APPOINTMENT_FORM.CLIENT_MIDDLE_NAME'
                                  )
                                )
                              : $t(
                                  'SCHEDULING.APPOINTMENT_FORM.CLIENT_MIDDLE_NAME'
                                )
                          "
                          :message="inlineContactMiddleNameMessage"
                          :message-type="
                            inlineContactMiddleNameMessage ? 'error' : 'info'
                          "
                          @update:model-value="
                            formStore.updateField('clientMiddleName', $event)
                          "
                        />
                      </div>
                    </div>

                    <div v-if="isContactEditorOpen" class="grid gap-4 pt-2">
                      <div class="grid gap-4 md:grid-cols-2">
                        <div>
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
                          <p
                            v-if="formStore.validationErrors.clientPhone"
                            class="mt-1 mb-0 text-xs text-n-ruby-9"
                          >
                            {{
                              validationErrorMessage(
                                formStore.validationErrors.clientPhone
                              )
                            }}
                          </p>
                        </div>
                        <Input
                          v-model="inlineContactForm.iin"
                          inputmode="numeric"
                          maxlength="12"
                          custom-input-class="tabular-nums"
                          :label="
                            isInlineContactMedelementContext
                              ? `${$t('SCHEDULING.CONTACT.IIN')} *`
                              : $t('SCHEDULING.CONTACT.IIN')
                          "
                          :message="inlineContactIinMessage"
                          :message-type="
                            inlineContactIinMessage ? 'error' : 'info'
                          "
                        />
                      </div>
                      <div class="grid gap-4 md:grid-cols-2">
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
                          variant="faded"
                          color="slate"
                          :disabled="isInlineContactSaveDisabled"
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
                    <Input
                      class="md:col-span-2"
                      :model-value="formStore.form.title"
                      :label="$t('SCHEDULING.APPOINTMENT_FORM.TITLE')"
                      :placeholder="
                        $t('SCHEDULING.APPOINTMENT_FORM.TITLE_PLACEHOLDER')
                      "
                      @update:model-value="
                        formStore.updateField('title', $event)
                      "
                    />
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
                    <SchedulingSelectField
                      v-if="isSelectedFormResourceMedelement"
                      class="appointment-drawer-select-control"
                      :model-value="formStore.form.medelementCabinetCode"
                      :options="medelementCabinetOptions"
                      :label="$t('SCHEDULING.MEDELEMENT.CABINET')"
                      :placeholder="$t('SCHEDULING.MEDELEMENT.CABINET')"
                      :message="
                        isMedelementCabinetMissing
                          ? $t('SCHEDULING.MEDELEMENT.CABINET_REQUIRED')
                          : ''
                      "
                      :has-error="isMedelementCabinetMissing"
                      @update:model-value="
                        formStore.updateField('medelementCabinetCode', $event)
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
                        v-else-if="!isSelectedFormResourceMedelement"
                        :model-value="formStore.form.serviceNameSnapshot"
                        :placeholder="$t('SCHEDULING.APPOINTMENT_FORM.SERVICE')"
                        @update:model-value="
                          value => {
                            formStore.updateField('serviceIds', []);
                            formStore.updateField('serviceNameSnapshot', value);
                          }
                        "
                      />
                      <p v-else class="mt-1 mb-0 text-xs text-n-slate-10">
                        {{ $t('SCHEDULING.MEDELEMENT.NO_SPECIALIST_SERVICES') }}
                      </p>
                      <p
                        v-if="formStore.validationErrors.serviceIds"
                        class="mt-1 mb-0 text-xs text-n-ruby-9"
                      >
                        {{
                          validationErrorMessage(
                            formStore.validationErrors.serviceIds
                          )
                        }}
                      </p>
                    </div>
                    <div
                      class="appointment-money-grid grid gap-4 md:col-span-2 md:grid-cols-[minmax(0,0.85fr)_minmax(0,1.35fr)_minmax(0,0.8fr)]"
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
                        type="datetime"
                        :model-value="formStore.form.startsAt"
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
                        @update:model-value="
                          formStore.updateField('startsAt', $event)
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
                      v-if="canCreateMedelementReception"
                      size="sm"
                      variant="faded"
                      :disabled="
                        isMedelementCabinetMissing ||
                        isMedelementContactMissing ||
                        !!formStore.validationErrors.clientPhone ||
                        providerCommandsStore.ui.isExecuting
                      "
                      :is-loading="providerCommandsStore.ui.isExecuting"
                      :label="$t('SCHEDULING.MEDELEMENT.CREATE_ACTION')"
                      @click="
                        stageCreateMedelementReception(
                          formStore.selectedAppointment
                        )
                      "
                    />
                    <Button
                      size="sm"
                      variant="faded"
                      color="ruby"
                      :is-loading="
                        formStore.ui.isSaving ||
                        providerCommandsStore.ui.isExecuting
                      "
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
                      v-if="
                        !isSelectedAppointmentProviderOwned &&
                        formStore.form.status === 'cancelled'
                      "
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
            :contacts="appointmentConversationContacts"
            :contactable-inboxes="
              appointmentConversationDraft.contactableInboxes
            "
            :selected-contact-id="appointmentConversationDraft.contactId"
            :can-manage="canManageAppointmentConversation"
            :is-creating-conversation="appointmentConversationDraft.isCreating"
            :is-loading-inboxes="appointmentConversationDraft.isLoadingInboxes"
            load-error-i18n-key="SCHEDULING.CONVERSATION_PLACEHOLDER.LOAD_ERROR"
            placeholder-i18n-prefix="SCHEDULING.CONVERSATION_PLACEHOLDER"
            :visible="
              formStore.isOpen && shouldShowAppointmentConversationPanel
            "
            @add-contact="handleAppointmentConversationAddContact"
            @close="showAppointmentConversationPanel = false"
            @create-conversation="createAppointmentConversation"
            @select-contact="loadAppointmentConversationContext"
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

        <label
          class="flex cursor-pointer items-center gap-2 text-sm text-n-slate-12"
        >
          <Checkbox v-model="appointmentFilterDraft.showInactiveAppointments" />
          <span>{{ $t('SCHEDULING.TOOLBAR.SHOW_INACTIVE_APPOINTMENTS') }}</span>
        </label>

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
      ref="providerCommandDialogRef"
      width="md"
      type="alert"
      :title="providerCommandTitle"
      :description="providerCommandDescription"
      :confirm-button-label="providerCommandConfirmLabel"
      :disable-confirm-button="disableProviderCommandConfirm"
      :is-loading="providerCommandsStore.ui.isExecuting"
      :show-confirm-button="showProviderCommandConfirm"
      @close="handleProviderCommandDialogClose"
      @confirm="handleProviderCommandConfirm"
    >
      <div
        v-if="
          pendingProviderAction?.command?.status ===
          'awaiting_patient_selection'
        "
        class="flex flex-col gap-2"
      >
        <button
          v-for="candidate in patientCandidates"
          :key="candidate.token"
          type="button"
          class="flex flex-col items-start gap-1 p-3 text-start border rounded-lg"
          :class="
            selectedPatientToken === candidate.token
              ? 'border-n-brand bg-n-brand/10'
              : 'border-n-weak hover:border-n-strong'
          "
          @click="selectedPatientToken = candidate.token"
        >
          <span class="text-sm font-medium text-n-slate-12">
            {{
              [candidate.name, candidate.middlename].filter(Boolean).join(' ')
            }}
          </span>
          <span class="text-xs text-n-slate-11">
            {{
              [candidate.birthday, candidate.iinMasked, candidate.phoneMasked]
                .filter(Boolean)
                .join(' · ')
            }}
          </span>
        </button>
      </div>
      <Button
        v-if="showProviderCommandCancel"
        type="button"
        color="slate"
        variant="faded"
        :disabled="providerCommandsStore.ui.isExecuting"
        :label="$t('SCHEDULING.MEDELEMENT.CANCEL_COMMAND')"
        @click="handleProviderCommandCancel"
      />
    </Dialog>

    <Dialog
      ref="appointmentDeleteDialogRef"
      width="md"
      type="alert"
      :title="$t('SCHEDULING.APPOINTMENT_FORM.DELETE_TITLE')"
      :description="
        $t('SCHEDULING.APPOINTMENT_FORM.DELETE_DESCRIPTION', {
          name: appointmentClientName() || '',
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
  @apply flex items-start gap-3 rounded-lg px-1 py-1;
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

.appointment-drawer-form :deep(.grid) {
  @apply items-start;
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
