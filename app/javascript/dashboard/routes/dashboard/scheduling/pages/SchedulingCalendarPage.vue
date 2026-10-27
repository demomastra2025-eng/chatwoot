<script setup>
import {
  computed,
  onBeforeUnmount,
  onMounted,
  reactive,
  readonly,
  ref,
  watch,
} from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';

import { useAccount } from 'dashboard/composables/useAccount';
import { useAlert } from 'dashboard/composables';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { useMapGetter } from 'dashboard/composables/store';
import SchedulingAppointmentsAPI from 'dashboard/api/scheduling/appointments';
import Button from 'dashboard/components-next/button/Button.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import TagMultiSelectComboBox from 'dashboard/components-next/combobox/TagMultiSelectComboBox.vue';
import CrmDealConversationPanel from 'dashboard/components-next/CRM/CrmDealConversationPanel.vue';
import CrmCustomFieldsSection from 'dashboard/components-next/CRM/CrmCustomFieldsSection.vue';
import AppointmentDealSelector from 'dashboard/components-next/CRM/AppointmentDealSelector.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import PhoneNumberInput from 'dashboard/components-next/phonenumberinput/PhoneNumberInput.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import SchedulingCalendarGrid from 'dashboard/components-next/Scheduling/SchedulingCalendarGrid.vue';
import SchedulingContactPhoneEditor from 'dashboard/components-next/Scheduling/SchedulingContactPhoneEditor.vue';
import SchedulingCustomFieldAdvancedFilter from 'dashboard/components-next/Scheduling/SchedulingCustomFieldAdvancedFilter.vue';
import SchedulingDateTimeField from 'dashboard/components-next/Scheduling/SchedulingDateTimeField.vue';
import SchedulingAppointmentTimeFields from 'dashboard/components-next/Scheduling/SchedulingAppointmentTimeFields.vue';
import SchedulingErrorState from 'dashboard/components-next/Scheduling/SchedulingErrorState.vue';
import SchedulingFormFieldGroup from 'dashboard/components-next/Scheduling/SchedulingFormFieldGroup.vue';
import SchedulingMoneyInput from 'dashboard/components-next/Scheduling/SchedulingMoneyInput.vue';
import SchedulingMultiSelectFilter from 'dashboard/components-next/Scheduling/SchedulingMultiSelectFilter.vue';
import SchedulingResourceFilter from 'dashboard/components-next/Scheduling/SchedulingResourceFilter.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import SchedulingToolbar from 'dashboard/components-next/Scheduling/SchedulingToolbar.vue';
import SchedulingViewSwitcher from 'dashboard/components-next/Scheduling/SchedulingViewSwitcher.vue';
import {
  appointmentCrmLinkWarningMessage,
  appointmentProviderMoveMessage,
  appointmentSaveAlertMessage,
} from 'dashboard/components-next/Scheduling/appointmentSaveMessage';

import {
  APPOINTMENT_STATUS_ICONS,
  APPOINTMENT_STATUS_ICON_CLASSES,
  APPOINTMENT_STATUS_VALUES,
  DEFAULT_WORKSPACE_TIMEZONE,
} from '../constants';
import {
  formatSchedulingErrorMessage,
  isDeletedFromScheduling,
  normalizePayload,
} from 'dashboard/stores/scheduling/shared';
import {
  appointmentCancellationAlertMessage,
  appointmentPatientDialogRoute,
  buildMedelementProviderCommandDetails,
  hasMedelementReceptionIdentity,
  buildMedelementProviderCommandParams,
  calendarDayAnchor,
  calendarTodayAnchor,
  dateTimeInputDurationMinutes,
  canCreateAppointmentConversation,
  formatCalendarTitle,
  formatMedelementMissingFields,
  formatSchedulingDateTime,
  fromDateTimeInputValue,
  isAppointmentProviderOwned,
  toDateTimeInputValue,
  isMedelementCancellationLocalOnly,
  isMedelementLocalCancellation,
  isMedelementResource,
  medelementCommandFailureMessage,
  medelementCabinetsForResource,
  medelementReceptionCode,
  medelementSyncStatusKey,
  medelementSyncStatusMessage,
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
import {
  appointmentFormMutationContext,
  isKazakhstanE164Phone,
  refreshCurrentCalendarProviderAction,
  runCurrentCalendarProviderAction,
  useSchedulingAppointmentFormStore,
} from 'dashboard/stores/scheduling/appointmentForm';
import { useSchedulingCalendarStore } from 'dashboard/stores/scheduling/calendar';
import {
  buildProviderCommandAction,
  providerCommandRequiresPatientSelection,
  useSchedulingProviderCommandsStore,
} from 'dashboard/stores/scheduling/providerCommands';
import { useSchedulingReferencesStore } from 'dashboard/stores/scheduling/references';
import { parseIinMetadata } from 'dashboard/stores/scheduling/iin';
import {
  buildContactableInboxesList,
  fetchContactableInboxes,
} from 'dashboard/components-next/NewConversation/helpers/composeConversationHelper.js';

const { t, locale } = useI18n();
const calendarStore = useSchedulingCalendarStore();
const crmReferencesStore = useCrmReferencesStore();
const referencesStore = useSchedulingReferencesStore();
const formStore = useSchedulingAppointmentFormStore();
const appointmentFormControlValues = computed(() => readonly(formStore.form));
const providerCommandsStore = useSchedulingProviderCommandsStore();
const { currentAccount } = useAccount();
const route = useRoute();
const router = useRouter();
const { updateUISettings } = useUISettings();
const currentUser = useMapGetter('getCurrentUser');
let calendarDisposed = false;
let providerActionGeneration = 0;
let activeProviderAction = null;
const calendarPatientContext = () =>
  JSON.stringify([
    route.params.accountId,
    currentUser.value?.id,
    appointmentFormMutationContext(formStore),
  ]);
const isCurrentProviderAction = action =>
  !calendarDisposed &&
  action?.generation === providerActionGeneration &&
  action.patientContext === calendarPatientContext();
const captureCalendarFormMutation = () => {
  const context = calendarPatientContext();
  const formContext = appointmentFormMutationContext(formStore);
  return () =>
    !calendarDisposed &&
    context === calendarPatientContext() &&
    formContext === appointmentFormMutationContext(formStore);
};
// There is no account-level workspace timezone setting on this base yet, so
// the calendar is rendered in the default company timezone. A future account
// setting only has to replace this computed value.
const workspaceTimezone = computed(() => DEFAULT_WORKSPACE_TIMEZONE);
const currentPresentation = ref('calendar');
const contactEditorMode = ref(null);
const contactSelectorFieldRef = ref(null);
const inlineContactDraftInitialized = ref(false);
const customFieldFilters = ref({});
const filterDialogRef = ref(null);
const appointmentFilterDraft = reactive({
  customFieldFilters: {},
  hideCancelledAppointments: false,
  statusFilters: [],
});
const pendingCreateCustomFieldDefaultsHydration = ref(false);
const appointmentDeleteDialogRef = ref(null);
const appointmentLocalCancelDialogRef = ref(null);
const providerCommandDialogRef = ref(null);
const pendingProviderAction = ref(null);
const patientCandidates = ref([]);
const selectedPatientToken = ref('');
const showAppointmentConversationPanel = ref(false);
const isAppointmentPage = computed(() => Boolean(route.params?.appointmentId));
const appointmentPageTab = ref('appointment');
const isAppointmentLoading = ref(false);
const appointmentPageError = ref(null);
const isCalendarLoaded = ref(false);
let appointmentOpenGeneration = 0;
const appointmentConversationDraft = reactive({
  contactId: '',
  contactableInboxes: [],
  contextRequestId: 0,
  isCreating: false,
  isLoadingInboxes: false,
});
const appointmentContactableInboxesByContactId = ref({});
const phoneEditorError = ref('');
const isPhoneSaving = ref(false);
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
  'appointmentId',
  'contactId',
  'contactFirstName',
  'contactLastName',
  'contactMiddleName',
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
    icon: value === 'calendar' ? 'i-lucide-calendar-days' : 'i-lucide-list',
    label: presentationLabels.value[value],
    value,
  }))
);

const pageTitle = computed(() =>
  formatCalendarTitle(
    calendarStore.currentView,
    calendarStore.anchorDate,
    locale.value,
    workspaceTimezone.value
  )
);

const isSelectedAppointmentProviderOwned = computed(
  () =>
    formStore.mode === 'edit' &&
    isAppointmentProviderOwned(formStore.selectedAppointment)
);
const isSelectedAppointmentInMedelement = computed(
  () =>
    formStore.mode === 'edit' &&
    (isSelectedAppointmentProviderOwned.value ||
      hasMedelementReceptionIdentity(formStore.selectedAppointment))
);
// MedElement-linked and the integration keeps receptions on cancel: the cancel stays in OneLink.
const isSelectedAppointmentCancelLocalOnly = computed(
  () =>
    formStore.mode === 'edit' &&
    isMedelementCancellationLocalOnly(formStore.selectedAppointment)
);
const isSelectedAppointmentLocallyCancelled = computed(
  () =>
    formStore.mode === 'edit' &&
    isMedelementLocalCancellation(formStore.selectedAppointment)
);

const filterableResources = computed(() =>
  referencesStore.resources.filter(
    resource => resource.active && !isDeletedFromScheduling(resource)
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
const selectedAppointmentMedelementReceptionCode = computed(() => {
  if (formStore.mode !== 'edit' || !formStore.selectedAppointment) return '';

  return medelementReceptionCode(formStore.selectedAppointment);
});
const selectedAppointmentMedelementStatus = computed(() => {
  if (formStore.mode !== 'edit' || !formStore.selectedAppointment) {
    return null;
  }

  const key = medelementSyncStatusKey(formStore.selectedAppointment, {
    isMedelementResource: isSelectedFormResourceMedelement.value,
  });
  if (!key) return null;

  const label = medelementSyncStatusMessage(formStore.selectedAppointment, t, {
    isMedelementResource: isSelectedFormResourceMedelement.value,
  });
  let state = 'not_synced';
  if (key === 'SCHEDULING.MEDELEMENT.SYNC_STATUS.SYNCED') {
    state = 'synced';
  } else if (
    [
      'SCHEDULING.MEDELEMENT.SYNC_STATUS.PENDING',
      'SCHEDULING.APPOINTMENT_STATUS.MOVE_PENDING',
      'SCHEDULING.APPOINTMENT_STATUS.CANCELLATION_PENDING',
    ].includes(key)
  ) {
    state = 'pending';
  } else if (key === 'SCHEDULING.APPOINTMENT_STATUS.MEDELEMENT_NOT_CANCELLED') {
    state = 'warning';
  } else if (
    [
      'SCHEDULING.APPOINTMENT_STATUS.PROVIDER_REVIEW',
      'SCHEDULING.APPOINTMENT_STATUS.CANCELLATION_REVIEW',
      'SCHEDULING.APPOINTMENT_STATUS.MOVE_REVIEW',
      'SCHEDULING.APPOINTMENT_STATUS.MOVE_REJECTED',
    ].includes(key)
  ) {
    state = 'error';
  }

  return { key, label, state };
});
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
    !hasMedelementReceptionIdentity(formStore.selectedAppointment) &&
    isSelectedFormResourceMedelement.value &&
    ['scheduled', 'confirmed'].includes(formStore.form.status)
);
const patientActionStatuses = new Set([
  'awaiting_patient_creation',
  'awaiting_patient_selection',
  'awaiting_phone_refresh',
]);
const hasPatientAction = command =>
  patientActionStatuses.has(command?.status) ||
  providerCommandRequiresPatientSelection(command);

const providerCommandTitle = computed(() => {
  const status = pendingProviderAction.value?.command?.status;
  if (
    providerCommandRequiresPatientSelection(
      pendingProviderAction.value?.command
    )
  ) {
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
// On the clinic clock, the same time the grid and the drawer show.
const formatProviderCommandDateTime = value =>
  formatSchedulingDateTime(value, locale.value, workspaceTimezone.value);
const formatProviderCommandRange = (startsAt, endsAt) => {
  const start = formatProviderCommandDateTime(startsAt);
  const end = formatProviderCommandDateTime(endsAt);
  return endsAt ? `${start} — ${end}` : start;
};
const providerCommandDescription = computed(() => {
  const action = pendingProviderAction.value || {};
  const command = action.command;
  if (providerCommandRequiresPatientSelection(command)) {
    if (command.patientAction?.requiresPatientCardConfirmation) {
      return t('SCHEDULING.PATIENT_CONTEXT.CONFIRM_PATIENT_CARD');
    }
    return t('SCHEDULING.MEDELEMENT.PATIENT_SELECTION_DESCRIPTION', {
      count:
        command.patientAction?.candidateCount || patientCandidates.value.length,
    });
  }
  if (command?.status === 'awaiting_patient_creation') {
    const missing = command.patientAction?.missingFields || [];
    return missing.length
      ? t('SCHEDULING.MEDELEMENT.PATIENT_CREATION_INCOMPLETE', {
          fields: formatMedelementMissingFields(missing, t),
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
  if (
    providerCommandRequiresPatientSelection(
      pendingProviderAction.value?.command
    )
  ) {
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
  hasPatientAction(pendingProviderAction.value?.command)
);
const disableProviderCommandConfirm = computed(() => {
  if (providerCommandsStore.ui.isExecuting) return true;

  if (pendingProviderAction.value?.intentMismatch) return true;

  const command = pendingProviderAction.value?.command;
  if (providerCommandRequiresPatientSelection(command)) {
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
      action.command.patientAction?.cancellable !== false &&
      (action.intentMismatch || hasPatientAction(action.command))
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
    wrapLabel: true,
  }))
);
const hasServiceOptions = computed(() => serviceOptions.value.length > 0);

const companySelectionEnabled = computed(
  () => currentAccount.value?.settings?.scheduling_company_enabled !== false
);

const contactSelectionRequired = computed(
  () => currentAccount.value?.settings?.scheduling_contact_required !== false
);

const contactOptions = computed(() => {
  if (formStore.form.patientContactId) {
    return [
      {
        value: formStore.form.patientContactId,
        label: formStore.selectedContact?.fullName || appointmentClientName(),
      },
    ];
  }
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

  const fallbackLabel = [
    formStore.selectedContact?.fullName || appointmentClientName(),
    formStore.selectedContact?.phone || formStore.form.clientPhone,
  ]
    .filter(Boolean)
    .join(' ');

  const list =
    hasSelectedOption || !fallbackLabel
      ? options
      : [
          {
            label: fallbackLabel,
            value: formStore.form.contactId,
          },
          ...options,
        ];

  return [
    ...list,
    {
      value: '__create_new_contact__',
      label: t('SCHEDULING.CONTACT.NEW_ACTION'),
      icon: 'i-lucide-plus',
      iconClass: 'text-n-brand',
      labelClass: 'font-medium text-n-brand',
    },
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

const genderOptions = computed(() => [
  { label: t('SCHEDULING.CONTACT.GENDER.MALE'), value: 'male' },
  { label: t('SCHEDULING.CONTACT.GENDER.FEMALE'), value: 'female' },
  { label: t('SCHEDULING.CONTACT.GENDER.OTHER'), value: 'other' },
  { label: t('SCHEDULING.CONTACT.GENDER.UNKNOWN'), value: 'unknown' },
]);

const hasSelectedResources = computed(
  () => calendarStore.selectedResourceIds.length > 0
);
const isContactEditorOpen = computed(() => Boolean(contactEditorMode.value));
const canEditInlineContact = computed(
  () =>
    Boolean(formStore.form.contactId || formStore.form.patientContactId) &&
    Boolean(
      formStore.selectedContact ||
        formStore.form.patientContactId ||
        !formStore.isProviderPatientIdentity
    )
);
const isEditingContact = computed(
  () =>
    contactEditorMode.value === 'edit' ||
    Boolean(formStore.form.contactId || formStore.form.patientContactId)
);
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
const unifiedAppointmentFieldDefinitions = computed(() => {
  const definitions = [
    ...intakeAppointmentFieldDefinitions.value,
    ...generalAppointmentFieldDefinitions.value,
  ];
  if (selectedAppointmentMedelementReceptionCode.value) {
    definitions.push({
      id: 'medelement_reception_code',
      active: true,
      key: 'medelement_reception_code',
      label: t('SCHEDULING.MEDELEMENT.RECEPTION_CODE_FIELD_LABEL'),
      fieldType: 'text',
      readOnly: true,
    });
  }
  return definitions;
});
const appointmentCustomFieldsModelValue = computed(() => {
  const baseAttributes = appointmentFormControlValues.value.customAttributes;
  if (!selectedAppointmentMedelementReceptionCode.value) {
    return baseAttributes;
  }

  return readonly({
    ...baseAttributes,
    medelement_reception_code: selectedAppointmentMedelementReceptionCode.value,
  });
});
const handleAppointmentCustomFieldsUpdate = nextValue => {
  if (!nextValue || typeof nextValue !== 'object') {
    formStore.updateField('customAttributes', {});
    return;
  }

  const {
    medelement_reception_code: _ignoredReceptionCode,
    ...editableValues
  } = nextValue;
  formStore.updateField('customAttributes', editableValues);
};
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
  calendarStore.setWorkspaceTimezone(workspaceTimezone.value);
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

const appointmentDealSelection = computed({
  get: () => formStore.form.crmDealSelection || {},
  set: value => formStore.updateField('crmDealSelection', value),
});

const appointmentStartsAt = computed({
  get: () => formStore.form.startsAt,
  set: value => formStore.updateField('startsAt', value),
});
const appointmentEndsAt = computed({
  get: () => formStore.form.endsAt,
  set: value => formStore.updateField('endsAt', value),
});
const appointmentDurationMin = computed({
  get: () =>
    formStore.form.durationMin !== ''
      ? formStore.form.durationMin
      : dateTimeInputDurationMinutes(
          formStore.form.startsAt,
          formStore.form.endsAt,
          DEFAULT_WORKSPACE_TIMEZONE
        ) || 30,
  set: value => formStore.updateField('durationMin', value),
});

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
const patientDialogRoute = computed(() =>
  appointmentPatientDialogRoute(
    formStore.selectedAppointment,
    route.params.accountId
  )
);
const openPatientDialog = () => {
  if (!patientDialogRoute.value) return;
  updateUISettings({
    is_contact_sidebar_open: false,
    is_crm_deal_panel_open: false,
    is_scheduling_appointments_panel_open: true,
  });
  router.push(patientDialogRoute.value);
};
const canManageAppointmentConversation = computed(
  () =>
    formStore.mode === 'edit' &&
    canCreateAppointmentConversation(formStore.selectedAppointment)
);
const shouldShowAppointmentConversationPanel = computed(
  () =>
    isAppointmentPage.value ||
    (canOpenAppointmentConversation.value &&
      showAppointmentConversationPanel.value)
);

const appointmentDrawerModalClass = computed(() => {
  if (isAppointmentPage.value) {
    return 'flex h-full w-full min-h-0 min-w-0 flex-col overflow-hidden bg-n-solid-2 lg:flex-row';
  }

  return [
    'mx-auto flex h-full w-full overflow-hidden rounded-2xl border border-n-weak bg-n-solid-2 shadow-2xl',
    shouldShowAppointmentConversationPanel.value
      ? 'max-w-[min(96rem,calc(100vw-1.5rem))] flex-col md:flex-row'
      : 'max-w-[min(30rem,calc(100vw-1.5rem))] flex-col',
  ];
});

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
const inlineContactPhoneMessage = computed(() => {
  if (
    isInlineContactMedelementContext.value &&
    !isKazakhstanE164Phone(formStore.form.clientPhone)
  ) {
    return t('SCHEDULING.APPOINTMENT_FORM.ERRORS.MEDELEMENT_PHONE_REQUIRED');
  }

  return validationErrorMessage(formStore.validationErrors.clientPhone);
});
const needsProviderPatientPhoneInput = computed(
  () =>
    formStore.isProviderPatientIdentity &&
    !isSelectedAppointmentProviderOwned.value &&
    !isKazakhstanE164Phone(formStore.selectedContact?.phone)
);
const isInlineContactSaveDisabled = computed(
  () =>
    formStore.ui.isSaving ||
    !String(formStore.form.clientFirstName || '').trim() ||
    Boolean(inlineContactLastNameMessage.value) ||
    Boolean(inlineContactPhoneMessage.value) ||
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
  appointmentFilterDraft.hideCancelledAppointments = Boolean(
    calendarStore.hideCancelledAppointments
  );
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
  calendarStore.setHideCancelledAppointments?.(
    appointmentFilterDraft.hideCancelledAppointments
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
  if (!isAppointmentPage.value && !numericQueryValue('appointmentId')) {
    await fetchCalendar();
    isCalendarLoaded.value = true;
  }
};

const resetAppointmentConversationDraft = () => {
  appointmentConversationDraft.contextRequestId += 1;
  const contactId = Number(formStore.form.contactId);
  appointmentConversationDraft.contactId =
    Number.isFinite(contactId) && contactId > 0 ? contactId : '';
  appointmentConversationDraft.contactableInboxes =
    (!hasAppointmentConversationTarget.value &&
      appointmentConversationDraft.contactId &&
      appointmentContactableInboxesByContactId.value[
        appointmentConversationDraft.contactId
      ]) ||
    [];
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

  calendarStore.setAnchorDate(
    calendarDayAnchor(nextDate, workspaceTimezone.value).toISOString()
  );
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

  const contactId = numericQueryValue('contactId');

  openNewAppointment({
    contactId,
    conversationId: numericQueryValue('conversationId'),
  });

  try {
    if (contactId) {
      await formStore.loadContact(contactId);
      contactEditorMode.value = 'edit';
    }
  } catch (error) {
    useAlert(formatErrorMessage(error));
  } finally {
    await clearAppointmentPrefillQuery();
  }
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

const returnToCalendar = () => {
  const calendarPath = `/app/accounts/${route.params.accountId}/scheduling/calendar`;
  if (window.history.state?.back?.split('?')[0] === calendarPath) {
    router.back();
    return;
  }

  const nextQuery = { ...route.query };
  delete nextQuery.appointmentId;
  router.push({
    name: 'scheduling_calendar',
    params: { accountId: route.params.accountId },
    query: nextQuery,
  });
};

const closeAppointmentEditor = () => {
  if (isAppointmentPage.value) {
    handleDrawerClose();
    returnToCalendar();
    return;
  }

  handleDrawerClose();
};

const closeAppointmentConversationPanel = () => {
  if (isAppointmentPage.value) {
    closeAppointmentEditor();
    return;
  }

  showAppointmentConversationPanel.value = false;
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
  if (formStore.ui.isSaving) return;
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
  if (formStore.ui.isSaving || !canManageAppointmentConversation.value) return;

  appointmentConversationContactCreateRequested.value = true;
  if (isAppointmentPage.value) {
    appointmentPageTab.value = 'appointment';
  } else {
    showAppointmentConversationPanel.value = false;
  }
  openInlineContactCreate();
};

const inlineContactEditPayload = () => ({
  ...inlineContactForm,
  firstName: formStore.form.clientFirstName,
  fullName: appointmentClientName(),
  lastName: formStore.form.clientLastName,
  middleName: formStore.form.clientMiddleName,
  phone: formStore.form.clientPhone,
  resourceId: formStore.form.resourceId,
});

function openInlineContactEdit() {
  if (formStore.ui.isSaving) return;
  if (!canEditInlineContact.value) {
    contactEditorMode.value = null;
    formStore.inlineContactSnapshot = null;
    return;
  }

  contactEditorMode.value = 'edit';
  fillInlineContactForm(
    formStore.selectedContact || {
      ...formStore.form,
      id: formStore.form.patientContactId || formStore.form.contactId,
    }
  );
  formStore.beginInlineContactEdit(inlineContactEditPayload());
}

const cancelInlineContactEdit = () => {
  if (formStore.ui.isSaving) return;
  contactEditorMode.value = null;
  formStore.inlineContactSnapshot = null;
};

const syncCalendarContextToAppointment = appointment => {
  if (!appointment) return;

  const startsAt = new Date(appointment.startsAt);
  const endsAt = new Date(appointment.endsAt || appointment.startsAt);
  const currentRange = calendarStore.currentRange;
  const inCurrentRange =
    !Number.isNaN(startsAt.getTime()) &&
    !Number.isNaN(endsAt.getTime()) &&
    currentRange?.from &&
    currentRange?.to &&
    startsAt < currentRange.to &&
    endsAt > currentRange.from;

  let calendarContextChanged = false;
  if (
    !Number.isNaN(startsAt.getTime()) &&
    (!isCalendarLoaded.value || !inCurrentRange)
  ) {
    calendarStore.setAnchorDate(
      calendarDayAnchor(
        appointment.startsAt,
        workspaceTimezone.value
      ).toISOString()
    );
    calendarContextChanged = true;
  }

  const resourceId = Number(appointment.resourceId);
  if (
    Number.isFinite(resourceId) &&
    resourceId > 0 &&
    calendarStore.selectedResourceIds.length &&
    !calendarStore.selectedResourceIds.includes(resourceId) &&
    filterableResources.value.some(
      resource => Number(resource.id) === resourceId
    )
  ) {
    calendarStore.setSelectedResources([
      ...calendarStore.selectedResourceIds,
      resourceId,
    ]);
    calendarContextChanged = true;
  }

  if (calendarContextChanged) {
    isCalendarLoaded.value = false;
    calendarStore.syncAppointment(appointment);
  }
};

const openEditAppointment = appointment => {
  const wasAlreadyOpen = formStore.isOpen;
  formStore.openEdit(appointment);
  appointmentPageTab.value = 'appointment';
  resetAppointmentConversationDraft();
  appointmentConversationContactCreateRequested.value = false;
  showAppointmentConversationPanel.value = true;
  contactEditorMode.value = null;
  formStore.inlineContactSnapshot = null;
  if (
    wasAlreadyOpen &&
    !hasAppointmentConversationTarget.value &&
    formStore.form.contactId &&
    !appointmentConversationDraft.contactableInboxes.length
  ) {
    loadAppointmentConversationContext(formStore.form.contactId);
  }
};

const openAppointmentPage = appointment => {
  if (!appointment?.id) return;

  router.push({
    name: 'scheduling_appointment_show',
    params: {
      accountId: route.params.accountId,
      appointmentId: appointment.id,
    },
    query: route.query,
  });
};

const handleSelectAppointment = appointment => {
  openEditAppointment(appointment);
  openAppointmentPage(appointment);
};

const consumeAppointmentOpenQuery = async () => {
  const appointmentId = numericQueryValue('appointmentId');
  if (!appointmentId) return false;

  const nextQuery = { ...route.query };
  delete nextQuery.appointmentId;
  await router.replace({
    name: 'scheduling_appointment_show',
    params: {
      accountId: route.params.accountId,
      appointmentId,
    },
    query: nextQuery,
  });

  return true;
};

const openAppointmentFromRoute = async () => {
  appointmentOpenGeneration += 1;
  const generation = appointmentOpenGeneration;
  const appointmentId = Number(route.params?.appointmentId);
  if (!Number.isSafeInteger(appointmentId) || appointmentId <= 0) {
    isAppointmentLoading.value = false;
    appointmentPageError.value = t('SCHEDULING.ERRORS.APPOINTMENT_NOT_FOUND');
    return;
  }

  appointmentPageError.value = null;
  if (
    formStore.isOpen &&
    formStore.mode === 'edit' &&
    Number(formStore.recordId) === appointmentId &&
    formStore.selectedAppointment
  ) {
    syncCalendarContextToAppointment(formStore.selectedAppointment);
    isAppointmentLoading.value = false;
    return;
  }

  isAppointmentLoading.value = true;
  try {
    let appointment = isCalendarLoaded.value
      ? calendarStore.appointments.find(
          record => Number(record.id) === appointmentId
        )
      : null;
    if (!appointment) {
      const { data } = await SchedulingAppointmentsAPI.show(appointmentId);
      if (calendarDisposed || generation !== appointmentOpenGeneration) return;
      appointment = normalizePayload(data);
    }
    if (calendarDisposed || generation !== appointmentOpenGeneration) return;
    syncCalendarContextToAppointment(appointment);
    openEditAppointment(appointment);
  } catch (error) {
    if (!calendarDisposed && generation === appointmentOpenGeneration) {
      handleDrawerClose();
      appointmentPageError.value = formatErrorMessage(error);
    }
  } finally {
    if (generation === appointmentOpenGeneration) {
      isAppointmentLoading.value = false;
    }
  }
};

const handleInlineContactSave = async () => {
  if (formStore.ui.isSaving) return;
  if (isInlineContactSaveDisabled.value) {
    useAlert(inlineContactIinMessage.value);
    return;
  }

  const contactPayload = inlineContactEditPayload();
  const context = calendarPatientContext();
  const ownerId = formStore.form.contactId;
  const patientId = formStore.form.patientContactId;
  const isCurrent = () => context === calendarPatientContext();

  try {
    if (isEditingContact.value) {
      const updated = await formStore.updateInlineContact(
        patientId || ownerId,
        contactPayload,
        isCurrent
      );
      if (!isCurrent() || !updated) return;
      useAlert(t('SCHEDULING.CONTACT.SUCCESS_UPDATE'));
      if (formStore.mode === 'edit') {
        contactEditorMode.value = null;
        formStore.inlineContactSnapshot = null;
      } else {
        openInlineContactEdit();
      }
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
    if (isCurrent()) useAlert(formatErrorMessage(error));
  }
};

const saveContactPhone = async phone => {
  const contactId = formStore.form.patientContactId || formStore.form.contactId;
  if (!contactId || isPhoneSaving.value) return;

  phoneEditorError.value = '';
  isPhoneSaving.value = true;
  try {
    const updated = await formStore.updateInlineContact(contactId, { phone });
    if (!updated) return;

    const cached = { ...appointmentContactableInboxesByContactId.value };
    delete cached[contactId];
    appointmentContactableInboxesByContactId.value = cached;
    if (Number(appointmentConversationDraft.contactId) === Number(contactId)) {
      await loadAppointmentConversationInboxes(
        appointmentConversationDraft.contextRequestId
      );
    }
    useAlert(t('SCHEDULING.CONTACT.PHONE_SAVED'));
  } catch (error) {
    if (
      Number(formStore.form.patientContactId || formStore.form.contactId) ===
      Number(contactId)
    ) {
      phoneEditorError.value = formatErrorMessage(error);
    }
  } finally {
    isPhoneSaving.value = false;
  }
};

watch(
  () => [
    formStore.mode,
    formStore.recordId,
    formStore.form.patientContactId,
    formStore.form.contactId,
  ],
  ([mode]) => {
    phoneEditorError.value = '';
    if (mode === 'edit') {
      contactEditorMode.value = null;
      formStore.inlineContactSnapshot = null;
    }
  }
);

watch(
  appointmentFieldDefinitions,
  definitions => {
    if (
      !formStore.isOpen ||
      formStore.ui.isSaving ||
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
    if (formStore.ui.isSaving) return;
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

const handleContactSelect = rawContactId => {
  if (formStore.ui.isSaving || formStore.form.patientContactId) return;
  const contactId =
    rawContactId === '__create_new_contact__' ? '' : rawContactId;
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
    if (formStore.mode === 'create' && !formStore.isProviderPatientIdentity) {
      openInlineContactEdit();
    } else {
      contactEditorMode.value = null;
      formStore.inlineContactSnapshot = null;
    }
  }
};

const handleContactDropdownOpen = async () => {
  if (formStore.ui.isSaving || formStore.ui.isLoadingContacts) return;

  try {
    await formStore.searchContacts('');
  } catch {
    // Surface API errors through the existing form store error state.
  }
};

const openContactSelector = () => {
  if (!formStore.ui.isSaving) contactSelectorFieldRef.value?.open();
};
const updateInlineContactField = (field, value) => {
  if (!formStore.ui.isSaving) inlineContactForm[field] = value;
};
const searchAppointmentContacts = query => {
  if (!formStore.ui.isSaving) return formStore.searchContacts(query);
  return null;
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
  if (!isCurrentProviderAction(action)) return false;
  selectedPatientToken.value = '';
  patientCandidates.value = [];
  pendingProviderAction.value = { ...action, command };
  const pending = pendingProviderAction.value;
  activeProviderAction = pending;
  if (providerCommandRequiresPatientSelection(command)) {
    const payload = await providerCommandsStore.loadPatientCandidates(command);
    if (
      !isCurrentProviderAction(action) ||
      pendingProviderAction.value !== pending
    )
      return false;
    patientCandidates.value = payload?.candidates || [];
  }
  return (
    isCurrentProviderAction(action) && pendingProviderAction.value === pending
  );
};

const refreshAfterProviderCommand = action =>
  refreshCurrentCalendarProviderAction({
    refresh: async () => {
      await calendarStore.refresh();
      if (
        isAppointmentPage.value &&
        action.appointment?.id &&
        !calendarStore.appointments.some(
          item => Number(item.id) === Number(action.appointment?.id)
        )
      ) {
        const { data } = await SchedulingAppointmentsAPI.show(
          action.appointment.id
        );
        const fetched = normalizePayload(data);
        if (fetched) {
          syncCalendarContextToAppointment(fetched);
          calendarStore.syncAppointment(fetched);
        }
      }
    },
    isCurrent: () => isCurrentProviderAction(action),
    onCurrent: () => {
      if (action.closeDrawer) {
        closeAppointmentEditor();
        return;
      }
      if (
        formStore.mode === 'edit' &&
        Number(formStore.recordId) === Number(action.appointment?.id)
      ) {
        const refreshed = calendarStore.appointments.find(
          item => Number(item.id) === Number(action.appointment?.id)
        );
        if (refreshed) {
          if (isAppointmentPage.value) {
            syncCalendarContextToAppointment(refreshed);
            openEditAppointment(refreshed);
          } else {
            formStore.selectedAppointment = refreshed;
          }
        }
      }
    },
  });

const showProviderCommandOutcome = async (action, command) => {
  if (!isCurrentProviderAction(action)) return;
  if (hasPatientAction(command)) {
    if (await prepareProviderCommandAction(action, command))
      providerCommandDialogRef.value?.open();
    return;
  }

  pendingProviderAction.value = null;
  providerCommandDialogRef.value?.close();
  if (!(await refreshAfterProviderCommand(action))) return;

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
  if (!isCurrentProviderAction(action)) return;
  if (action.intentMismatch) {
    if (await prepareProviderCommandAction(action, action.command))
      providerCommandDialogRef.value?.open();
    return;
  }

  if (hasPatientAction(action.command)) {
    if (await prepareProviderCommandAction(action, action.command))
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
        action.requestedParams,
        () => isCurrentProviderAction(action)
      )
    : await providerCommandsStore.executeConfirmed(action.params, {
        isCurrent: () => isCurrentProviderAction(action),
      });
  if (!isCurrentProviderAction(action) || !command) return;
  await showProviderCommandOutcome(action, command);
};

const recoverConcurrentProviderCommand = async (action, error) => {
  if (!isCurrentProviderAction(action)) return true;
  const errorCode = error?.code || error?.response?.data?.code;
  if (errorCode !== 'MEDELEMENT_COMMAND_IN_PROGRESS') return false;

  const existing = await providerCommandsStore.findActive({
    appointmentId: action.appointment.id,
    provider: action.params.provider,
  });
  if (!isCurrentProviderAction(action)) return true;
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
  providerActionGeneration += 1;
  const action = {
    appointment,
    closeDrawer,
    params,
    patientContext: calendarPatientContext(),
    generation: providerActionGeneration,
  };
  activeProviderAction = action;
  // Replacing a UI action only abandons its client result; an already sent
  // command retains its server intent and is discovered through findActive.
  providerCommandsStore.ui.operationId += 1;
  providerCommandsStore.ui.isExecuting = false;
  providerCommandsStore.ui.error = null;
  try {
    const existing = await providerCommandsStore.findActive({
      appointmentId: appointment.id,
      provider: params.provider,
    });
    if (!isCurrentProviderAction(action)) return;
    const stagedAction = buildProviderCommandAction(action, existing);
    activeProviderAction = stagedAction;
    await executeProviderCommandAction(stagedAction);
  } catch (error) {
    if (!isCurrentProviderAction(action)) return;
    try {
      if (await recoverConcurrentProviderCommand(action, error)) return;
    } catch (recoveryError) {
      if (!isCurrentProviderAction(action)) return;
      useAlert(formatErrorMessage(recoveryError));
      return;
    }
    if (!isCurrentProviderAction(action)) return;
    useAlert(formatErrorMessage(error));
  }
};

watch(
  () => calendarPatientContext(),
  () => {
    if (
      activeProviderAction &&
      !isCurrentProviderAction(activeProviderAction)
    ) {
      activeProviderAction = null;
      providerCommandsStore.ui.operationId += 1;
      providerCommandsStore.ui.isExecuting = false;
      providerCommandsStore.ui.error = null;
    }
    if (
      pendingProviderAction.value &&
      !isCurrentProviderAction(pendingProviderAction.value)
    ) {
      providerCommandDialogRef.value?.close();
      pendingProviderAction.value = null;
      selectedPatientToken.value = '';
      patientCandidates.value = [];
    }
  }
);

const stageCreateMedelementReception = appointment => {
  if (formStore.ui.isSaving) return;
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
  const isCurrent = () =>
    pendingProviderAction.value === action && isCurrentProviderAction(action);
  if (!isCurrent()) return;
  if (action.intentMismatch) {
    useAlert(t('SCHEDULING.MEDELEMENT.STALE_COMMAND_DESCRIPTION'));
    return;
  }

  try {
    let command;
    if (providerCommandRequiresPatientSelection(action.command)) {
      command = await providerCommandsStore.selectPatient(
        action.command,
        selectedPatientToken.value,
        action.requestedParams,
        isCurrent
      );
    } else if (action.command?.status === 'awaiting_patient_creation') {
      command = await providerCommandsStore.confirmPatientCreation(
        action.command,
        action.requestedParams,
        isCurrent
      );
    } else if (action.command?.status === 'awaiting_phone_refresh') {
      command = await providerCommandsStore.retryPhoneMismatch(
        action.command,
        action.requestedParams,
        isCurrent
      );
    } else {
      return;
    }

    if (!isCurrent()) return;
    const bound = command.appointment;
    if (bound && Number(bound.id) === Number(action.appointment.id)) {
      calendarStore.syncAppointment(bound);
      if (Number(formStore.recordId) === Number(bound.id)) {
        formStore.selectedAppointment = bound;
        formStore.form.patientContactId = bound.patientContactId || '';
        formStore.selectedContact = null;
        action.patientContext = calendarPatientContext();
      }
      action.appointment = bound;
    }
    await showProviderCommandOutcome(action, command);
  } catch (error) {
    if (!isCurrent()) return;
    providerCommandDialogRef.value?.close();
    useAlert(formatErrorMessage(error));
  }
};

const handleProviderCommandCancel = async () => {
  const action = pendingProviderAction.value;
  const command = action?.command;
  if (!command || providerCommandsStore.ui.isExecuting) return;
  const isCurrent = () =>
    pendingProviderAction.value === action && isCurrentProviderAction(action);
  await runCurrentCalendarProviderAction({
    run: () => providerCommandsStore.cancel(command, isCurrent),
    isCurrent,
    onSuccess: () => providerCommandDialogRef.value?.close(),
    onError: error => useAlert(formatErrorMessage(error)),
    onFinally: () => {
      pendingProviderAction.value = null;
    },
  });
};

const handleProviderCommandDialogClose = () => {
  if (pendingProviderAction.value) {
    pendingProviderAction.value = null;
    activeProviderAction = null;
    providerActionGeneration += 1;
    providerCommandsStore.ui.operationId += 1;
    providerCommandsStore.ui.isExecuting = false;
    providerCommandsStore.ui.error = null;
    selectedPatientToken.value = '';
    patientCandidates.value = [];
  }
};

const selectProviderPatientCandidate = token => {
  const action = pendingProviderAction.value;
  if (
    providerCommandsStore.ui.isExecuting ||
    !isCurrentProviderAction(action) ||
    !patientCandidates.value.some(candidate => candidate.token === token)
  )
    return;
  selectedPatientToken.value = token;
};

const handleAppointmentSubmit = async () => {
  if (formStore.ui.isSaving || formStore.ui.isCreatingContact) return;

  if (!isSelectedAppointmentProviderOwned.value) {
    if (isMedelementCabinetMissing.value) {
      useAlert(t('SCHEDULING.MEDELEMENT.CABINET_REQUIRED'));
      return;
    }
    if (isMedelementContactMissing.value) {
      useAlert(t('SCHEDULING.MEDELEMENT.CONTACT_REQUIRED'));
      return;
    }
  }

  const desiredStartsAt = fromDateTimeInputValue(
    formStore.form.startsAt,
    workspaceTimezone.value
  );
  const desiredEndsAt = fromDateTimeInputValue(
    formStore.form.endsAt,
    workspaceTimezone.value
  );
  const hasProviderOwnedTimeChanged =
    isSelectedAppointmentProviderOwned.value &&
    Boolean(desiredStartsAt && desiredEndsAt) &&
    (toDateTimeInputValue(
      formStore.selectedAppointment?.startsAt,
      workspaceTimezone.value
    ) !== formStore.form.startsAt ||
      toDateTimeInputValue(
        formStore.selectedAppointment?.endsAt,
        workspaceTimezone.value
      ) !== formStore.form.endsAt);
  const moveCabinetCode = hasProviderOwnedTimeChanged
    ? resolveAppointmentMedelementCabinetCode(
        formStore.selectedAppointment,
        referencesStore.resources
      ) || formStore.form.medelementCabinetCode
    : '';
  if (hasProviderOwnedTimeChanged && !moveCabinetCode) {
    useAlert(t('SCHEDULING.MEDELEMENT.CABINET_REQUIRED'));
    return;
  }

  const shouldCreateInMedelement =
    isSelectedFormResourceMedelement.value &&
    !isSelectedAppointmentProviderOwned.value &&
    !hasMedelementReceptionIdentity(formStore.selectedAppointment);
  const companyCabinetCode = formStore.form.medelementCabinetCode;
  const isCurrent = captureCalendarFormMutation();
  await runCurrentCalendarProviderAction({
    run: () =>
      formStore.submit(calendarStore, { isCurrent, closeOnSuccess: false }),
    isCurrent,
    onSuccess: appointment => {
      if (!appointment) return;
      if (!hasProviderOwnedTimeChanged) {
        useAlert(appointmentSaveAlertMessage(appointment, t));
      }
      if (isAppointmentPage.value) {
        syncCalendarContextToAppointment(appointment);
        openEditAppointment(appointment);
      } else {
        handleDrawerClose();
      }
      if (hasProviderOwnedTimeChanged) {
        stageProviderCommand({
          appointment,
          params: buildMedelementProviderCommandParams({
            appointment,
            companyCabinetCode: moveCabinetCode,
            operation: 'move_reception',
            patch: {
              starts_at: desiredStartsAt,
              ends_at: desiredEndsAt,
            },
          }),
        });
      } else if (shouldCreateInMedelement) {
        stageProviderCommand({
          appointment,
          params: buildMedelementProviderCommandParams({
            appointment,
            companyCabinetCode,
            operation: 'create_reception',
          }),
        });
      }
    },
    onError: error => useAlert(formatErrorMessage(error)),
  });
};

const cancelSelectedAppointment = async () => {
  if (formStore.ui.isSaving) return;
  const isCurrent = captureCalendarFormMutation();
  await runCurrentCalendarProviderAction({
    run: () =>
      formStore.cancel(calendarStore, { isCurrent, closeOnSuccess: false }),
    isCurrent,
    onSuccess: appointment => {
      if (!appointment) return;
      useAlert(appointmentCancellationAlertMessage(appointment, t));
      if (isAppointmentPage.value) {
        syncCalendarContextToAppointment(appointment);
        openEditAppointment(appointment);
      } else {
        handleDrawerClose();
      }
    },
    onError: error => useAlert(formatErrorMessage(error)),
  });
};

const handleLocalOnlyCancelConfirm = async () => {
  appointmentLocalCancelDialogRef.value?.close();
  await cancelSelectedAppointment();
};

const handleAppointmentCancel = async () => {
  if (formStore.ui.isSaving) return;
  if (isSelectedAppointmentCancelLocalOnly.value) {
    appointmentLocalCancelDialogRef.value?.open();
    return;
  }

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

  await cancelSelectedAppointment();
};

const openAppointmentDeleteDialog = () => {
  if (isSelectedAppointmentProviderOwned.value || formStore.ui.isSaving) return;

  appointmentDeleteDialogRef.value?.open();
};

const handleAppointmentDelete = async () => {
  if (isSelectedAppointmentProviderOwned.value || formStore.ui.isSaving) return;
  const isCurrent = captureCalendarFormMutation();
  await runCurrentCalendarProviderAction({
    run: () =>
      formStore.destroy(calendarStore, { isCurrent, closeOnSuccess: false }),
    isCurrent,
    onSuccess: deletedId => {
      if (!deletedId) return;
      appointmentDeleteDialogRef.value?.close();
      useAlert(t('SCHEDULING.APPOINTMENT_FORM.SUCCESS_DELETE'));
      closeAppointmentEditor();
    },
    onError: error => useAlert(formatErrorMessage(error)),
  });
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
    const pendingMoveMessage = appointmentProviderMoveMessage(
      updatedAppointment,
      t
    );
    if (pendingMoveMessage) useAlert(pendingMoveMessage);

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
  [
    () => formStore.form.serviceIds,
    () => formStore.form.resourceId,
    () => referencesStore.services,
  ],
  ([serviceIds, resourceId]) => {
    if (!serviceIds?.length) return;
    if (resourceId) formStore.syncServicePricing(referencesStore.services);
    formStore.syncServiceDuration(referencesStore.services);
  },
  { deep: true }
);

watch(
  [() => formStore.form.resourceId, selectedFormMedelementCabinets],
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
  },
  { immediate: true }
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
  calendarDisposed = true;
  providerActionGeneration += 1;
  activeProviderAction = null;
  providerCommandsStore.ui.operationId += 1;
  providerCommandsStore.ui.isExecuting = false;
  providerCommandsStore.ui.error = null;
  appointmentConversationDisposed = true;
  appointmentConversationDraft.contextRequestId += 1;
  appointmentConversationCreateRequestId += 1;
  handleDrawerClose();
});

const handleAppointmentRouteState = async () => {
  if (isAppointmentPage.value) {
    await openAppointmentFromRoute();
    return;
  }

  if (await consumeAppointmentOpenQuery()) return;
  if (formStore.isOpen && formStore.mode === 'edit') {
    handleDrawerClose();
  }
  await consumeAppointmentPrefillQuery();
};

const retryAppointmentPage = async () => {
  appointmentPageError.value = null;
  try {
    await loadPage();
    await openAppointmentFromRoute();
  } catch (error) {
    if (!calendarDisposed) {
      appointmentPageError.value = formatErrorMessage(error);
    }
  }
};

watch(
  () => route.params?.appointmentId,
  async (appointmentId, previousAppointmentId) => {
    if (
      previousAppointmentId &&
      Number(formStore.recordId) !== Number(appointmentId)
    ) {
      handleDrawerClose();
    }
    appointmentPageError.value = null;
    if (appointmentId) {
      await openAppointmentFromRoute();
    } else if (previousAppointmentId) {
      handleDrawerClose();
      if (!isCalendarLoaded.value || calendarStore.ui.error) {
        await fetchCalendar();
        isCalendarLoaded.value = true;
      }
    }
  }
);

watch(
  () => [
    route.query?.appointmentId,
    route.query?.action,
    route.query?.contactId,
    route.query?.conversationId,
  ],
  async () => {
    if (!isAppointmentPage.value) {
      await handleAppointmentRouteState();
    }
  }
);

onMounted(async () => {
  handleDrawerClose();
  calendarStore.setWorkspaceTimezone(workspaceTimezone.value);
  calendarStore.hydratePreferences();
  currentPresentation.value = 'calendar';
  try {
    await loadPage();
    await handleAppointmentRouteState();
  } catch (error) {
    if (!calendarDisposed && isAppointmentPage.value) {
      appointmentPageError.value = formatErrorMessage(error);
    }
  }
});
</script>

<template>
  <section class="relative flex flex-1 min-h-0 overflow-hidden bg-n-surface-1">
    <div
      v-show="!isAppointmentPage"
      class="flex min-w-0 flex-1 flex-col overflow-hidden"
    >
      <SchedulingToolbar
        v-model="currentView"
        :anchor-date="calendarStore.anchorDate"
        :current-label="pageTitle"
        :views="calendarTypeViews"
        show-today
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
          calendarStore.setAnchorDate(
            calendarTodayAnchor(new Date(), workspaceTimezone).toISOString()
          );
          fetchCalendar();
        "
        @select-date="handleAnchorDateSelect"
      >
        <template #leading>
          <SchedulingViewSwitcher
            v-model="currentPresentation"
            :views="presentationOptions"
            icon-only
          />
        </template>
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
              ? 'flex h-full min-h-0 flex-col px-6 pb-4 pt-2'
              : 'flex flex-col gap-4 px-6 pb-4 pt-2'
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
            :workspace-timezone="workspaceTimezone"
            @change-status="
              updateAppointmentMutation($event.appointment, {
                status: $event.status,
              })
            "
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
            @create-appointment="openCreateAppointment($event)"
            @select-appointment="handleSelectAppointment($event)"
          />
        </div>
      </div>
    </div>

    <div
      v-if="isAppointmentPage && !formStore.isOpen"
      class="flex min-h-0 flex-1 flex-col"
    >
      <header class="border-b border-n-weak bg-n-surface-1 px-4 py-2">
        <Button
          size="sm"
          color="slate"
          variant="ghost"
          icon="i-lucide-arrow-left"
          :label="$t('SCHEDULING.GENERAL.BACK')"
          @click="returnToCalendar"
        />
      </header>
      <div class="flex min-h-0 flex-1 items-center justify-center p-6">
        <SchedulingErrorState
          v-if="appointmentPageError"
          :title="$t('SCHEDULING.GENERAL.ERROR_TITLE')"
          :description="appointmentPageError"
          @retry="retryAppointmentPage"
        />
        <Spinner v-else class="!h-8 !w-8" />
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
        v-if="
          formStore.isOpen && (isAppointmentPage || formStore.mode === 'create')
        "
        :class="
          isAppointmentPage
            ? 'flex min-h-0 min-w-0 flex-1'
            : 'modal-mask fixed inset-0 z-[110] bg-black/35 p-3 backdrop-blur-[4px]'
        "
      >
        <div :class="appointmentDrawerModalClass">
          <div
            v-if="isAppointmentPage"
            data-testid="scheduling-appointment-page-tabs"
            class="grid grid-cols-2 border-b border-n-weak bg-n-alpha-black2 p-1 lg:hidden"
            role="tablist"
            :aria-label="$t('SCHEDULING.APPOINTMENT_FORM.APPOINTMENT_TITLE')"
          >
            <button
              type="button"
              class="inline-flex h-8 items-center justify-center rounded-lg px-3 text-sm font-medium transition-colors"
              :class="
                appointmentPageTab === 'appointment'
                  ? 'bg-n-solid-1 text-n-slate-12 shadow-sm'
                  : 'text-n-slate-11 hover:text-n-slate-12'
              "
              role="tab"
              :aria-selected="appointmentPageTab === 'appointment'"
              @click="appointmentPageTab = 'appointment'"
            >
              {{ $t('SCHEDULING.APPOINTMENT_FORM.APPOINTMENT_TITLE') }}
            </button>
            <button
              type="button"
              class="inline-flex h-8 items-center justify-center rounded-lg px-3 text-sm font-medium transition-colors"
              :class="
                appointmentPageTab === 'chat'
                  ? 'bg-n-solid-1 text-n-slate-12 shadow-sm'
                  : 'text-n-slate-11 hover:text-n-slate-12'
              "
              role="tab"
              :aria-selected="appointmentPageTab === 'chat'"
              @click="appointmentPageTab = 'chat'"
            >
              {{ $t('SCHEDULING.APPOINTMENT_PAGE.CHAT_TAB') }}
            </button>
          </div>
          <aside
            data-testid="scheduling-appointment-card"
            class="min-w-0 w-full flex-col overflow-hidden bg-n-solid-2"
            :class="{
              'flex h-full md:w-[28rem] md:min-w-[28rem] xl:w-[30rem] xl:min-w-[30rem]':
                !isAppointmentPage,
              'min-h-0 flex-1 lg:h-full lg:w-1/3 lg:flex-none lg:border-r lg:border-n-weak':
                isAppointmentPage,
              flex: !isAppointmentPage || appointmentPageTab === 'appointment',
              'hidden lg:flex':
                isAppointmentPage && appointmentPageTab === 'chat',
              'md:border-r md:border-n-weak':
                !isAppointmentPage && shouldShowAppointmentConversationPanel,
            }"
          >
            <header
              class="flex items-center gap-2 border-b border-n-weak bg-n-surface-1 px-4 py-2"
            >
              <Button
                v-if="isAppointmentPage"
                size="sm"
                color="slate"
                variant="ghost"
                icon="i-lucide-arrow-left"
                :label="$t('SCHEDULING.GENERAL.BACK')"
                @click="closeAppointmentEditor"
              />
              <input
                id="scheduling-appointment-drawer-title"
                :disabled="formStore.ui.isSaving"
                class="reset-base min-w-0 flex-1 border-none bg-transparent text-base font-semibold text-n-slate-12 outline-none placeholder:text-n-slate-10"
                :aria-label="
                  $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_FIRST_NAME')
                "
                :placeholder="drawerTitle"
                :value="formStore.form.clientFirstName"
                @input="
                  formStore.updateField('clientFirstName', $event.target.value)
                "
              />

              <span
                v-if="selectedAppointmentMedelementStatus"
                v-tooltip.bottom="selectedAppointmentMedelementStatus.label"
                :title="selectedAppointmentMedelementStatus.label"
                :aria-label="selectedAppointmentMedelementStatus.label"
                :data-sync-state="selectedAppointmentMedelementStatus.state"
                data-test="calendar-appointment-medelement-meta"
                role="status"
                class="inline-flex size-7 shrink-0 items-center justify-center rounded-lg border transition-colors"
                :class="
                  {
                    synced: 'border-n-teal-6/50 bg-n-teal-3 text-n-teal-11',
                    pending: 'border-n-amber-6/50 bg-n-amber-3 text-n-amber-11',
                    warning: 'border-n-amber-6/50 bg-n-amber-3 text-n-amber-11',
                    error: 'border-n-ruby-6/50 bg-n-ruby-3 text-n-ruby-11',
                    not_synced: 'border-n-weak bg-n-alpha-2 text-n-slate-11',
                  }[selectedAppointmentMedelementStatus.state]
                "
              >
                <svg
                  viewBox="0 0 24 24"
                  fill="none"
                  xmlns="http://www.w3.org/2000/svg"
                  class="size-4 shrink-0"
                  aria-hidden="true"
                >
                  <path
                    d="M2.25 9.25L4.85 6.75H5.55V8.3C6.35 7.25 7.55 6.55 9.05 6.55C10.7 6.55 11.95 7.25 12.55 8.55C13.45 7.25 14.8 6.55 16.45 6.55C18.95 6.55 20.45 8.2 20.45 11.05V17.25H17.15V11.55C17.15 9.95 16.4 9.15 15.15 9.15C13.85 9.15 13.05 10.05 13.05 11.65V17.25H9.75V11.55C9.75 9.95 9.0 9.15 7.75 9.15C6.45 9.15 5.65 10.05 5.65 11.65V17.25H2.25V9.25Z"
                    fill="currentColor"
                  />
                  <rect
                    x="21.1"
                    y="13.85"
                    width="2.4"
                    height="3.4"
                    rx="0.5"
                    fill="currentColor"
                  />
                </svg>
                <span class="sr-only">
                  {{ selectedAppointmentMedelementStatus.label }}
                </span>
              </span>

              <Button
                v-if="
                  !isAppointmentPage &&
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
                  formStore.ui.isCreatingContact ||
                  (!isSelectedAppointmentProviderOwned &&
                    (isMedelementCabinetMissing || isMedelementContactMissing))
                "
                :label="drawerConfirmLabel"
                @click="handleAppointmentSubmit"
              />
              <Button
                v-if="!isAppointmentPage"
                size="sm"
                color="slate"
                variant="ghost"
                icon="i-lucide-x"
                @click="closeAppointmentEditor"
              />
            </header>

            <div class="min-h-0 flex-1 overflow-y-auto px-4 py-3">
              <fieldset
                class="appointment-drawer-form min-w-0 border-0 p-0"
                :disabled="formStore.ui.isSaving"
                :inert="formStore.ui.isSaving ? '' : undefined"
                data-test="appointment-form-controls"
              >
                <p
                  v-if="
                    appointmentCrmLinkWarningMessage(
                      formStore.selectedAppointment,
                      $t
                    )
                  "
                  class="mb-3 text-sm leading-5 text-n-amber-11"
                  role="status"
                  data-test="calendar-crm-link-result"
                >
                  {{
                    appointmentCrmLinkWarningMessage(
                      formStore.selectedAppointment,
                      $t
                    )
                  }}
                </p>
                <div
                  v-if="formStore.ui.error"
                  class="px-4 py-3 text-sm rounded-xl bg-n-ruby-3/70 text-n-ruby-11"
                >
                  {{ formErrorMessage }}
                </div>

                <div class="appointment-contact-section">
                  <div class="appointment-contact-section-heading">
                    <h3
                      class="mb-0 flex items-center gap-2 text-sm font-semibold text-n-slate-12"
                    >
                      <span>{{
                        $t('SCHEDULING.APPOINTMENT_FORM.CONTACT_TITLE')
                      }}</span>
                      <span
                        v-if="
                          formStore.form.contactId ||
                          formStore.form.patientContactId
                        "
                        data-test="calendar-selected-contact-badge"
                        class="inline-flex items-center rounded-md bg-n-teal-3 px-2 py-0.5 text-xs font-medium text-n-teal-11"
                      >
                        {{ $t('SCHEDULING.CONTACT.SELECTED_BADGE') }}
                      </span>
                    </h3>
                    <div
                      class="relative flex items-center gap-2 ltr:ml-auto rtl:mr-auto"
                    >
                      <Button
                        v-if="!isContactEditorOpen && canEditInlineContact"
                        size="sm"
                        variant="link"
                        color="blue"
                        data-test="calendar-edit-contact-button"
                        :label="$t('SCHEDULING.GENERAL.EDIT')"
                        :disabled="formStore.ui.isSaving"
                        @click="openInlineContactEdit"
                      />
                      <Button
                        v-if="
                          !formStore.form.patientContactId &&
                          !isSelectedAppointmentInMedelement
                        "
                        size="sm"
                        variant="link"
                        color="blue"
                        :label="$t('SCHEDULING.CONTACT.SELECT_ACTION')"
                        :disabled="formStore.ui.isSaving"
                        @click.stop="openContactSelector"
                      />
                      <SchedulingSelectField
                        ref="contactSelectorFieldRef"
                        class="pointer-events-none absolute right-0 top-full h-px w-px opacity-0"
                        :model-value="
                          formStore.form.patientContactId ||
                          formStore.form.contactId
                        "
                        :disabled="
                          formStore.ui.isSaving ||
                          Boolean(formStore.form.patientContactId) ||
                          isSelectedAppointmentInMedelement
                        "
                        :options="contactOptions"
                        use-api-results
                        dropdown-align="end"
                        :dropdown-min-width="405"
                        placeholder=" "
                        :aria-label="$t('SCHEDULING.CONTACT.SELECT_ACTION')"
                        :search-placeholder="
                          $t('SCHEDULING.APPOINTMENT_FORM.CONTACT_SEARCH')
                        "
                        :empty-state="
                          $t('SCHEDULING.APPOINTMENT_FORM.CONTACT_EMPTY')
                        "
                        @open="handleContactDropdownOpen"
                        @search="searchAppointmentContacts"
                        @update:model-value="handleContactSelect"
                      />
                    </div>
                  </div>

                  <div class="appointment-contact-accordion">
                    <div
                      v-if="!isContactEditorOpen"
                      class="grid gap-2 text-sm"
                      :data-test="
                        formStore.isProviderPatientIdentity
                          ? 'calendar-patient-provider-source'
                          : 'calendar-patient-summary'
                      "
                    >
                      <div class="appointment-drawer-row">
                        <span class="appointment-drawer-label">
                          {{ $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_NAME') }}
                        </span>
                        <span
                          class="appointment-drawer-control text-sm font-medium text-n-slate-12"
                        >
                          {{ appointmentClientName() }}
                        </span>
                      </div>
                      <div
                        v-if="
                          formStore.form.clientPhone &&
                          !needsProviderPatientPhoneInput &&
                          !formStore.form.patientContactId &&
                          !formStore.form.contactId
                        "
                        class="appointment-drawer-row"
                      >
                        <span class="appointment-drawer-label">
                          {{ $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_PHONE') }}
                        </span>
                        <span
                          class="appointment-drawer-control text-sm text-n-slate-11 tabular-nums"
                        >
                          {{ formStore.form.clientPhone }}
                        </span>
                      </div>
                      <SchedulingContactPhoneEditor
                        v-if="
                          formStore.form.patientContactId ||
                          formStore.form.contactId
                        "
                        :contact-id="
                          formStore.form.patientContactId ||
                          formStore.form.contactId
                        "
                        :phone="
                          formStore.selectedContact?.phone ||
                          formStore.form.clientPhone
                        "
                        :saving="isPhoneSaving || formStore.ui.isSaving"
                        :error="phoneEditorError"
                        @save="saveContactPhone"
                      />
                      <div
                        v-if="formStore.form.clientIdentifier"
                        class="appointment-drawer-row"
                      >
                        <span class="appointment-drawer-label">
                          {{ $t('SCHEDULING.CONTACT.IIN') }}
                        </span>
                        <span
                          class="appointment-drawer-control text-sm text-n-slate-11 tabular-nums"
                        >
                          {{ formStore.form.clientIdentifier }}
                        </span>
                      </div>
                      <div
                        v-if="formStore.form.clientBirthDate"
                        class="appointment-drawer-row"
                      >
                        <span class="appointment-drawer-label">
                          {{ $t('SCHEDULING.CONTACT.BIRTH_DATE') }}
                        </span>
                        <span
                          class="appointment-drawer-control text-sm text-n-slate-11"
                        >
                          {{ formStore.form.clientBirthDate }}
                        </span>
                      </div>
                      <div
                        v-if="
                          needsProviderPatientPhoneInput &&
                          !formStore.form.patientContactId &&
                          !formStore.form.contactId
                        "
                        class="appointment-drawer-row pt-1"
                      >
                        <span class="appointment-drawer-label">
                          {{
                            isSelectedFormResourceMedelement
                              ? requiredContactLabel(
                                  $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_PHONE')
                                )
                              : $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_PHONE')
                          }}
                        </span>
                        <div class="appointment-drawer-control">
                          <PhoneNumberInput
                            :model-value="formStore.form.clientPhone"
                            :disabled="formStore.ui.isSaving"
                            class="appointment-drawer-phone-control"
                            default-country="KZ"
                            :show-country-flag="false"
                            :max-digits="11"
                            :label="
                              isSelectedFormResourceMedelement
                                ? requiredContactLabel(
                                    $t(
                                      'SCHEDULING.APPOINTMENT_FORM.CLIENT_PHONE'
                                    )
                                  )
                                : $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_PHONE')
                            "
                            size="md"
                            @update:model-value="
                              formStore.updateField('clientPhone', $event)
                            "
                          />
                          <p
                            v-if="inlineContactPhoneMessage"
                            class="mt-1 mb-0 text-xs text-n-ruby-9"
                          >
                            {{ inlineContactPhoneMessage }}
                          </p>
                        </div>
                      </div>
                    </div>

                    <div v-if="isContactEditorOpen" class="grid gap-2">
                      <div class="appointment-drawer-row">
                        <span class="appointment-drawer-label">
                          {{
                            requiredContactLabel(
                              $t(
                                'SCHEDULING.APPOINTMENT_FORM.CLIENT_FIRST_NAME'
                              )
                            )
                          }}
                        </span>
                        <Input
                          class="appointment-drawer-control"
                          :model-value="formStore.form.clientFirstName"
                          :disabled="formStore.ui.isSaving"
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
                      </div>

                      <div class="appointment-drawer-row">
                        <span class="appointment-drawer-label">
                          {{
                            isInlineContactMedelementContext
                              ? requiredContactLabel(
                                  $t(
                                    'SCHEDULING.APPOINTMENT_FORM.CLIENT_LAST_NAME'
                                  )
                                )
                              : $t(
                                  'SCHEDULING.APPOINTMENT_FORM.CLIENT_LAST_NAME'
                                )
                          }}
                        </span>
                        <Input
                          class="appointment-drawer-control"
                          :model-value="formStore.form.clientLastName"
                          :disabled="formStore.ui.isSaving"
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
                      </div>

                      <div class="appointment-drawer-row">
                        <span class="appointment-drawer-label">
                          {{
                            $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_MIDDLE_NAME')
                          }}
                        </span>
                        <Input
                          class="appointment-drawer-control"
                          :model-value="formStore.form.clientMiddleName"
                          :disabled="formStore.ui.isSaving"
                          :label="
                            $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_MIDDLE_NAME')
                          "
                          @update:model-value="
                            formStore.updateField('clientMiddleName', $event)
                          "
                        />
                      </div>

                      <div class="appointment-drawer-row">
                        <span class="appointment-drawer-label">
                          {{
                            isInlineContactMedelementContext
                              ? requiredContactLabel(
                                  $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_PHONE')
                                )
                              : $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_PHONE')
                          }}
                        </span>
                        <div class="appointment-drawer-control">
                          <PhoneNumberInput
                            :model-value="formStore.form.clientPhone"
                            :disabled="formStore.ui.isSaving"
                            class="appointment-drawer-phone-control"
                            default-country="KZ"
                            :show-country-flag="false"
                            :max-digits="11"
                            :label="
                              isInlineContactMedelementContext
                                ? requiredContactLabel(
                                    $t(
                                      'SCHEDULING.APPOINTMENT_FORM.CLIENT_PHONE'
                                    )
                                  )
                                : $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_PHONE')
                            "
                            size="md"
                            @update:model-value="
                              formStore.updateField('clientPhone', $event)
                            "
                          />
                          <p
                            v-if="inlineContactPhoneMessage"
                            class="mt-1 mb-0 text-xs text-n-ruby-9"
                          >
                            {{ inlineContactPhoneMessage }}
                          </p>
                        </div>
                      </div>

                      <div class="appointment-drawer-row">
                        <span class="appointment-drawer-label">
                          {{
                            isInlineContactMedelementContext
                              ? `${$t('SCHEDULING.CONTACT.IIN')} *`
                              : $t('SCHEDULING.CONTACT.IIN')
                          }}
                        </span>
                        <Input
                          class="appointment-drawer-control"
                          :model-value="inlineContactForm.iin"
                          :disabled="formStore.ui.isSaving"
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
                          @update:model-value="
                            updateInlineContactField('iin', $event)
                          "
                        />
                      </div>

                      <div class="appointment-drawer-row">
                        <span class="appointment-drawer-label">
                          {{ $t('SCHEDULING.CONTACT.BIRTH_DATE') }}
                        </span>
                        <SchedulingDateTimeField
                          class="appointment-drawer-control"
                          :model-value="inlineContactForm.birthDate"
                          :disabled="formStore.ui.isSaving"
                          type="date"
                          :label="$t('SCHEDULING.CONTACT.BIRTH_DATE')"
                          @update:model-value="
                            updateInlineContactField('birthDate', $event)
                          "
                        />
                      </div>

                      <div class="appointment-drawer-row">
                        <span class="appointment-drawer-label">
                          {{ $t('SCHEDULING.CONTACT.GENDER_LABEL') }}
                        </span>
                        <SchedulingSelectField
                          class="appointment-drawer-control appointment-drawer-select-control"
                          :model-value="inlineContactForm.gender"
                          :disabled="formStore.ui.isSaving"
                          :options="genderOptions"
                          :label="$t('SCHEDULING.CONTACT.GENDER_LABEL')"
                          :placeholder="$t('SCHEDULING.CONTACT.GENDER_LABEL')"
                          @update:model-value="
                            updateInlineContactField('gender', $event)
                          "
                        />
                      </div>

                      <div class="flex justify-end gap-2 pt-1">
                        <Button
                          v-if="formStore.mode === 'edit'"
                          size="sm"
                          variant="ghost"
                          color="slate"
                          :disabled="
                            formStore.ui.isSaving ||
                            formStore.ui.isCreatingContact
                          "
                          :label="$t('SCHEDULING.GENERAL.CANCEL')"
                          @click="cancelInlineContactEdit"
                        />
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
                >
                  <AppointmentDealSelector
                    v-if="formStore.mode === 'create'"
                    v-model="appointmentDealSelection"
                    :communication-contact-id="formStore.form.contactId"
                    :conversation-display-id="
                      formStore.form.conversationDisplayId
                    "
                    :disabled="formStore.ui.isSaving"
                    class="mb-2"
                  />
                  <div class="grid gap-2">
                    <div class="appointment-drawer-row">
                      <span class="appointment-drawer-label">
                        {{ $t('SCHEDULING.APPOINTMENT_FORM.RESOURCE') }}
                      </span>
                      <SchedulingSelectField
                        class="appointment-drawer-control appointment-drawer-select-control"
                        :model-value="formStore.form.resourceId"
                        :disabled="
                          formStore.ui.isSaving ||
                          isSelectedAppointmentInMedelement
                        "
                        :options="resourceOptions"
                        :label="$t('SCHEDULING.APPOINTMENT_FORM.RESOURCE')"
                        :placeholder="
                          $t('SCHEDULING.APPOINTMENT_FORM.RESOURCE')
                        "
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
                    </div>

                    <div
                      v-if="isSelectedFormResourceMedelement"
                      class="appointment-drawer-row"
                    >
                      <span class="appointment-drawer-label">
                        {{ $t('SCHEDULING.MEDELEMENT.CABINET') }}
                      </span>
                      <SchedulingSelectField
                        class="appointment-drawer-control appointment-drawer-select-control"
                        :model-value="formStore.form.medelementCabinetCode"
                        :disabled="
                          formStore.ui.isSaving ||
                          isSelectedAppointmentInMedelement
                        "
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
                    </div>

                    <div
                      class="appointment-drawer-row appointment-drawer-row--start"
                    >
                      <span class="appointment-drawer-label">
                        {{ $t('SCHEDULING.APPOINTMENT_FORM.SERVICE') }}
                      </span>
                      <div class="appointment-drawer-control grid gap-1">
                        <TagMultiSelectComboBox
                          v-if="hasServiceOptions"
                          class="appointment-drawer-multi-control"
                          :model-value="appointmentFormControlValues.serviceIds"
                          :disabled="
                            formStore.ui.isSaving ||
                            isSelectedAppointmentProviderOwned
                          "
                          :options="serviceOptions"
                          wrap-labels
                          clamp-selected-labels
                          show-selected-label-preview
                          :placeholder="
                            $t('SCHEDULING.APPOINTMENT_FORM.SERVICE')
                          "
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
                          :disabled="
                            formStore.ui.isSaving ||
                            isSelectedAppointmentProviderOwned
                          "
                          :placeholder="
                            $t('SCHEDULING.APPOINTMENT_FORM.SERVICE')
                          "
                          @update:model-value="
                            value => {
                              formStore.updateField('serviceIds', []);
                              formStore.updateField(
                                'serviceNameSnapshot',
                                value
                              );
                            }
                          "
                        />
                        <p v-else class="mt-1 mb-0 text-xs text-n-slate-10">
                          {{
                            $t('SCHEDULING.MEDELEMENT.NO_SPECIALIST_SERVICES')
                          }}
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
                    </div>

                    <div class="appointment-drawer-row">
                      <span class="appointment-drawer-label">
                        {{ $t('SCHEDULING.APPOINTMENT_FORM.STATUS') }}
                      </span>
                      <SchedulingSelectField
                        class="appointment-drawer-control appointment-drawer-select-control"
                        :model-value="formStore.form.status"
                        :disabled="
                          formStore.ui.isSaving ||
                          isSelectedAppointmentProviderOwned
                        "
                        :options="appointmentStatusOptions"
                        :label="$t('SCHEDULING.APPOINTMENT_FORM.STATUS')"
                        :placeholder="$t('SCHEDULING.APPOINTMENT_FORM.STATUS')"
                        @update:model-value="
                          formStore.updateField('status', $event)
                        "
                      />
                    </div>

                    <div class="appointment-drawer-row">
                      <span class="appointment-drawer-label">
                        {{ $t('SCHEDULING.APPOINTMENT_FORM.SERVICE_AMOUNT') }}
                      </span>
                      <SchedulingMoneyInput
                        :model-value="formStore.form.serviceAmount"
                        :disabled="
                          formStore.ui.isSaving ||
                          isSelectedAppointmentProviderOwned
                        "
                        class="appointment-drawer-control appointment-drawer-money-control"
                        min="0"
                        :label="
                          $t('SCHEDULING.APPOINTMENT_FORM.SERVICE_AMOUNT')
                        "
                        @update:model-value="
                          formStore.updateField('serviceAmount', $event)
                        "
                      />
                    </div>

                    <SchedulingAppointmentTimeFields
                      v-model:starts-at="appointmentStartsAt"
                      v-model:ends-at="appointmentEndsAt"
                      v-model:duration-min="appointmentDurationMin"
                      id-prefix="calendar-appointment"
                      layout="rows"
                      :disabled="formStore.ui.isSaving"
                      :starts-at-message="
                        formStore.validationErrors.startsAt
                          ? validationErrorMessage(
                              formStore.validationErrors.startsAt
                            )
                          : ''
                      "
                      :ends-at-message="
                        formStore.validationErrors.endsAt
                          ? validationErrorMessage(
                              formStore.validationErrors.endsAt
                            )
                          : ''
                      "
                      @change="formStore.markDurationEdited()"
                    />
                    <p
                      v-if="formStore.validationErrors.durationMin"
                      class="m-0 text-xs text-n-ruby-9"
                    >
                      {{ $t(formStore.validationErrors.durationMin) }}
                    </p>
                  </div>
                </SchedulingFormFieldGroup>

                <CrmCustomFieldsSection
                  class="appointment-custom-fields-section"
                  :model-value="appointmentCustomFieldsModelValue"
                  :disabled="formStore.ui.isSaving"
                  :definitions="unifiedAppointmentFieldDefinitions"
                  :framed="false"
                  layout="rows"
                  @update:model-value="handleAppointmentCustomFieldsUpdate"
                />

                <div class="appointment-drawer-section">
                  <div
                    class="appointment-drawer-row appointment-drawer-row--start"
                  >
                    <span class="appointment-drawer-label">
                      {{ $t('SCHEDULING.APPOINTMENT_FORM.COMMENT') }}
                    </span>
                    <TextArea
                      class="appointment-drawer-control"
                      :model-value="formStore.form.clientComment"
                      :disabled="formStore.ui.isSaving"
                      auto-height
                      custom-text-area-wrapper-class="!rounded-md !border-n-weak !bg-n-alpha-black2 !px-2 !py-1 hover:!border-n-slate-6"
                      :label="$t('SCHEDULING.APPOINTMENT_FORM.COMMENT')"
                      :placeholder="
                        $t('SCHEDULING.APPOINTMENT_FORM.COMMENT_PLACEHOLDER')
                      "
                      min-height="3rem"
                      @update:model-value="
                        formStore.updateField('clientComment', $event)
                      "
                    />
                  </div>
                </div>

                <div
                  v-if="formStore.mode === 'edit'"
                  class="appointment-drawer-section"
                >
                  <p
                    v-if="isSelectedAppointmentLocallyCancelled"
                    class="mb-2 text-xs font-medium leading-5 text-n-amber-11"
                    role="status"
                  >
                    {{
                      $t(
                        'SCHEDULING.APPOINTMENT_STATUS.MEDELEMENT_NOT_CANCELLED'
                      )
                    }}
                  </p>
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
              </fieldset>
            </div>
          </aside>

          <CrmDealConversationPanel
            data-testid="scheduling-appointment-chat"
            :active="!isAppointmentPage || appointmentPageTab === 'chat'"
            :inline="isAppointmentPage"
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
            :show-appointments="false"
            :show-open-full-screen="false"
            :visible="
              formStore.isOpen && shouldShowAppointmentConversationPanel
            "
            @add-contact="handleAppointmentConversationAddContact"
            @close="closeAppointmentConversationPanel"
            @create-conversation="createAppointmentConversation"
            @open-full-screen="openPatientDialog"
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
        </div>

        <label
          class="flex cursor-pointer items-center gap-2 text-sm text-n-slate-12"
        >
          <Checkbox
            v-model="appointmentFilterDraft.hideCancelledAppointments"
          />
          <span>{{
            $t('SCHEDULING.TOOLBAR.HIDE_CANCELLED_APPOINTMENTS')
          }}</span>
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
          providerCommandRequiresPatientSelection(
            pendingProviderAction?.command
          )
        "
        class="flex flex-col gap-2"
      >
        <button
          v-for="candidate in patientCandidates"
          :key="candidate.token"
          type="button"
          :disabled="providerCommandsStore.ui.isExecuting"
          class="flex flex-col items-start gap-1 p-3 text-start border rounded-lg"
          :class="
            selectedPatientToken === candidate.token
              ? 'border-n-brand bg-n-brand/10'
              : 'border-n-weak hover:border-n-strong'
          "
          @click="selectProviderPatientCandidate(candidate.token)"
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

    <Dialog
      ref="appointmentLocalCancelDialogRef"
      width="md"
      type="alert"
      :title="$t('SCHEDULING.MEDELEMENT.LOCAL_CANCEL_CONFIRM_TITLE')"
      :description="
        $t('SCHEDULING.MEDELEMENT.LOCAL_CANCEL_CONFIRM_DESCRIPTION')
      "
      :confirm-button-label="
        $t('SCHEDULING.APPOINTMENT_FORM.CANCEL_APPOINTMENT')
      "
      :is-loading="formStore.ui.isSaving"
      @confirm="handleLocalOnlyCancelConfirm"
    />
  </section>
</template>

<style scoped>
.appointment-contact-accordion {
  @apply grid gap-2;
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

.appointment-drawer-row {
  display: grid;
  gap: 0.375rem;
  min-width: 0;
}

.appointment-drawer-label {
  @apply mb-0 min-w-0 text-[13px] font-medium leading-4 text-n-slate-12;
}

.appointment-drawer-control,
.appointment-drawer-form :deep(.appointment-drawer-control) {
  width: 100%;
  min-width: 0;
}

.appointment-drawer-row :deep(> div > label),
.appointment-drawer-row :deep(> div > span.mb-0\.5),
.appointment-drawer-row :deep(.appointment-drawer-control label) {
  @apply sr-only;
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

.appointment-drawer-form :deep(section.appointment-custom-fields-section),
.appointment-drawer-form :deep(section.appointment-custom-fields-section > div),
.appointment-drawer-form
  :deep(
    section.appointment-custom-fields-section .crm-custom-fields-section-rows
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
  @apply gap-2 pt-0;
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
  .appointment-drawer-row {
    align-items: center;
    grid-template-columns: minmax(6.5rem, 1fr) minmax(8rem, 14rem);
  }

  .appointment-drawer-row--start {
    align-items: start;
  }

  .appointment-drawer-label {
    @apply text-left;
  }

  .appointment-drawer-row--start > .appointment-drawer-label {
    padding-top: 0.5rem;
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
