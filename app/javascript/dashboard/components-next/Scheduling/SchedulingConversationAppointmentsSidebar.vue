<script setup>
import {
  computed,
  nextTick,
  onBeforeUnmount,
  onMounted,
  reactive,
  ref,
  watch,
} from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';

import SchedulingAppointmentsAPI from 'dashboard/api/scheduling/appointments';
import SchedulingProviderCommandsAPI from 'dashboard/api/scheduling/providerCommands';
import SidebarActionsHeader from 'dashboard/components-next/SidebarActionsHeader.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import SchedulingDateTimeField from 'dashboard/components-next/Scheduling/SchedulingDateTimeField.vue';
import SchedulingErrorState from 'dashboard/components-next/Scheduling/SchedulingErrorState.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import { useAlert } from 'dashboard/composables';
import { useStore } from 'dashboard/composables/store';
import {
  resolveChatContact,
  resolveChatContactId,
} from 'dashboard/components-next/CRM/crmConversationDealContext';
import {
  compactPayload,
  formatSchedulingErrorMessage,
  normalizePayload,
  toIntegerNumeric,
  toNumeric,
} from 'dashboard/stores/scheduling/shared';
import {
  providerCommandIntentMatches,
  providerCommandRequiresPatientSelection,
  useSchedulingProviderCommandsStore,
} from 'dashboard/stores/scheduling/providerCommands';
import { useSchedulingReferencesStore } from 'dashboard/stores/scheduling/references';
import { isKazakhstanE164Phone } from 'dashboard/stores/scheduling/appointmentForm';
import { schedulingContactNameParts } from 'dashboard/stores/scheduling/contactName';
import {
  patientBirthDate,
  patientContactId,
  useConversationPatientContextStore,
} from 'dashboard/stores/scheduling/patientContext';
import {
  addMinutesToDateTimeInputValue,
  appointmentCancellationAlertMessage,
  buildMedelementProviderCommandParams,
  fromDateTimeInputValue,
  getServicePriceForResource,
  isAppointmentProviderOwned,
  isMedelementCancellationLocalOnly,
  providerBookingNeedsReview,
  providerBookingStatusKey,
  providerBookingStatusMessage,
  providerCancellationPending,
  isMedelementResource,
  medelementCabinetsForResource,
  resolveAppointmentMedelementCabinetCode,
  servicesAvailableForResource,
  toDateTimeInputValue,
} from 'dashboard/routes/dashboard/scheduling/helpers';
import {
  APPOINTMENT_STATUS_ICONS,
  APPOINTMENT_STATUS_ICON_CLASSES,
  APPOINTMENT_STATUS_VALUES,
  DEFAULT_WORKSPACE_TIMEZONE,
} from 'dashboard/routes/dashboard/scheduling/constants';

const props = defineProps({
  currentChat: {
    required: true,
    type: Object,
  },
  selectedPatient: { type: Object, default: null },
  patientContextEnabled: { type: Boolean, default: false },
  patientContextLoading: { type: Boolean, default: false },
  patientContextKey: { type: String, default: '' },
});
const emit = defineEmits(['close', 'patientBound']);
// Appointments are shown and edited on the clinic clock, the same timezone as
// the calendar grid, whatever the browser timezone is.
const SCHEDULING_TIMEZONE = DEFAULT_WORKSPACE_TIMEZONE;
const toClinicDateTime = value =>
  toDateTimeInputValue(value, SCHEDULING_TIMEZONE);
const fromClinicDateTime = value =>
  fromDateTimeInputValue(value, SCHEDULING_TIMEZONE);

const NEW_APPOINTMENT_KEY = 'new-appointment';

const { t, locale } = useI18n();
const store = useStore();
const route = useRoute();
const schedulingReferencesStore = useSchedulingReferencesStore();
const providerCommandsStore = useSchedulingProviderCommandsStore();
const patientContextStore = useConversationPatientContextStore();

const appointments = ref([]);
const appointmentForms = reactive({});
const openAppointmentKeys = ref([]);
const scrollContainer = ref(null);
const isCreating = ref(false);
const isSavingCreate = ref(false);
const savingAppointmentKey = ref('');
const cancellingAppointmentKey = ref('');
const checkingAppointmentKey = ref('');
const resolvingCancellationKey = ref('');
const cancellationReviews = reactive({});
const patientActions = reactive({});
const patientActionLookupIds = reactive({});
const patientActionBusyKey = ref('');
const patientActionRequestId = ref(0);
let providerReviewGeneration = 0;
let loadRequestId = 0;
let sidebarDisposed = false;
let appointmentSaveRequestId = 0;
let createSaveRequestId = 0;
let appointmentCancellationRequestId = 0;
let referencesReadyPromise;
const createForm = reactive({
  clientBirthDate: '',
  clientGender: '',
  clientIdentifier: '',
  clientIdentifierInferred: false,
  clientFirstName: '',
  clientLastName: '',
  clientMiddleName: '',
  clientName: '',
  clientNameStructured: true,
  clientPhone: '',
  patientContactId: null,
  patientContextContactId: null,
  endsAt: '',
  medelementCabinetCode: '',
  resourceId: '',
  serviceAmount: '',
  serviceId: '',
  serviceNameSnapshot: '',
  startsAt: '',
  status: 'scheduled',
});
const ui = reactive({
  isLoading: false,
  error: null,
});

const headerButtons = computed(() =>
  isCreating.value || !patientContextReady.value
    ? []
    : [
        {
          icon: 'i-lucide-plus',
          key: 'new_appointment',
          tooltip: t('SCHEDULING.CALENDAR.NEW_APPOINTMENT'),
        },
      ]
);

const appointmentStatusLabels = computed(() => ({
  cancelled: t('SCHEDULING.APPOINTMENT_STATUS.cancelled'),
  completed: t('SCHEDULING.DIALOGS.APPOINTMENT_STATUS_SHORT.completed'),
  confirmed: t('SCHEDULING.DIALOGS.APPOINTMENT_STATUS_SHORT.confirmed'),
  no_show: t('SCHEDULING.APPOINTMENT_STATUS.no_show'),
  scheduled: t('SCHEDULING.DIALOGS.APPOINTMENT_STATUS_SHORT.scheduled'),
}));

const statusOptions = computed(() =>
  APPOINTMENT_STATUS_VALUES.map(status => ({
    icon: APPOINTMENT_STATUS_ICONS[status],
    iconClass: APPOINTMENT_STATUS_ICON_CLASSES[status],
    label: appointmentStatusLabels.value[status] || status,
    labelClass: APPOINTMENT_STATUS_ICON_CLASSES[status],
    value: status,
  }))
);

const activeResources = computed(() =>
  (
    schedulingReferencesStore.activeResources ||
    schedulingReferencesStore.resources ||
    []
  ).filter(resource => resource.active !== false)
);
const activeServices = computed(() =>
  (
    schedulingReferencesStore.activeServices ||
    schedulingReferencesStore.services ||
    []
  ).filter(service => service.active !== false)
);
const resourceOptions = computed(() =>
  activeResources.value.map(resource => ({
    label: resource.specialty
      ? `${resource.name} · ${resource.specialty}`
      : resource.name,
    value: resource.id,
  }))
);
const serviceOptions = computed(() =>
  activeServices.value.map(service => ({
    label: service.name,
    wrapLabel: true,
    value: service.id,
  }))
);
const hasServiceOptions = computed(() => serviceOptions.value.length > 0);
const serviceOptionsForForm = form => {
  const resource = activeResources.value.find(
    item => Number(item.id) === Number(form?.resourceId)
  );

  return servicesAvailableForResource(activeServices.value, resource).map(
    service => ({
      label: service.name,
      value: service.id,
      wrapLabel: true,
    })
  );
};
const hasServiceOptionsForForm = form => serviceOptionsForForm(form).length > 0;

const contact = computed(() => resolveChatContact(props.currentChat));
const contactId = computed(() => resolveChatContactId(props.currentChat));
// The chat owner remains the recipient. Only clinical context changes here.
const patient = computed(() =>
  props.patientContextEnabled ? props.selectedPatient : contact.value
);
const selectedPatientContextId = computed(() =>
  patientContactId(
    props.patientContextEnabled ? patient.value?.id : contactId.value
  )
);
const selectedPatientCardId = computed(() =>
  props.patientContextEnabled && patient.value?.selectable_patient
    ? patientContactId(patient.value?.patient_contact_id)
    : null
);
const patientContextReady = computed(
  () =>
    !props.patientContextEnabled ||
    (!props.patientContextLoading && Boolean(selectedPatientContextId.value))
);
const currentDraftKey = computed(() =>
  props.patientContextEnabled &&
  props.patientContextKey &&
  selectedPatientContextId.value
    ? `${props.patientContextKey}:${selectedPatientContextId.value}`
    : ''
);
let activeDraftKey = currentDraftKey.value;
const accountId = computed(() => String(route.params?.accountId || ''));

const createConversationDisplayId = computed(() => {
  const ids = [
    props.currentChat?.active_reply_channel?.conversation_id,
    props.currentChat?.active_reply_channel_conversation_id,
    ...(props.currentChat?.conversation_ids || []),
    ...(props.currentChat?.conversationIds || []),
    props.currentChat?.is_communication_thread ? null : props.currentChat?.id,
  ];

  return (
    ids.map(id => Number(id)).find(id => Number.isFinite(id) && id > 0) || null
  );
});

const contactName = computed(
  () =>
    patient.value?.name ||
    patient.value?.fullName ||
    patient.value?.full_name ||
    ''
);
const contactPhone = computed(
  () =>
    patient.value?.phone_number ||
    patient.value?.phoneNumber ||
    patient.value?.phone ||
    (props.patientContextEnabled
      ? contact.value?.phone_number ||
        contact.value?.phoneNumber ||
        contact.value?.phone
      : '') ||
    ''
);

const normalizePatientIin = value => String(value || '').replace(/\D/g, '');
const isValidPatientIin = value => {
  const iin = normalizePatientIin(value);
  if (!/^\d{12}$/.test(iin)) return false;

  const digits = [...iin].map(Number);
  const checksum = weights =>
    weights.reduce((sum, weight, index) => sum + weight * digits[index], 0) %
    11;
  // Keep the same two-pass checksum as Scheduling::IinValidator.
  const first = checksum([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]);
  const result =
    first === 10 ? checksum([3, 4, 5, 6, 7, 8, 9, 10, 11, 1, 2]) : first;
  return (result === 10 ? 0 : result) === digits[11];
};
const contactIin = computed(() => {
  const attributes =
    patient.value?.custom_attributes || patient.value?.customAttributes || {};
  const value = [
    attributes.medelement_iin,
    attributes.medelementIin,
    attributes.iin,
    patient.value?.identifier,
  ].find(isValidPatientIin);
  return value ? normalizePatientIin(value) : '';
});

const fullPatientName = form =>
  [form?.clientFirstName, form?.clientLastName, form?.clientMiddleName]
    .map(value => String(value || '').trim())
    .filter(Boolean)
    .join(' ');

const updatePatientIin = (form, value) => {
  form.clientIdentifier = value;
  form.clientIdentifierInferred = false;
};

const updatePatientNamePart = (form, field, value) => {
  if (form[field] !== value && form.clientIdentifierInferred) {
    form.clientIdentifier = '';
    form.clientIdentifierInferred = false;
  }
  form[field] = value;
  form.clientName = fullPatientName(form);
  form.clientNameStructured = true;
};

const patientNameParts = source => {
  if (
    source?.clientFirstName ||
    source?.clientLastName ||
    source?.clientMiddleName
  ) {
    return {
      clientFirstName: source.clientFirstName || '',
      clientLastName: source.clientLastName || '',
      clientMiddleName: source.clientMiddleName || '',
      clientNameStructured: true,
    };
  }

  return {
    clientFirstName: String(source?.clientName || '').trim(),
    clientLastName: '',
    clientMiddleName: '',
    clientNameStructured: false,
  };
};

const buildDefaultAppointmentTimes = () => {
  const startsAt = new Date();
  startsAt.setMinutes(Math.ceil(startsAt.getMinutes() / 5) * 5, 0, 0);

  const endsAt = new Date(startsAt);
  const primaryResource = activeResources.value[0];
  endsAt.setMinutes(
    endsAt.getMinutes() +
      Math.max(Number(primaryResource?.slotDurationMin) || 30, 5)
  );

  return {
    endsAt: toClinicDateTime(endsAt),
    startsAt: toClinicDateTime(startsAt),
  };
};

const resetCreateForm = () => {
  const primaryResource = activeResources.value[0];
  const primaryResourceCabinets =
    medelementCabinetsForResource(primaryResource);
  const defaults = buildDefaultAppointmentTimes();
  const contactNameParts = schedulingContactNameParts({
    firstName: patient.value?.first_name || patient.value?.firstName,
    fullName: contactName.value,
    lastName: patient.value?.last_name || patient.value?.lastName,
    middleName: patient.value?.middle_name || patient.value?.middleName,
  });

  Object.assign(createForm, {
    clientBirthDate: patientBirthDate(patient.value),
    clientGender: patient.value?.gender || '',
    clientIdentifier: contactIin.value,
    clientIdentifierInferred: Boolean(contactIin.value),
    clientFirstName: contactNameParts.firstName,
    clientLastName: contactNameParts.lastName,
    clientMiddleName: contactNameParts.middleName,
    clientName: contactName.value,
    clientNameStructured: true,
    clientPhone: contactPhone.value,
    patientContactId: selectedPatientCardId.value,
    patientContextContactId: selectedPatientContextId.value,
    endsAt: defaults.endsAt,
    medelementCabinetCode:
      primaryResourceCabinets.length === 1
        ? primaryResourceCabinets[0].code
        : '',
    resourceId: primaryResource?.id || '',
    serviceAmount: '',
    serviceId: '',
    serviceNameSnapshot: '',
    startsAt: defaults.startsAt,
    status: 'scheduled',
  });
};

const selectedCreateService = computed(() =>
  activeServices.value.find(
    service => Number(service.id) === Number(createForm.serviceId)
  )
);

const selectedCreateResource = computed(() =>
  activeResources.value.find(
    resource => Number(resource.id) === Number(createForm.resourceId)
  )
);
const selectedCreateMedelementCabinets = computed(() =>
  medelementCabinetsForResource(selectedCreateResource.value)
);
const medelementCabinetOptions = computed(() =>
  selectedCreateMedelementCabinets.value.map(cabinet => ({
    label:
      [cabinet.name, cabinet.number].filter(Boolean).join(' · ') ||
      cabinet.code,
    value: cabinet.code,
  }))
);

const conversationDisplayIds = computed(() => {
  const ids = [
    props.currentChat?.id,
    ...(props.currentChat?.conversation_ids || []),
    ...(props.currentChat?.conversationIds || []),
  ];

  return [
    ...new Set(
      ids.map(id => Number(id)).filter(id => Number.isFinite(id) && id > 0)
    ),
  ];
});

const lookupParams = computed(() => {
  if (props.patientContextEnabled) {
    return patientContextReady.value
      ? [{ patient_contact_ids: selectedPatientContextId.value }]
      : [];
  }
  const params = [];

  if (contactId.value) {
    params.push({ contact_ids: contactId.value });
  }

  if (conversationDisplayIds.value.length) {
    params.push({
      conversation_display_ids: conversationDisplayIds.value.join(','),
    });
  }

  return params;
});

const PATIENT_ACTION_STATUSES = new Set([
  'awaiting_patient_creation',
  'awaiting_patient_selection',
  'awaiting_phone_refresh',
]);
const hasPatientAction = command =>
  PATIENT_ACTION_STATUSES.has(command?.status) ||
  providerCommandRequiresPatientSelection(command);

const appointmentKey = appointment => `appointment-${appointment.id}`;
const invalidatePatientAction = key => {
  patientActionLookupIds[key] = (patientActionLookupIds[key] || 0) + 1;
  delete patientActions[key];
  if (patientActionBusyKey.value === key) {
    patientActionRequestId.value += 1;
    patientActionBusyKey.value = '';
    providerCommandsStore.ui.operationId += 1;
    providerCommandsStore.ui.isExecuting = false;
    providerCommandsStore.ui.error = null;
  }
};
const APPOINTMENT_PROVIDER_FORM_INTENT_FIELDS = [
  'clientBirthDate',
  'clientGender',
  'clientFirstName',
  'clientIdentifier',
  'clientLastName',
  'clientMiddleName',
  'clientPhone',
  'patientContactId',
  'endsAt',
  'medelementCabinetCode',
  'resourceId',
  'serviceId',
  'startsAt',
  'status',
];
const providerFormIntentFingerprint = form =>
  JSON.stringify(
    APPOINTMENT_PROVIDER_FORM_INTENT_FIELDS.map(field =>
      String(form?.[field] ?? '').trim()
    )
  );
const appointmentProviderFormIntent = appointment => {
  const nameParts = patientNameParts(appointment);
  return {
    clientBirthDate: appointment?.clientBirthDate || '',
    clientGender: appointment?.clientGender || '',
    clientFirstName: nameParts.clientFirstName,
    clientIdentifier: appointment?.clientIdentifier || '',
    clientLastName: nameParts.clientLastName,
    clientMiddleName: nameParts.clientMiddleName,
    clientPhone: appointment?.clientPhone || '',
    patientContactId: patientContactId(appointment?.patientContactId),
    endsAt: toClinicDateTime(appointment?.endsAt),
    medelementCabinetCode:
      appointment?.customAttributes?.medelementCabinetCode ||
      appointment?.customAttributes?.medelement_cabinet_code ||
      appointment?.custom_attributes?.medelement_cabinet_code ||
      '',
    resourceId: appointment?.resourceId || '',
    serviceId: appointment?.serviceId || '',
    startsAt: toClinicDateTime(appointment?.startsAt),
    status: appointment?.status || 'scheduled',
  };
};
const isAppointmentProviderFormUnchanged = appointment => {
  const form = appointmentForms[appointmentKey(appointment)];
  return (
    providerFormIntentFingerprint(form) ===
    providerFormIntentFingerprint(appointmentProviderFormIntent(appointment))
  );
};
const appointmentContextFingerprint = appointment =>
  JSON.stringify([
    appointment?.id,
    appointment?.resourceId,
    appointment?.serviceId,
    appointment?.startsAt,
    appointment?.endsAt,
    appointment?.status,
    appointment?.source,
    appointment?.contactId,
    appointment?.conversationId,
    appointment?.conversationDisplayId,
    appointment?.patientContactId,
    appointment?.clientIdentifier,
    appointment?.clientPhone,
    appointment?.clientName,
    appointment?.clientFirstName,
    appointment?.clientLastName,
    appointment?.clientMiddleName,
    appointment?.customAttributes?.medelementCabinetCode ||
      appointment?.customAttributes?.medelement_cabinet_code ||
      appointment?.custom_attributes?.medelement_cabinet_code ||
      appointment?.custom_attributes?.medelementCabinetCode ||
      '',
  ]);
const captureSidebarContext = () => ({
  accountId: accountId.value,
  chatId: String(props.currentChat?.id || ''),
  contactId: String(contactId.value || ''),
  conversationIds: conversationDisplayIds.value.join(','),
  patientContextId: selectedPatientContextId.value,
  patientContextKey: props.patientContextKey,
  generation: providerReviewGeneration,
});
const isCurrentSidebarContext = context =>
  !sidebarDisposed &&
  context.generation === providerReviewGeneration &&
  context.accountId === accountId.value &&
  context.chatId === String(props.currentChat?.id || '') &&
  context.contactId === String(contactId.value || '') &&
  context.patientContextId === selectedPatientContextId.value &&
  context.patientContextKey === props.patientContextKey &&
  patientContextReady.value &&
  context.conversationIds === conversationDisplayIds.value.join(',');
const captureProviderContext = appointment => ({
  ...captureSidebarContext(),
  appointmentId: Number(appointment?.id),
  appointmentFingerprint: appointmentContextFingerprint(appointment),
});
const isCurrentProviderContext = context => {
  if (!isCurrentSidebarContext(context)) return false;

  const currentAppointment = appointments.value.find(
    item => Number(item.id) === context.appointmentId
  );
  return (
    currentAppointment &&
    appointmentContextFingerprint(currentAppointment) ===
      context.appointmentFingerprint
  );
};
const appointmentResource = appointment =>
  activeResources.value.find(
    resource => Number(resource.id) === Number(appointment?.resourceId)
  );
const isMedelementAppointment = appointment =>
  isMedelementResource(appointmentResource(appointment));
const isPatientActionPendingOnAppointment = appointment =>
  appointment?.status !== 'cancelled' &&
  !providerCancellationPending(appointment) &&
  (PATIENT_ACTION_STATUSES.has(
    appointment?.providerConfirmationStatus ||
      appointment?.customAttributes?.medelement_provider_sync_status ||
      appointment?.custom_attributes?.medelement_provider_sync_status
  ) ||
    (appointment?.providerConfirmationStatus ||
      appointment?.customAttributes?.medelement_provider_sync_status ||
      appointment?.custom_attributes?.medelement_provider_sync_status) ===
      'pending');
const patientActionTitle = entry => {
  const status = entry?.command?.status;
  if (providerCommandRequiresPatientSelection(entry?.command)) {
    return t('SCHEDULING.MEDELEMENT.PATIENT_SELECTION_TITLE');
  }
  if (status === 'awaiting_patient_creation') {
    return t('SCHEDULING.MEDELEMENT.PATIENT_CREATION_TITLE');
  }
  if (status === 'awaiting_phone_refresh') {
    return t('SCHEDULING.MEDELEMENT.PHONE_REFRESH_TITLE');
  }
  if (status === 'succeeded') return t('SCHEDULING.MEDELEMENT.SUCCESS');
  if (
    status === 'provider_status_unknown' ||
    status === 'v2_provider_status_unknown'
  ) {
    return entry?.appointment?.status === 'cancelled'
      ? t('SCHEDULING.APPOINTMENT_STATUS.CANCELLATION_REVIEW')
      : t('SCHEDULING.APPOINTMENT_STATUS.PROVIDER_REVIEW');
  }
  if (
    status === 'reconciliation_required' ||
    status === 'v2_reconciliation_required' ||
    ['queued', 'processing', 'awaiting_confirmation', 'pending'].includes(
      status
    )
  ) {
    return t('SCHEDULING.MEDELEMENT.RECONCILING');
  }
  if (status === 'cancelled') {
    return t('SCHEDULING.APPOINTMENT_STATUS.CANCELLATION_REVIEW');
  }
  if (['failed', 'declined'].includes(status)) {
    return t('SCHEDULING.MEDELEMENT.FAILED', {
      code: entry.command.lastErrorCode || status,
    });
  }

  return entry?.appointment
    ? providerBookingStatusMessage(entry.appointment, t) ||
        t('SCHEDULING.APPOINTMENT_STATUS.PROVIDER_REVIEW')
    : t('SCHEDULING.MEDELEMENT.RECONCILING');
};
const patientActionDescription = entry => {
  const { command, candidates = [] } = entry || {};
  const appointment = appointments.value.find(
    item => Number(item.id) === Number(entry?.context?.appointmentId)
  );
  if (
    entry?.intentMismatch ||
    (appointment && !isAppointmentProviderFormUnchanged(appointment))
  ) {
    return t('SCHEDULING.MEDELEMENT.STALE_COMMAND_DESCRIPTION');
  }
  if (providerCommandRequiresPatientSelection(command)) {
    if (command.patientAction?.requiresPatientCardConfirmation) {
      return t('SCHEDULING.PATIENT_CONTEXT.CONFIRM_PATIENT_CARD');
    }
    return t('SCHEDULING.MEDELEMENT.PATIENT_SELECTION_DESCRIPTION', {
      count: command.patientAction?.candidateCount || candidates.length || 0,
    });
  }
  if (command?.status === 'awaiting_patient_creation') {
    const missingFields = command.patientAction?.missingFields || [];
    return missingFields.length
      ? t('SCHEDULING.MEDELEMENT.PATIENT_CREATION_INCOMPLETE', {
          fields: missingFields.join(', '),
        })
      : t('SCHEDULING.MEDELEMENT.PATIENT_CREATION_DESCRIPTION');
  }
  if (command?.status === 'awaiting_phone_refresh') {
    return t('SCHEDULING.MEDELEMENT.PHONE_REFRESH_UNSUPPORTED');
  }
  return entry?.error || '';
};
const patientActionButtonLabel = entry => {
  const status = entry?.command?.status;
  if (providerCommandRequiresPatientSelection(entry?.command)) {
    return t('SCHEDULING.MEDELEMENT.PATIENT_SELECT_ACTION');
  }
  if (status === 'awaiting_patient_creation') {
    return t('SCHEDULING.MEDELEMENT.PATIENT_CREATE_ACTION');
  }
  if (status === 'awaiting_phone_refresh') {
    return t('SCHEDULING.MEDELEMENT.PHONE_RETRY_ACTION');
  }
  return '';
};
const canContinuePatientAction = entry => {
  const appointment = appointments.value.find(
    item => Number(item.id) === Number(entry?.context?.appointmentId)
  );
  const key = appointment ? appointmentKey(appointment) : '';
  if (
    !entry ||
    patientActionBusyKey.value ||
    providerCommandsStore.ui.isExecuting ||
    entry.intentMismatch ||
    !appointment ||
    checkingAppointmentKey.value === key ||
    savingAppointmentKey.value === key ||
    cancellingAppointmentKey.value === key ||
    !isAppointmentProviderFormUnchanged(appointment)
  ) {
    return false;
  }

  if (providerCommandRequiresPatientSelection(entry.command)) {
    return Boolean(
      entry.selectedPatientToken &&
        entry.candidates.some(
          candidate => candidate.token === entry.selectedPatientToken
        )
    );
  }
  if (entry.command?.status === 'awaiting_patient_creation') {
    return entry.command.patientAction?.canConfirm === true;
  }
  return entry.command?.status === 'awaiting_phone_refresh';
};
const isProviderCancellationPending = appointment =>
  (isAppointmentProviderOwned(appointment) &&
    appointment?.providerConfirmationStatus === 'pending') ||
  providerCancellationPending(appointment);
const isAppointmentOpen = appointment =>
  openAppointmentKeys.value.includes(appointmentKey(appointment));

const statusIconClass = appointment =>
  providerBookingNeedsReview(appointment)
    ? 'text-n-ruby-11'
    : (APPOINTMENT_STATUS_ICON_CLASSES[appointment.status] ??
      APPOINTMENT_STATUS_ICON_CLASSES.scheduled);

const statusIcon = appointment =>
  providerBookingNeedsReview(appointment)
    ? 'i-lucide-circle-alert'
    : APPOINTMENT_STATUS_ICONS[appointment.status] ||
      APPOINTMENT_STATUS_ICONS.scheduled;

const parseTimestamp = value => Date.parse(value || '') || 0;

const sortAppointmentsForDialog = items => {
  return [...items].sort((left, right) => {
    const leftTime = parseTimestamp(left.startsAt);
    const rightTime = parseTimestamp(right.startsAt);
    return rightTime - leftTime;
  });
};

const mergeUniqueAppointments = (...collections) => {
  const byId = new Map();
  collections.flat().forEach(appointment => {
    if (appointment?.id) {
      byId.set(String(appointment.id), appointment);
    }
  });

  return sortAppointmentsForDialog([...byId.values()]);
};

const formFromAppointment = appointment => {
  const nameParts = patientNameParts(appointment);
  return {
    appointmentType: appointment.appointmentType || 'primary',
    clientBirthDate: appointment.clientBirthDate || '',
    clientGender: appointment.clientGender || '',
    clientIdentifier: appointment.clientIdentifier || '',
    clientIdentifierInferred: false,
    ...nameParts,
    clientName: appointment.clientName || '',
    clientPhone: appointment.clientPhone || '',
    patientContactId: patientContactId(appointment.patientContactId),
    patientContextContactId: patientContactId(
      appointment.patientContextContactId ||
        appointment.patientContactId ||
        appointment.contactId
    ),
    contactId: appointment.contactId || contactId.value || '',
    conversationDisplayId:
      appointment.conversationDisplayId ||
      createConversationDisplayId.value ||
      '',
    conversationId: appointment.conversationId || '',
    endsAt: toClinicDateTime(appointment.endsAt),
    medelementCabinetCode:
      appointment.customAttributes?.medelementCabinetCode ||
      appointment.customAttributes?.medelement_cabinet_code ||
      '',
    resourceId: appointment.resourceId || '',
    serviceAmount:
      appointment.serviceAmount === null ||
      typeof appointment.serviceAmount === 'undefined'
        ? ''
        : String(appointment.serviceAmount),
    serviceId: appointment.serviceId || '',
    serviceNameSnapshot: appointment.serviceNameSnapshot || '',
    startsAt: toClinicDateTime(appointment.startsAt),
    status: appointment.status || 'scheduled',
  };
};

const setAppointmentForms = () => {
  Object.keys(appointmentForms).forEach(key => delete appointmentForms[key]);
  appointments.value.forEach(appointment => {
    appointmentForms[appointmentKey(appointment)] =
      formFromAppointment(appointment);
  });
};

const rememberPatientDraft = () => {
  if (!activeDraftKey || (!isCreating.value && !appointments.value.length))
    return;
  patientContextStore.saveDraft(activeDraftKey, {
    createForm: isCreating.value ? createForm : null,
    appointmentForms: Object.fromEntries(
      appointments.value.map(appointment => [
        appointmentKey(appointment),
        {
          form: appointmentForms[appointmentKey(appointment)],
          fingerprint: appointmentContextFingerprint(appointment),
        },
      ])
    ),
  });
};

const restorePatientDraft = () => {
  if (!patientContextReady.value || !currentDraftKey.value) return false;
  const draft = patientContextStore.drafts[currentDraftKey.value];
  if (!draft) return false;
  appointments.value.forEach(appointment => {
    const key = appointmentKey(appointment);
    const saved = draft.appointmentForms?.[key];
    if (saved?.fingerprint === appointmentContextFingerprint(appointment)) {
      appointmentForms[key] = { ...saved.form };
    }
  });
  if (
    draft.createForm &&
    draft.createForm.patientContextContactId ===
      selectedPatientContextId.value &&
    draft.createForm.patientContactId === selectedPatientCardId.value
  ) {
    Object.assign(createForm, draft.createForm);
    isCreating.value = true;
    openAppointmentKeys.value = [
      NEW_APPOINTMENT_KEY,
      ...openAppointmentKeys.value,
    ];
    return true;
  }
  return false;
};

const selectedServiceForForm = form =>
  activeServices.value.find(
    service => Number(service.id) === Number(form?.serviceId)
  );

const selectedResourceForForm = form =>
  activeResources.value.find(
    resource => Number(resource.id) === Number(form?.resourceId)
  );

const medelementCabinetOptionsForForm = form =>
  medelementCabinetsForResource(selectedResourceForForm(form)).map(cabinet => ({
    label:
      [cabinet.name, cabinet.number].filter(Boolean).join(' · ') ||
      cabinet.code,
    value: cabinet.code,
  }));

const updateFormEndFromDuration = form => {
  if (!form?.startsAt) return;
  if (Number.isNaN(new Date(form.startsAt).getTime())) return;

  const durationMin = Math.max(
    Number(selectedServiceForForm(form)?.durationMin) ||
      Number(selectedResourceForForm(form)?.slotDurationMin) ||
      30,
    5
  );
  form.endsAt = addMinutesToDateTimeInputValue(
    form.startsAt,
    durationMin,
    SCHEDULING_TIMEZONE
  );
};

const syncFormServiceFields = form => {
  if (selectedServiceForForm(form)) {
    const price = getServicePriceForResource(
      selectedServiceForForm(form),
      form.resourceId
    );
    form.serviceAmount = price ? String(price) : form.serviceAmount;
  }
  updateFormEndFromDuration(form);
};

const handleFormResourceChange = (form, value) => {
  form.resourceId = value;
  const cabinets = medelementCabinetsForResource(selectedResourceForForm(form));
  form.medelementCabinetCode = cabinets.length === 1 ? cabinets[0].code : '';
  if (
    !serviceOptionsForForm(form).some(
      option => Number(option.value) === Number(form.serviceId)
    )
  ) {
    form.serviceId = '';
    form.serviceNameSnapshot = '';
  }
  syncFormServiceFields(form);
};

const handleFormServiceChange = (form, value) => {
  form.serviceId = value;
  form.serviceNameSnapshot = '';
  syncFormServiceFields(form);
};

const selectedServiceIdForPayload = serviceId =>
  hasServiceOptions.value ? toNumeric(serviceId) : undefined;

const appendServicePayload = (payload, { serviceId, serviceNameSnapshot }) => {
  const selectedServiceId = selectedServiceIdForPayload(serviceId);
  const servicePayload = compactPayload({
    ...payload,
    service_id: selectedServiceId,
    service_ids: selectedServiceId ? [selectedServiceId] : undefined,
    service_name_snapshot: selectedServiceId ? undefined : serviceNameSnapshot,
  });

  if (!selectedServiceId) {
    servicePayload.service_ids = [];
  }
  if (Object.hasOwn(payload, 'client_identifier')) {
    servicePayload.client_identifier = payload.client_identifier;
  }
  if (Object.hasOwn(payload, 'client_first_name')) {
    servicePayload.client_last_name = payload.client_last_name?.trim() || null;
    servicePayload.client_middle_name =
      payload.client_middle_name?.trim() || null;
  }

  return servicePayload;
};

const appointmentFormEndsAfterStart = form => {
  if (!form?.startsAt || !form?.endsAt) return false;

  return new Date(form.endsAt) > new Date(form.startsAt);
};

const medelementLastNameError = form =>
  isMedelementResource(selectedResourceForForm(form)) &&
  !form?.clientLastName?.trim()
    ? t('SCHEDULING.APPOINTMENT_FORM.ERRORS.MEDELEMENT_LAST_NAME_REQUIRED')
    : '';

const medelementPhoneError = form =>
  isMedelementResource(selectedResourceForForm(form)) &&
  !isKazakhstanE164Phone(form?.clientPhone)
    ? t('SCHEDULING.APPOINTMENT_FORM.ERRORS.MEDELEMENT_PHONE_REQUIRED')
    : '';

const medelementIinError = form => {
  if (
    !isMedelementResource(selectedResourceForForm(form)) ||
    !form?.clientIdentifier?.trim()
  ) {
    return '';
  }
  const iin = normalizePatientIin(form.clientIdentifier);
  if (!/^\d{12}$/.test(iin)) {
    return t('SCHEDULING.CONTACT.IIN_ERROR_LENGTH');
  }
  return isValidPatientIin(iin) ? '' : t('SCHEDULING.ERRORS.INVALID_IIN');
};

const medelementServiceError = form =>
  isMedelementResource(selectedResourceForForm(form)) &&
  form?.serviceId &&
  !serviceOptionsForForm(form).some(
    option => Number(option.value) === Number(form?.serviceId)
  )
    ? t('SCHEDULING.APPOINTMENT_FORM.ERRORS.MEDELEMENT_SERVICE_REQUIRED')
    : '';

const medelementCabinetError = form =>
  isMedelementResource(selectedResourceForForm(form)) &&
  !form?.medelementCabinetCode
    ? t('SCHEDULING.MEDELEMENT.CABINET_REQUIRED')
    : '';

const isAppointmentFormInvalid = form =>
  !patientContextReady.value ||
  (props.patientContextEnabled &&
    form?.patientContextContactId !== selectedPatientContextId.value) ||
  !contactId.value ||
  !form?.clientFirstName?.trim() ||
  Boolean(medelementLastNameError(form)) ||
  Boolean(medelementPhoneError(form)) ||
  Boolean(medelementIinError(form)) ||
  Boolean(medelementServiceError(form)) ||
  Boolean(medelementCabinetError(form)) ||
  !form?.resourceId ||
  !form?.startsAt ||
  !form?.endsAt ||
  !appointmentFormEndsAfterStart(form);

const buildAppointmentPayload = form =>
  appendServicePayload(
    {
      appointment_type: form.appointmentType || 'primary',
      ...(form.clientNameStructured
        ? {
            client_first_name: form.clientFirstName,
            client_last_name: form.clientLastName,
            client_middle_name: form.clientMiddleName,
          }
        : {}),
      client_name: fullPatientName(form),
      client_birth_date: form.clientBirthDate || undefined,
      client_gender: form.clientGender || undefined,
      client_phone: form.clientPhone,
      ...(isMedelementResource(selectedResourceForForm(form))
        ? {
            client_identifier:
              normalizePatientIin(form.clientIdentifier) || null,
          }
        : {}),
      contact_id: toNumeric(form.contactId || contactId.value),
      ...(patientContactId(form.patientContactId)
        ? { patient_contact_id: patientContactId(form.patientContactId) }
        : {}),
      conversation_display_id: toNumeric(
        form.conversationId
          ? null
          : form.conversationDisplayId || createConversationDisplayId.value
      ),
      conversation_id: toNumeric(form.conversationId),
      custom_attributes: form.medelementCabinetCode
        ? { medelement_cabinet_code: form.medelementCabinetCode }
        : undefined,
      ends_at: fromClinicDateTime(form.endsAt),
      resource_id: toNumeric(form.resourceId),
      service_amount:
        toIntegerNumeric(form.serviceAmount || 0, 'service_amount') || 0,
      source: 'conversation',
      starts_at: fromClinicDateTime(form.startsAt),
      status: form.status || 'scheduled',
    },
    {
      serviceId: form.serviceId,
      serviceNameSnapshot: form.serviceNameSnapshot,
    }
  );

const buildCreatePayload = () =>
  appendServicePayload(
    {
      appointment_type: 'primary',
      ...(createForm.clientNameStructured
        ? {
            client_first_name: createForm.clientFirstName,
            client_last_name: createForm.clientLastName,
            client_middle_name: createForm.clientMiddleName,
          }
        : {}),
      client_name: fullPatientName(createForm),
      client_birth_date: createForm.clientBirthDate || undefined,
      client_gender: createForm.clientGender || undefined,
      client_phone: createForm.clientPhone,
      ...(isMedelementResource(selectedResourceForForm(createForm))
        ? {
            client_identifier:
              normalizePatientIin(createForm.clientIdentifier) || null,
          }
        : {}),
      contact_id: toNumeric(contactId.value),
      ...(patientContactId(createForm.patientContactId)
        ? { patient_contact_id: patientContactId(createForm.patientContactId) }
        : {}),
      conversation_display_id: toNumeric(createConversationDisplayId.value),
      ...(createForm.medelementCabinetCode
        ? {
            custom_attributes: {
              medelement_cabinet_code: createForm.medelementCabinetCode,
            },
          }
        : {}),
      ends_at: fromClinicDateTime(createForm.endsAt),
      resource_id: toNumeric(createForm.resourceId),
      service_amount:
        toIntegerNumeric(createForm.serviceAmount || 0, 'service_amount') || 0,
      source: 'conversation',
      starts_at: fromClinicDateTime(createForm.startsAt),
      status: createForm.status || 'scheduled',
    },
    {
      serviceId: createForm.serviceId,
      serviceNameSnapshot: createForm.serviceNameSnapshot,
    }
  );

const upsertAppointment = appointment => {
  const key = appointmentKey(appointment);
  const existingAppointment = appointments.value.find(
    item => Number(item.id) === Number(appointment.id)
  );
  if (
    existingAppointment &&
    appointmentContextFingerprint(existingAppointment) !==
      appointmentContextFingerprint(appointment)
  ) {
    invalidatePatientAction(key);
  }

  appointments.value = mergeUniqueAppointments(appointments.value, [
    appointment,
  ]);
  appointmentForms[appointmentKey(appointment)] =
    formFromAppointment(appointment);
};

const refreshSidebarCounters = () => {
  Promise.allSettled([store.dispatch('fetchSidebarUnreadCounts')]);
};

const fetchAppointmentsByParams = async params => {
  if (!params) return [];

  const response = await SchedulingAppointmentsAPI.get(params);
  return normalizePayload(response.data);
};

const beginPatientActionLookup = key => {
  patientActionLookupIds[key] = (patientActionLookupIds[key] || 0) + 1;
  return patientActionLookupIds[key];
};
const isCurrentPatientActionLookup = (key, context, lookupId) =>
  isCurrentProviderContext(context) && patientActionLookupIds[key] === lookupId;
const COMMANDS_WAITING_FOR_PROVIDER = new Set([
  'awaiting_confirmation',
  'pending',
  'processing',
  'queued',
]);
const COMMANDS_NEEDING_RECONCILIATION = new Set([
  'provider_status_unknown',
  'reconciliation_required',
  'v2_provider_status_unknown',
  'v2_reconciliation_required',
]);

async function showPatientAction(appointment, command, context, lookupId) {
  const key = appointmentKey(appointment);
  if (
    !isCurrentProviderContext(context) ||
    (lookupId && !isCurrentPatientActionLookup(key, context, lookupId)) ||
    Number(command.appointmentId || command.appointment_id) !==
      Number(appointment.id) ||
    !hasPatientAction(command)
  ) {
    return null;
  }

  const expectedIntent = buildMedelementProviderCommandParams({
    appointment,
    companyCabinetCode: resolveAppointmentMedelementCabinetCode(
      appointment,
      activeResources.value
    ),
    operation: command.operation,
  });
  const entry = reactive({
    command,
    context,
    appointment,
    lookupId,
    expectedIntent,
    intentMismatch: !providerCommandIntentMatches(expectedIntent, command),
    candidates: [],
    selectedPatientToken: '',
    error: '',
    loadingCandidates: false,
  });
  patientActions[key] = entry;

  if (
    providerCommandRequiresPatientSelection(command) &&
    !entry.intentMismatch
  ) {
    entry.loadingCandidates = true;
    try {
      const payload =
        await providerCommandsStore.loadPatientCandidates(command);
      if (
        !isCurrentProviderContext(context) ||
        patientActions[key] !== entry ||
        (lookupId && !isCurrentPatientActionLookup(key, context, lookupId))
      ) {
        return null;
      }
      entry.candidates = payload?.candidates || [];
    } catch (error) {
      if (
        isCurrentProviderContext(context) &&
        patientActions[key] === entry &&
        (!lookupId || isCurrentPatientActionLookup(key, context, lookupId))
      ) {
        entry.error = formatSchedulingErrorMessage(error, t);
      }
    } finally {
      if (
        isCurrentProviderContext(context) &&
        patientActions[key] === entry &&
        (!lookupId || isCurrentPatientActionLookup(key, context, lookupId))
      ) {
        entry.loadingCandidates = false;
      }
    }
  }

  return entry;
}

const showProviderCommandWaiting = (
  appointment,
  context,
  lookupId,
  command = null
) => {
  const key = appointmentKey(appointment);
  if (!isCurrentPatientActionLookup(key, context, lookupId)) return null;

  const expectedIntent = command
    ? buildMedelementProviderCommandParams({
        appointment,
        companyCabinetCode: resolveAppointmentMedelementCabinetCode(
          appointment,
          activeResources.value
        ),
        operation: command.operation,
      })
    : null;
  const entry = reactive({
    command: command || { status: 'pending' },
    context,
    appointment,
    lookupId,
    expectedIntent,
    intentMismatch: Boolean(
      command && !providerCommandIntentMatches(expectedIntent, command)
    ),
    candidates: [],
    selectedPatientToken: '',
    error: '',
    loadingCandidates: false,
  });
  patientActions[key] = entry;
  return entry;
};

async function refreshProviderAppointmentState(
  appointment,
  context,
  isCurrent = () => isCurrentProviderContext(context)
) {
  try {
    const response = await SchedulingAppointmentsAPI.show(appointment.id);
    if (!isCurrent()) return null;

    const refreshed = normalizePayload(response.data);
    if (Number(refreshed?.id) !== Number(appointment.id)) return null;

    const currentAppointment = appointments.value.find(
      item => Number(item.id) === Number(appointment.id)
    );
    if (!currentAppointment) return null;

    const refreshedAttributes = refreshed.customAttributes || {};
    const providerStatus =
      refreshed.providerConfirmationStatus ||
      refreshedAttributes.medelementProviderSyncStatus ||
      refreshedAttributes.medelement_provider_sync_status;
    if (providerStatus) {
      currentAppointment.providerConfirmationStatus = providerStatus;
    }

    const providerAttributeKeys = [
      'medelement_provider_sync_status',
      'medelementProviderSyncStatus',
      'medelement_reception_code',
      'medelementReceptionCode',
    ];
    const updatedAttributes = { ...currentAppointment.customAttributes };
    providerAttributeKeys.forEach(attributeKey => {
      if (Object.hasOwn(refreshedAttributes, attributeKey)) {
        updatedAttributes[attributeKey] = refreshedAttributes[attributeKey];
      }
    });
    currentAppointment.customAttributes = updatedAttributes;
    if (refreshed.externalRef) {
      currentAppointment.externalRef = refreshed.externalRef;
    }
    return currentAppointment;
  } catch {
    // The provider result remains visible if the local appointment readback fails.
    return null;
  }
}

const refreshPendingProviderReadback = async (
  appointment,
  context,
  lookupId
) => {
  const key = appointmentKey(appointment);
  const isCurrentReadback = () =>
    isCurrentPatientActionLookup(key, context, lookupId);
  const refreshedAppointment = await refreshProviderAppointmentState(
    appointment,
    context,
    isCurrentReadback
  );
  if (!isCurrentReadback()) return null;

  const currentAppointment =
    refreshedAppointment ||
    appointments.value.find(item => Number(item.id) === Number(appointment.id));
  if (isPatientActionPendingOnAppointment(currentAppointment)) {
    showProviderCommandWaiting(currentAppointment, context, lookupId);
  } else {
    delete patientActions[key];
  }
  return currentAppointment || null;
};

async function refreshPendingPatientAction(
  appointment,
  context = captureProviderContext(appointment),
  lookupId = beginPatientActionLookup(appointmentKey(appointment))
) {
  if (
    !isMedelementAppointment(appointment) ||
    isAppointmentProviderOwned(appointment)
  ) {
    return null;
  }

  const key = appointmentKey(appointment);
  try {
    const response = await SchedulingProviderCommandsAPI.list({
      provider: 'medelement',
      appointmentId: appointment.id,
      activeOnly: true,
    });
    if (!isCurrentPatientActionLookup(key, context, lookupId)) return null;

    const commands = normalizePayload(response.data) || [];
    const command = commands.find(
      item => item.operation === 'create_reception' && hasPatientAction(item)
    );
    if (command) {
      return showPatientAction(appointment, command, context, lookupId);
    }

    const waitingCommand = commands.find(
      item =>
        item.operation === 'create_reception' &&
        (COMMANDS_WAITING_FOR_PROVIDER.has(item.status) ||
          COMMANDS_NEEDING_RECONCILIATION.has(item.status))
    );
    if (waitingCommand) {
      return showProviderCommandWaiting(
        appointment,
        context,
        lookupId,
        waitingCommand
      );
    }

    if (isPatientActionPendingOnAppointment(appointment)) {
      return refreshPendingProviderReadback(appointment, context, lookupId);
    }

    delete patientActions[key];
  } catch {
    // Keep local appointment saves usable when this read-only lookup fails.
  }
  return null;
}

const loadAppointments = async () => {
  if (sidebarDisposed) return false;
  loadRequestId += 1;
  const requestId = loadRequestId;
  const params = lookupParams.value;
  const lookupKey = JSON.stringify(params);
  const context = captureSidebarContext();
  const isCurrentRequest = () =>
    !sidebarDisposed &&
    requestId === loadRequestId &&
    isCurrentSidebarContext(context) &&
    lookupKey === JSON.stringify(lookupParams.value);

  if (!params.length) {
    appointments.value = [];
    setAppointmentForms();
    ui.isLoading = false;
    ui.error = null;
    return true;
  }

  ui.isLoading = true;
  ui.error = null;

  try {
    const results = await Promise.all(params.map(fetchAppointmentsByParams));
    if (!isCurrentRequest()) return false;
    appointments.value = mergeUniqueAppointments(...results);
    if (props.patientContextEnabled) {
      appointments.value = appointments.value.filter(
        appointment =>
          patientContactId(
            appointment.patientContextContactId ||
              appointment.patientContactId ||
              appointment.contactId
          ) === selectedPatientContextId.value
      );
    }
    setAppointmentForms();
    appointments.value
      .filter(
        appointment =>
          !isAppointmentProviderOwned(appointment) &&
          isMedelementAppointment(appointment) &&
          isPatientActionPendingOnAppointment(appointment)
      )
      .forEach(appointment => {
        refreshPendingPatientAction(appointment).catch(() => {});
      });
    const firstEditableAppointment = appointments.value.find(
      appointment => !isAppointmentProviderOwned(appointment)
    );
    openAppointmentKeys.value = firstEditableAppointment
      ? [appointmentKey(firstEditableAppointment)]
      : [];
  } catch (error) {
    if (!isCurrentRequest()) return false;
    ui.error = error;
  } finally {
    if (requestId === loadRequestId) ui.isLoading = false;
  }
  return true;
};

const toggleAppointment = appointment => {
  if (isAppointmentProviderOwned(appointment)) return;

  const key = appointmentKey(appointment);
  openAppointmentKeys.value = isAppointmentOpen(appointment)
    ? openAppointmentKeys.value.filter(item => item !== key)
    : [...openAppointmentKeys.value, key];
};

const scrollToTop = async () => {
  await nextTick();

  const scheduleFrame =
    typeof window !== 'undefined' && window.requestAnimationFrame
      ? window.requestAnimationFrame
      : callback => callback();
  scheduleFrame(() => {
    const container = scrollContainer.value;
    if (typeof container?.scrollTo === 'function') {
      container.scrollTo({ top: 0, behavior: 'smooth' });
    }
  });
};

const updateCreateEndFromDuration = () => {
  if (!createForm.startsAt) return;
  if (Number.isNaN(new Date(createForm.startsAt).getTime())) return;

  const durationMin = Math.max(
    Number(selectedCreateService.value?.durationMin) ||
      Number(selectedCreateResource.value?.slotDurationMin) ||
      30,
    5
  );
  createForm.endsAt = addMinutesToDateTimeInputValue(
    createForm.startsAt,
    durationMin,
    SCHEDULING_TIMEZONE
  );
};

const syncCreateServiceFields = () => {
  if (selectedCreateService.value) {
    const price = getServicePriceForResource(
      selectedCreateService.value,
      createForm.resourceId
    );
    createForm.serviceAmount = price ? String(price) : createForm.serviceAmount;
  }
  updateCreateEndFromDuration();
};

const handleCreateResourceChange = value => {
  createForm.resourceId = value;
  const cabinets = medelementCabinetsForResource(selectedCreateResource.value);
  createForm.medelementCabinetCode =
    cabinets.length === 1 ? cabinets[0].code : '';
  if (
    !serviceOptionsForForm(createForm).some(
      option => Number(option.value) === Number(createForm.serviceId)
    )
  ) {
    createForm.serviceId = '';
    createForm.serviceNameSnapshot = '';
  }
  syncCreateServiceFields();
};

const handleCreateServiceChange = value => {
  createForm.serviceId = value;
  createForm.serviceNameSnapshot = '';
  syncCreateServiceFields();
};

const startCreateAppointment = async ({ scroll = true } = {}) => {
  if (!patientContextReady.value) return;
  resetCreateForm();
  isCreating.value = true;
  if (!openAppointmentKeys.value.includes(NEW_APPOINTMENT_KEY)) {
    openAppointmentKeys.value = [
      NEW_APPOINTMENT_KEY,
      ...openAppointmentKeys.value,
    ];
  }
  if (scroll) await scrollToTop();
};

const cancelCreateAppointment = () => {
  if (!appointments.value.length) return;

  isCreating.value = false;
  patientContextStore.clearDraft(currentDraftKey.value);
  openAppointmentKeys.value = openAppointmentKeys.value.filter(
    key => key !== NEW_APPOINTMENT_KEY
  );
};

const createFormEndsAfterStart = computed(() =>
  appointmentFormEndsAfterStart(createForm)
);

const isCreateFormInvalid = computed(() =>
  isAppointmentFormInvalid(createForm)
);

const refreshDialogAppointments = savedAppointment => {
  upsertAppointment(savedAppointment);
  isCreating.value = false;
  openAppointmentKeys.value = [appointmentKey(savedAppointment)];
};

const saveCreateAppointment = async () => {
  if (isCreateFormInvalid.value) return;
  if (
    isSavingCreate.value ||
    savingAppointmentKey.value ||
    cancellingAppointmentKey.value ||
    patientActionBusyKey.value
  ) {
    return;
  }

  const context = captureSidebarContext();
  createSaveRequestId += 1;
  const requestId = createSaveRequestId;
  isSavingCreate.value = true;
  try {
    const response =
      await SchedulingAppointmentsAPI.create(buildCreatePayload());
    if (!isCurrentSidebarContext(context)) return;
    const savedAppointment = normalizePayload(response.data);
    patientContextStore.clearDraft(currentDraftKey.value);
    refreshDialogAppointments(savedAppointment);
    refreshPendingPatientAction(savedAppointment).catch(() => {});
    refreshSidebarCounters();
    useAlert(t('SCHEDULING.APPOINTMENT_FORM.SUCCESS_SAVE'));
    emit('patientBound', savedAppointment);
  } catch (error) {
    if (isCurrentSidebarContext(context)) {
      useAlert(formatSchedulingErrorMessage(error, t));
    }
  } finally {
    if (requestId === createSaveRequestId) isSavingCreate.value = false;
  }
};

async function cancelAppointment(appointment) {
  const key = appointmentKey(appointment);
  if (
    savingAppointmentKey.value ||
    cancellingAppointmentKey.value ||
    patientActionBusyKey.value
  ) {
    return;
  }

  const context = captureSidebarContext();
  appointmentCancellationRequestId += 1;
  const requestId = appointmentCancellationRequestId;
  cancellingAppointmentKey.value = key;
  try {
    const cancellationMode = appointment.medelementCancellationMode;
    const response = cancellationMode
      ? await SchedulingAppointmentsAPI.cancel(appointment.id, {
          medelement_cancellation_mode: cancellationMode,
        })
      : await SchedulingAppointmentsAPI.cancel(appointment.id);
    if (!isCurrentSidebarContext(context)) return;
    const savedAppointment = normalizePayload(response.data);
    upsertAppointment(savedAppointment);
    refreshSidebarCounters();
    useAlert(appointmentCancellationAlertMessage(savedAppointment, t));
  } catch (error) {
    if (isCurrentSidebarContext(context)) {
      useAlert(formatSchedulingErrorMessage(error, t));
    }
  } finally {
    if (requestId === appointmentCancellationRequestId) {
      cancellingAppointmentKey.value = '';
    }
  }
}

const selectPatientCandidate = (appointment, token) => {
  const entry = patientActions[appointmentKey(appointment)];
  if (
    !entry ||
    !isCurrentProviderContext(entry.context) ||
    !entry.candidates.some(candidate => candidate.token === token)
  ) {
    return;
  }
  entry.selectedPatientToken = token;
};

async function continuePatientAction(appointment) {
  const key = appointmentKey(appointment);
  const entry = patientActions[key];
  if (
    !entry ||
    !isCurrentProviderContext(entry.context) ||
    !canContinuePatientAction(entry)
  ) {
    return;
  }

  patientActionRequestId.value += 1;
  const requestId = patientActionRequestId.value;
  beginPatientActionLookup(key);
  patientActionBusyKey.value = key;
  entry.error = '';
  try {
    let command;
    if (providerCommandRequiresPatientSelection(entry.command)) {
      command = await providerCommandsStore.selectPatient(
        entry.command,
        entry.selectedPatientToken,
        entry.expectedIntent,
        () => isCurrentProviderContext(entry.context)
      );
    } else if (entry.command.status === 'awaiting_patient_creation') {
      command = await providerCommandsStore.confirmPatientCreation(
        entry.command,
        entry.expectedIntent,
        () => isCurrentProviderContext(entry.context)
      );
    } else if (entry.command.status === 'awaiting_phone_refresh') {
      command = await providerCommandsStore.retryPhoneMismatch(
        entry.command,
        entry.expectedIntent,
        () => isCurrentProviderContext(entry.context)
      );
    } else {
      return;
    }

    if (!isCurrentProviderContext(entry.context)) return;
    if (
      Number(command.id) !== Number(entry.command.id) ||
      (command.appointmentId !== undefined &&
        Number(command.appointmentId) !== entry.context.appointmentId)
    ) {
      entry.error = t('SCHEDULING.MEDELEMENT.STALE_COMMAND_DESCRIPTION');
      return;
    }
    // The server may safely bind a legacy draft during explicit patient selection.
    const boundAppointment =
      Number(command.appointment?.id) === Number(appointment.id)
        ? command.appointment
        : null;
    if (boundAppointment) {
      upsertAppointment(boundAppointment);
      appointment = boundAppointment;
      entry.context = captureProviderContext(boundAppointment);
    }
    if (hasPatientAction(command)) {
      await showPatientAction(appointment, command, entry.context);
    } else {
      entry.command = command;
      entry.selectedPatientToken = '';
      entry.candidates = [];
      if (command.status === 'succeeded') {
        const currentAppointment = appointments.value.find(
          item => Number(item.id) === Number(appointment.id)
        );
        if (currentAppointment) {
          currentAppointment.providerConfirmationStatus = 'succeeded';
          currentAppointment.customAttributes = {
            ...currentAppointment.customAttributes,
            medelement_provider_sync_status: 'succeeded',
          };
        }
        await refreshProviderAppointmentState(appointment, entry.context);
      }
    }
    if (boundAppointment) emit('patientBound', boundAppointment);
  } catch (error) {
    if (isCurrentProviderContext(entry.context)) {
      entry.error = formatSchedulingErrorMessage(error, t);
    }
  } finally {
    if (
      patientActionRequestId.value === requestId &&
      patientActionBusyKey.value === key
    ) {
      patientActionBusyKey.value = '';
    }
  }
}

async function checkProviderBooking(appointment) {
  if (checkingAppointmentKey.value || resolvingCancellationKey.value) return;

  const key = appointmentKey(appointment);
  if (
    savingAppointmentKey.value === key ||
    cancellingAppointmentKey.value === key ||
    patientActionBusyKey.value === key
  ) {
    return;
  }

  const context = captureProviderContext(appointment);
  const lookupId = beginPatientActionLookup(key);

  checkingAppointmentKey.value = key;
  try {
    const response = await SchedulingProviderCommandsAPI.list({
      provider: 'medelement',
      appointmentId: appointment.id,
      activeOnly: true,
    });
    const commands = normalizePayload(response.data) || [];
    if (!isCurrentPatientActionLookup(key, context, lookupId)) return;
    const pendingPatientCommand = commands.find(
      item => item.operation === 'create_reception' && hasPatientAction(item)
    );
    if (pendingPatientCommand) {
      await showPatientAction(
        appointment,
        pendingPatientCommand,
        context,
        lookupId
      );
      return;
    }

    const waitingCommand = commands.find(
      item =>
        item.operation === 'create_reception' &&
        COMMANDS_WAITING_FOR_PROVIDER.has(item.status)
    );
    if (waitingCommand) {
      showProviderCommandWaiting(
        appointment,
        context,
        lookupId,
        waitingCommand
      );
      return;
    }

    const command = commands.find(
      item =>
        item.operation === 'create_reception' &&
        COMMANDS_NEEDING_RECONCILIATION.has(item.status)
    );
    if (!isCurrentPatientActionLookup(key, context, lookupId)) return;
    if (!command) {
      if (isPatientActionPendingOnAppointment(appointment)) {
        await refreshPendingProviderReadback(appointment, context, lookupId);
        return;
      }
      if (appointment.status === 'cancelled') {
        useAlert(t('SCHEDULING.APPOINTMENT_STATUS.CANCELLATION_REVIEW'));
      } else {
        useAlert(t('SCHEDULING.APPOINTMENT_FORM.CHECK_NOT_AVAILABLE'));
      }
      return;
    }
    if (command.manualCancellationAvailable) {
      cancellationReviews[appointmentKey(appointment)] = {
        commandId: command.id,
        receptionCode: command.manualCancellationReceptionCode,
      };
      return;
    }
    if (
      appointment.status === 'cancelled' &&
      command.cancellationReviewCandidates?.length
    ) {
      useAlert(
        t('SCHEDULING.APPOINTMENT_FORM.CANCELLATION_CANDIDATES', {
          codes: command.cancellationReviewCandidates.join(', '),
        })
      );
      return;
    }

    await SchedulingProviderCommandsAPI.reconcile(command.id, {
      provider: 'medelement',
    });
    if (!isCurrentPatientActionLookup(key, context, lookupId)) return;
    if (appointment.status === 'cancelled') {
      useAlert(t('SCHEDULING.APPOINTMENT_FORM.CHECK_CANCELLED_STARTED'));
    } else {
      useAlert(t('SCHEDULING.APPOINTMENT_FORM.CHECK_STARTED'));
    }
  } catch (error) {
    if (isCurrentPatientActionLookup(key, context, lookupId)) {
      useAlert(formatSchedulingErrorMessage(error, t));
    }
  } finally {
    if (
      isCurrentProviderContext(context) &&
      checkingAppointmentKey.value === key
    ) {
      checkingAppointmentKey.value = '';
    }
  }
}

async function resolveManualCancellation(appointment) {
  if (resolvingCancellationKey.value || checkingAppointmentKey.value) return;

  const key = appointmentKey(appointment);
  const review = cancellationReviews[key];
  if (!review) return;
  const generation = providerReviewGeneration;

  resolvingCancellationKey.value = key;
  try {
    const response = await SchedulingProviderCommandsAPI.resolveCancellation(
      review.commandId,
      { provider: 'medelement', receptionCode: review.receptionCode }
    );
    if (generation !== providerReviewGeneration) return;
    const resolved = normalizePayload(response.data);
    if (
      resolved.id !== review.commandId ||
      resolved.status !== 'cancelled' ||
      resolved.manualCancellationResolution?.result !== 'removed' ||
      resolved.manualCancellationResolution?.receptionCode !==
        review.receptionCode ||
      resolved.appointment?.id !== appointment.id ||
      resolved.appointment?.status !== 'cancelled'
    ) {
      useAlert(t('SCHEDULING.ERRORS.MEDELEMENT_CANCELLATION_NOT_VERIFIED'));
      return;
    }
    upsertAppointment(resolved.appointment);
    delete cancellationReviews[key];
    refreshSidebarCounters();
    useAlert(t('SCHEDULING.APPOINTMENT_FORM.MANUAL_CANCELLATION_VERIFIED'));
  } catch (error) {
    if (generation === providerReviewGeneration) {
      useAlert(formatSchedulingErrorMessage(error, t));
    }
  } finally {
    if (generation === providerReviewGeneration)
      resolvingCancellationKey.value = '';
  }
}

async function checkReviewedBooking(appointment) {
  const review = cancellationReviews[appointmentKey(appointment)];
  if (!review || checkingAppointmentKey.value || resolvingCancellationKey.value)
    return;

  const generation = providerReviewGeneration;

  checkingAppointmentKey.value = appointmentKey(appointment);
  try {
    await SchedulingProviderCommandsAPI.reconcile(review.commandId, {
      provider: 'medelement',
    });
    if (generation !== providerReviewGeneration) return;
    delete cancellationReviews[appointmentKey(appointment)];
    useAlert(t('SCHEDULING.APPOINTMENT_FORM.CHECK_STARTED'));
  } catch (error) {
    if (generation === providerReviewGeneration) {
      useAlert(formatSchedulingErrorMessage(error, t));
    }
  } finally {
    if (generation === providerReviewGeneration)
      checkingAppointmentKey.value = '';
  }
}

const saveAppointment = async appointment => {
  if (isAppointmentProviderOwned(appointment)) return;

  const key = appointmentKey(appointment);
  if (
    savingAppointmentKey.value ||
    cancellingAppointmentKey.value ||
    patientActionBusyKey.value
  ) {
    return;
  }
  const form = appointmentForms[key];
  if (isAppointmentFormInvalid(form)) return;
  if (form.status === 'cancelled' && appointment.status !== 'cancelled') {
    await cancelAppointment(appointment);
    return;
  }

  const context = captureSidebarContext();
  appointmentSaveRequestId += 1;
  const requestId = appointmentSaveRequestId;
  savingAppointmentKey.value = key;
  try {
    const response = await SchedulingAppointmentsAPI.update(
      appointment.id,
      buildAppointmentPayload(form)
    );
    if (!isCurrentSidebarContext(context)) return;
    const savedAppointment = normalizePayload(response.data);
    upsertAppointment(savedAppointment);
    invalidatePatientAction(key);
    refreshPendingPatientAction(savedAppointment).catch(() => {});
    openAppointmentKeys.value = [appointmentKey(savedAppointment)];
    refreshSidebarCounters();
    useAlert(t('SCHEDULING.APPOINTMENT_FORM.SUCCESS_SAVE'));
    emit('patientBound', savedAppointment);
  } catch (error) {
    if (isCurrentSidebarContext(context)) {
      useAlert(formatSchedulingErrorMessage(error, t));
    }
  } finally {
    if (requestId === appointmentSaveRequestId) {
      savingAppointmentKey.value = '';
    }
  }
};

const handleHeaderAction = key => {
  if (key === 'new_appointment') {
    startCreateAppointment();
  }
};

const formatDateTimeRange = appointment => {
  const start = appointment.startsAt ? new Date(appointment.startsAt) : null;
  const end = appointment.endsAt ? new Date(appointment.endsAt) : null;

  if (!start || Number.isNaN(start.getTime())) {
    return '—';
  }

  const dateLabel = new Intl.DateTimeFormat(locale.value, {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
    timeZone: SCHEDULING_TIMEZONE,
  }).format(start);
  const startTime = new Intl.DateTimeFormat(locale.value, {
    hour: '2-digit',
    minute: '2-digit',
    timeZone: SCHEDULING_TIMEZONE,
  }).format(start);
  const endTime =
    end && !Number.isNaN(end.getTime())
      ? new Intl.DateTimeFormat(locale.value, {
          hour: '2-digit',
          minute: '2-digit',
          timeZone: SCHEDULING_TIMEZONE,
        }).format(end)
      : '';

  return endTime
    ? `${dateLabel}, ${startTime}–${endTime}`
    : `${dateLabel}, ${startTime}`;
};

const appointmentTitle = appointment =>
  appointment.title ||
  appointment.clientName ||
  appointment.serviceNameSnapshot ||
  t('SCHEDULING.CALENDAR.NO_SERVICE');

const appointmentMeta = appointment => {
  const serviceName =
    appointment.serviceNameSnapshot || t('SCHEDULING.CALENDAR.NO_SERVICE');
  return [
    formatDateTimeRange(appointment),
    serviceName,
    appointment.resourceName,
  ]
    .filter(Boolean)
    .join(' · ');
};

const initializeSidebar = async () => {
  const context = captureSidebarContext();
  await loadReferences();
  if (!isCurrentSidebarContext(context)) return;
  const loaded = await loadAppointments();
  if (loaded && !restorePatientDraft() && !appointments.value.length) {
    await startCreateAppointment({ scroll: false });
  }
};

const loadReferences = () => {
  if (!referencesReadyPromise) {
    referencesReadyPromise = Promise.all([
      schedulingReferencesStore.loadResources(),
      schedulingReferencesStore.loadServices(),
    ]).catch(() => {
      // Keep appointments usable when optional references fail.
    });
  }
  return referencesReadyPromise;
};

onMounted(() => {
  initializeSidebar();
});

onBeforeUnmount(() => {
  rememberPatientDraft();
  sidebarDisposed = true;
  loadRequestId += 1;
  providerReviewGeneration += 1;
  appointmentSaveRequestId += 1;
  createSaveRequestId += 1;
  appointmentCancellationRequestId += 1;
  patientActionRequestId.value += 1;
  providerCommandsStore.ui.operationId += 1;
  providerCommandsStore.ui.isExecuting = false;
  providerCommandsStore.ui.error = null;
});

watch(
  () => [
    accountId.value,
    props.currentChat?.id,
    contactId.value,
    conversationDisplayIds.value.join(','),
    selectedPatientContextId.value,
    props.patientContextKey,
    props.patientContextLoading,
    props.patientContextEnabled,
  ],
  async () => {
    rememberPatientDraft();
    activeDraftKey = currentDraftKey.value;
    providerReviewGeneration += 1;
    appointmentSaveRequestId += 1;
    createSaveRequestId += 1;
    appointmentCancellationRequestId += 1;
    Object.keys(cancellationReviews).forEach(
      key => delete cancellationReviews[key]
    );
    checkingAppointmentKey.value = '';
    resolvingCancellationKey.value = '';
    savingAppointmentKey.value = '';
    cancellingAppointmentKey.value = '';
    isSavingCreate.value = false;
    patientActionRequestId.value += 1;
    patientActionBusyKey.value = '';
    Object.keys(patientActions).forEach(key => delete patientActions[key]);
    providerCommandsStore.ui.operationId += 1;
    providerCommandsStore.ui.isExecuting = false;
    providerCommandsStore.ui.error = null;
    isCreating.value = false;
    appointments.value = [];
    setAppointmentForms();
    openAppointmentKeys.value = [];
    resetCreateForm();
    const context = captureSidebarContext();
    await loadReferences();
    if (!isCurrentSidebarContext(context)) return;
    const loaded = await loadAppointments();
    if (loaded && !restorePatientDraft() && !appointments.value.length) {
      await startCreateAppointment({ scroll: false });
    }
  },
  { flush: 'sync' }
);
</script>

<template>
  <div class="flex h-full min-w-0 flex-1 flex-col">
    <SidebarActionsHeader
      :title="$t('SCHEDULING.DIALOGS.PANEL_TITLE')"
      :buttons="headerButtons"
      @click="handleHeaderAction"
      @close="emit('close')"
    />

    <div
      ref="scrollContainer"
      class="flex min-h-0 flex-1 flex-col overflow-y-auto pb-5"
    >
      <div v-if="ui.isLoading" class="flex justify-center py-12">
        <Spinner class="!h-8 !w-8" />
      </div>

      <SchedulingErrorState
        v-else-if="ui.error"
        class="m-3"
        :title="$t('SCHEDULING.DIALOGS.ERROR')"
        @retry="loadAppointments"
      />

      <div
        v-else-if="!appointments.length && !isCreating"
        class="px-4 py-6 text-sm text-n-slate-11"
      >
        {{ $t('SCHEDULING.DIALOGS.EMPTY') }}
      </div>

      <div v-else class="border-t border-n-weak">
        <section
          v-if="isCreating"
          :key="NEW_APPOINTMENT_KEY"
          class="border-b border-n-weak bg-n-solid-1"
        >
          <button
            type="button"
            class="flex w-full p-0 text-left hover:bg-n-alpha-1 rtl:text-right"
            @click="openAppointmentKeys = [NEW_APPOINTMENT_KEY]"
          >
            <span
              class="flex min-w-0 flex-1 items-start justify-between gap-3 px-3 py-2.5"
            >
              <span class="flex min-w-0 items-start gap-2">
                <span
                  class="i-lucide-calendar-plus mt-0.5 size-4 shrink-0 text-n-slate-11"
                />
                <span class="min-w-0">
                  <span
                    class="block truncate text-sm font-medium text-n-slate-12"
                  >
                    {{ $t('SCHEDULING.CALENDAR.NEW_APPOINTMENT') }}
                  </span>
                  <span
                    class="block truncate text-xs leading-5 text-n-slate-11"
                  >
                    {{
                      $t('SCHEDULING.APPOINTMENT_FORM.APPOINTMENT_DESCRIPTION')
                    }}
                  </span>
                </span>
              </span>
              <span
                class="i-lucide-chevron-down mt-0.5 size-4 shrink-0 text-n-slate-10 transition-transform rotate-180"
              />
            </span>
          </button>

          <div class="border-t border-n-weak px-4 py-3">
            <div class="grid gap-3">
              <div class="scheduling-appointment-drawer-form">
                <div
                  class="scheduling-appointment-drawer-section scheduling-appointment-drawer-section--top"
                >
                  <div class="scheduling-appointment-drawer-row">
                    <label
                      class="scheduling-appointment-drawer-label"
                      for="scheduling-conversation-appointment-status"
                    >
                      {{ $t('SCHEDULING.APPOINTMENT_FORM.STATUS') }}
                    </label>
                    <SchedulingSelectField
                      id="scheduling-conversation-appointment-status"
                      class="scheduling-appointment-drawer-control scheduling-appointment-drawer-select-control"
                      :aria-label="$t('SCHEDULING.APPOINTMENT_FORM.STATUS')"
                      :model-value="createForm.status"
                      :options="statusOptions"
                      :placeholder="$t('SCHEDULING.APPOINTMENT_FORM.STATUS')"
                      dropdown-placement="auto"
                      @update:model-value="createForm.status = $event"
                    />
                  </div>

                  <div class="scheduling-appointment-drawer-row">
                    <label
                      class="scheduling-appointment-drawer-label"
                      for="scheduling-conversation-appointment-client-first-name"
                    >
                      {{ $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_FIRST_NAME') }}
                    </label>
                    <Input
                      id="scheduling-conversation-appointment-client-first-name"
                      class="scheduling-appointment-drawer-control"
                      custom-input-class="!rounded-md !bg-n-alpha-black2"
                      :aria-label="
                        $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_FIRST_NAME')
                      "
                      :model-value="createForm.clientFirstName"
                      size="sm"
                      @update:model-value="
                        updatePatientNamePart(
                          createForm,
                          'clientFirstName',
                          $event
                        )
                      "
                    />
                  </div>

                  <div class="scheduling-appointment-drawer-row">
                    <label
                      class="scheduling-appointment-drawer-label"
                      for="scheduling-conversation-appointment-client-last-name"
                    >
                      {{ $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_LAST_NAME') }}
                    </label>
                    <Input
                      id="scheduling-conversation-appointment-client-last-name"
                      class="scheduling-appointment-drawer-control"
                      custom-input-class="!rounded-md !bg-n-alpha-black2"
                      :aria-label="
                        $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_LAST_NAME')
                      "
                      :model-value="createForm.clientLastName"
                      :message="medelementLastNameError(createForm)"
                      :message-type="
                        medelementLastNameError(createForm) ? 'error' : 'info'
                      "
                      size="sm"
                      @update:model-value="
                        updatePatientNamePart(
                          createForm,
                          'clientLastName',
                          $event
                        )
                      "
                    />
                  </div>

                  <div class="scheduling-appointment-drawer-row">
                    <label
                      class="scheduling-appointment-drawer-label"
                      for="scheduling-conversation-appointment-client-middle-name"
                    >
                      {{ $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_MIDDLE_NAME') }}
                    </label>
                    <Input
                      id="scheduling-conversation-appointment-client-middle-name"
                      class="scheduling-appointment-drawer-control"
                      custom-input-class="!rounded-md !bg-n-alpha-black2"
                      :aria-label="
                        $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_MIDDLE_NAME')
                      "
                      :model-value="createForm.clientMiddleName"
                      size="sm"
                      @update:model-value="
                        updatePatientNamePart(
                          createForm,
                          'clientMiddleName',
                          $event
                        )
                      "
                    />
                  </div>

                  <div class="scheduling-appointment-drawer-row">
                    <label
                      class="scheduling-appointment-drawer-label"
                      for="scheduling-conversation-appointment-client-phone"
                    >
                      {{ $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_PHONE') }}
                    </label>
                    <Input
                      id="scheduling-conversation-appointment-client-phone"
                      class="scheduling-appointment-drawer-control"
                      custom-input-class="!rounded-md !bg-n-alpha-black2"
                      :aria-label="
                        $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_PHONE')
                      "
                      :model-value="createForm.clientPhone"
                      :message="medelementPhoneError(createForm)"
                      :message-type="
                        medelementPhoneError(createForm) ? 'error' : 'info'
                      "
                      size="sm"
                      @update:model-value="createForm.clientPhone = $event"
                    />
                  </div>

                  <div
                    v-if="isMedelementResource(selectedCreateResource)"
                    class="scheduling-appointment-drawer-row"
                  >
                    <label
                      class="scheduling-appointment-drawer-label"
                      for="scheduling-conversation-appointment-client-iin"
                    >
                      {{ $t('SCHEDULING.CONTACT.IIN') }}
                    </label>
                    <Input
                      id="scheduling-conversation-appointment-client-iin"
                      class="scheduling-appointment-drawer-control"
                      custom-input-class="!rounded-md !bg-n-alpha-black2"
                      :aria-label="$t('SCHEDULING.CONTACT.IIN')"
                      :model-value="createForm.clientIdentifier"
                      :message="medelementIinError(createForm)"
                      :message-type="
                        medelementIinError(createForm) ? 'error' : 'info'
                      "
                      inputmode="numeric"
                      autocomplete="off"
                      size="sm"
                      @update:model-value="updatePatientIin(createForm, $event)"
                    />
                  </div>

                  <div class="scheduling-appointment-drawer-row">
                    <label
                      class="scheduling-appointment-drawer-label"
                      for="scheduling-conversation-appointment-resource"
                    >
                      {{ $t('SCHEDULING.APPOINTMENT_FORM.RESOURCE') }}
                    </label>
                    <SchedulingSelectField
                      id="scheduling-conversation-appointment-resource"
                      class="scheduling-appointment-drawer-control scheduling-appointment-drawer-select-control"
                      :aria-label="$t('SCHEDULING.APPOINTMENT_FORM.RESOURCE')"
                      :model-value="createForm.resourceId"
                      :options="resourceOptions"
                      :placeholder="$t('SCHEDULING.APPOINTMENT_FORM.RESOURCE')"
                      :empty-state="$t('SCHEDULING.CALENDAR.NO_RESOURCES')"
                      dropdown-placement="auto"
                      @update:model-value="handleCreateResourceChange"
                    />
                  </div>

                  <div
                    v-if="isMedelementResource(selectedCreateResource)"
                    class="scheduling-appointment-drawer-row"
                  >
                    <label
                      class="scheduling-appointment-drawer-label"
                      for="scheduling-conversation-appointment-medelement-cabinet"
                    >
                      {{ $t('SCHEDULING.MEDELEMENT.CABINET') }}
                    </label>
                    <SchedulingSelectField
                      id="scheduling-conversation-appointment-medelement-cabinet"
                      class="scheduling-appointment-drawer-control scheduling-appointment-drawer-select-control"
                      :aria-label="$t('SCHEDULING.MEDELEMENT.CABINET')"
                      :model-value="createForm.medelementCabinetCode"
                      :options="medelementCabinetOptions"
                      :placeholder="$t('SCHEDULING.MEDELEMENT.CABINET')"
                      :message="medelementCabinetError(createForm)"
                      :message-type="
                        medelementCabinetError(createForm) ? 'error' : 'info'
                      "
                      dropdown-placement="auto"
                      @update:model-value="
                        createForm.medelementCabinetCode = $event
                      "
                    />
                  </div>

                  <div class="scheduling-appointment-drawer-row">
                    <label
                      class="scheduling-appointment-drawer-label"
                      for="scheduling-conversation-appointment-service"
                    >
                      {{ $t('SCHEDULING.APPOINTMENT_FORM.SERVICE') }}
                    </label>
                    <SchedulingSelectField
                      v-if="hasServiceOptionsForForm(createForm)"
                      id="scheduling-conversation-appointment-service"
                      class="scheduling-appointment-drawer-control scheduling-appointment-drawer-select-control"
                      :aria-label="$t('SCHEDULING.APPOINTMENT_FORM.SERVICE')"
                      :model-value="createForm.serviceId"
                      :options="serviceOptionsForForm(createForm)"
                      :placeholder="$t('SCHEDULING.APPOINTMENT_FORM.SERVICE')"
                      :empty-state="
                        $t('SCHEDULING.APPOINTMENT_FORM.SERVICE_EMPTY')
                      "
                      dropdown-placement="auto"
                      wrap-label
                      clamp-selected-label
                      @update:model-value="handleCreateServiceChange"
                    />
                    <Input
                      v-else-if="!isMedelementResource(selectedCreateResource)"
                      id="scheduling-conversation-appointment-service"
                      class="scheduling-appointment-drawer-control"
                      custom-input-class="!rounded-md !bg-n-alpha-black2"
                      :aria-label="$t('SCHEDULING.APPOINTMENT_FORM.SERVICE')"
                      :model-value="createForm.serviceNameSnapshot"
                      :placeholder="$t('SCHEDULING.APPOINTMENT_FORM.SERVICE')"
                      size="sm"
                      @update:model-value="
                        createForm.serviceNameSnapshot = $event
                      "
                    />
                    <p v-else class="mt-1 mb-0 text-xs text-n-slate-10">
                      {{ $t('SCHEDULING.MEDELEMENT.NO_SPECIALIST_SERVICES') }}
                    </p>
                  </div>

                  <div class="scheduling-appointment-drawer-row">
                    <span class="scheduling-appointment-drawer-label">
                      {{ $t('SCHEDULING.APPOINTMENT_FORM.STARTS_AT') }}
                    </span>
                    <SchedulingDateTimeField
                      class="scheduling-appointment-drawer-control"
                      :aria-label="$t('SCHEDULING.APPOINTMENT_FORM.STARTS_AT')"
                      :model-value="createForm.startsAt"
                      :placeholder="$t('SCHEDULING.APPOINTMENT_FORM.STARTS_AT')"
                      @update:model-value="
                        value => {
                          createForm.startsAt = value;
                          updateCreateEndFromDuration();
                        }
                      "
                    />
                  </div>

                  <div class="scheduling-appointment-drawer-row">
                    <span class="scheduling-appointment-drawer-label">
                      {{ $t('SCHEDULING.APPOINTMENT_FORM.ENDS_AT') }}
                    </span>
                    <SchedulingDateTimeField
                      class="scheduling-appointment-drawer-control"
                      :aria-label="$t('SCHEDULING.APPOINTMENT_FORM.ENDS_AT')"
                      :model-value="createForm.endsAt"
                      :placeholder="$t('SCHEDULING.APPOINTMENT_FORM.ENDS_AT')"
                      :message="
                        createForm.endsAt && !createFormEndsAfterStart
                          ? $t(
                              'SCHEDULING.APPOINTMENT_FORM.ERRORS.END_BEFORE_START'
                            )
                          : ''
                      "
                      :message-type="
                        createForm.endsAt && !createFormEndsAfterStart
                          ? 'error'
                          : 'info'
                      "
                      @update:model-value="createForm.endsAt = $event"
                    />
                  </div>

                  <div class="scheduling-appointment-drawer-row">
                    <label
                      class="scheduling-appointment-drawer-label"
                      for="scheduling-conversation-appointment-service-amount"
                    >
                      {{ $t('SCHEDULING.APPOINTMENT_FORM.SERVICE_AMOUNT') }}
                    </label>
                    <Input
                      id="scheduling-conversation-appointment-service-amount"
                      class="scheduling-appointment-drawer-control"
                      custom-input-class="!rounded-md !bg-n-alpha-black2"
                      inputmode="numeric"
                      min="0"
                      step="1"
                      type="number"
                      :aria-label="
                        $t('SCHEDULING.APPOINTMENT_FORM.SERVICE_AMOUNT')
                      "
                      :model-value="createForm.serviceAmount"
                      size="sm"
                      @update:model-value="createForm.serviceAmount = $event"
                    />
                  </div>
                </div>
              </div>

              <div class="flex items-center justify-end gap-2">
                <Button
                  v-if="appointments.length"
                  size="sm"
                  slate
                  faded
                  :label="$t('SCHEDULING.GENERAL.CANCEL')"
                  @click="cancelCreateAppointment"
                />
                <Button
                  size="sm"
                  color="blue"
                  :is-loading="isSavingCreate"
                  :disabled="isCreateFormInvalid"
                  :label="$t('SCHEDULING.GENERAL.SAVE')"
                  @click="saveCreateAppointment"
                />
              </div>
            </div>
          </div>
        </section>
        <section
          v-for="appointment in appointments"
          :key="appointment.id"
          class="border-b border-n-weak bg-n-solid-1"
        >
          <button
            type="button"
            class="flex w-full p-0 text-left rtl:text-right"
            :class="{
              'hover:bg-n-alpha-1': !isAppointmentProviderOwned(appointment),
            }"
            :disabled="isAppointmentProviderOwned(appointment)"
            @click="toggleAppointment(appointment)"
          >
            <span
              class="flex min-w-0 flex-1 items-start justify-between gap-3 px-3 py-2.5"
            >
              <span class="flex min-w-0 items-start gap-2">
                <span
                  class="mt-0.5 size-4 shrink-0"
                  :class="[
                    statusIcon(appointment),
                    statusIconClass(appointment),
                  ]"
                />
                <span class="min-w-0">
                  <span
                    class="block truncate text-sm font-medium text-n-slate-12"
                  >
                    {{ appointmentTitle(appointment) }}
                  </span>
                  <span
                    class="block truncate text-xs leading-5 text-n-slate-11"
                  >
                    {{ appointmentMeta(appointment) }}
                  </span>
                  <span
                    v-if="providerBookingStatusKey(appointment)"
                    class="block text-xs font-medium leading-5"
                    :class="
                      providerBookingNeedsReview(appointment)
                        ? 'text-n-ruby-11'
                        : 'text-n-slate-11'
                    "
                  >
                    {{ providerBookingStatusMessage(appointment, $t) }}
                  </span>
                </span>
              </span>
              <span
                v-if="!isAppointmentProviderOwned(appointment)"
                class="i-lucide-chevron-down mt-0.5 size-4 shrink-0 text-n-slate-10 transition-transform"
                :class="{ 'rotate-180': isAppointmentOpen(appointment) }"
              />
            </span>
          </button>

          <RouterLink
            v-if="
              appointment.patientContactId &&
              appointment.patientContactId !== appointment.contactId
            "
            class="mx-3 mb-2.5 block text-xs text-n-blue-11"
            :to="{
              name: 'contacts_edit',
              params: {
                accountId: route.params.accountId,
                contactId: appointment.patientContactId,
              },
            }"
            data-testid="appointment-patient-card"
          >
            {{
              $t('SCHEDULING.APPOINTMENT_FORM.PATIENT_CARD_LINK', {
                patientName:
                  appointment.patientContactName || appointment.clientName,
                contactId: appointment.patientContactId,
              })
            }}
          </RouterLink>

          <div
            v-if="patientActions[appointmentKey(appointment)]"
            class="mx-3 mb-3 rounded-md border border-n-weak bg-n-alpha-1 p-3"
            role="status"
            :data-testid="`provider-patient-action-${appointment.id}`"
          >
            <p class="text-sm font-medium text-n-slate-12">
              {{
                patientActionTitle(patientActions[appointmentKey(appointment)])
              }}
            </p>
            <p
              v-if="
                patientActionDescription(
                  patientActions[appointmentKey(appointment)]
                )
              "
              class="mt-1 text-xs leading-5 text-n-slate-11"
            >
              {{
                patientActionDescription(
                  patientActions[appointmentKey(appointment)]
                )
              }}
            </p>
            <p
              v-if="patientActions[appointmentKey(appointment)].error"
              class="mt-1 text-xs leading-5 text-n-ruby-11"
            >
              {{ patientActions[appointmentKey(appointment)].error }}
            </p>
            <div
              v-if="
                providerCommandRequiresPatientSelection(
                  patientActions[appointmentKey(appointment)].command
                )
              "
              class="mt-2 flex flex-col gap-2"
            >
              <Spinner
                v-if="
                  patientActions[appointmentKey(appointment)].loadingCandidates
                "
                class="!h-4 !w-4"
              />
              <button
                v-for="candidate in patientActions[appointmentKey(appointment)]
                  .candidates"
                :key="candidate.token"
                type="button"
                class="flex flex-col items-start gap-1 rounded-md border p-2 text-start"
                :class="
                  patientActions[appointmentKey(appointment)]
                    .selectedPatientToken === candidate.token
                    ? 'border-n-brand bg-n-brand/10'
                    : 'border-n-weak hover:border-n-strong'
                "
                :aria-pressed="
                  patientActions[appointmentKey(appointment)]
                    .selectedPatientToken === candidate.token
                "
                :data-testid="`patient-candidate-${appointment.id}-${candidate.token}`"
                @click="selectPatientCandidate(appointment, candidate.token)"
              >
                <span class="text-sm font-medium text-n-slate-12">
                  {{
                    [candidate.name, candidate.middlename]
                      .filter(Boolean)
                      .join(' ')
                  }}
                </span>
                <span class="text-xs text-n-slate-11">
                  {{
                    [
                      candidate.birthday,
                      candidate.iinMasked,
                      candidate.phoneMasked,
                    ]
                      .filter(Boolean)
                      .join(' · ')
                  }}
                </span>
              </button>
            </div>
            <div
              v-if="
                patientActionButtonLabel(
                  patientActions[appointmentKey(appointment)]
                )
              "
              class="mt-3 flex justify-end"
            >
              <Button
                size="sm"
                color="blue"
                :is-loading="
                  patientActionBusyKey === appointmentKey(appointment)
                "
                :disabled="
                  !canContinuePatientAction(
                    patientActions[appointmentKey(appointment)]
                  )
                "
                :label="
                  patientActionButtonLabel(
                    patientActions[appointmentKey(appointment)]
                  )
                "
                :data-testid="`continue-provider-patient-action-${appointment.id}`"
                @click="continuePatientAction(appointment)"
              />
            </div>
          </div>

          <div
            v-if="
              !isAppointmentProviderOwned(appointment) &&
              (providerBookingNeedsReview(appointment) ||
                (isMedelementAppointment(appointment) &&
                  isPatientActionPendingOnAppointment(appointment)))
            "
            class="flex justify-end px-3 pb-2.5"
          >
            <Button
              size="sm"
              slate
              faded
              :is-loading="
                checkingAppointmentKey === appointmentKey(appointment)
              "
              :disabled="
                Boolean(resolvingCancellationKey) ||
                patientActionBusyKey === appointmentKey(appointment) ||
                savingAppointmentKey === appointmentKey(appointment) ||
                cancellingAppointmentKey === appointmentKey(appointment)
              "
              :label="$t('SCHEDULING.APPOINTMENT_FORM.CHECK_PROVIDER_BOOKING')"
              @click="checkProviderBooking(appointment)"
            />
          </div>

          <div
            v-if="cancellationReviews[appointmentKey(appointment)]"
            class="mx-3 mb-3 rounded-md border border-n-weak bg-n-alpha-1 p-3"
            role="status"
          >
            <p class="mb-2 text-xs leading-5 text-n-slate-12">
              {{
                $t(
                  'SCHEDULING.APPOINTMENT_FORM.MANUAL_CANCELLATION_INSTRUCTIONS',
                  {
                    code: cancellationReviews[appointmentKey(appointment)]
                      .receptionCode,
                  }
                )
              }}
            </p>
            <div class="flex flex-wrap justify-end gap-2">
              <Button
                v-if="appointment.status !== 'cancelled'"
                size="sm"
                slate
                faded
                :disabled="Boolean(resolvingCancellationKey)"
                :is-loading="
                  checkingAppointmentKey === appointmentKey(appointment)
                "
                :label="
                  $t('SCHEDULING.APPOINTMENT_FORM.CHECK_PROVIDER_BOOKING')
                "
                @click="checkReviewedBooking(appointment)"
              />
              <Button
                size="sm"
                color="blue"
                :disabled="Boolean(checkingAppointmentKey)"
                :is-loading="
                  resolvingCancellationKey === appointmentKey(appointment)
                "
                :label="
                  $t('SCHEDULING.APPOINTMENT_FORM.VERIFY_MANUAL_CANCELLATION')
                "
                @click="resolveManualCancellation(appointment)"
              />
            </div>
          </div>

          <div
            v-if="
              isAppointmentProviderOwned(appointment) &&
              appointment.status !== 'cancelled' &&
              !isProviderCancellationPending(appointment)
            "
            class="flex flex-col items-end gap-1 px-3 pb-2.5"
          >
            <Button
              size="sm"
              slate
              faded
              :is-loading="
                cancellingAppointmentKey === appointmentKey(appointment)
              "
              :disabled="
                patientActionBusyKey === appointmentKey(appointment) ||
                savingAppointmentKey === appointmentKey(appointment)
              "
              :label="$t('SCHEDULING.APPOINTMENT_FORM.CANCEL_APPOINTMENT')"
              @click="cancelAppointment(appointment)"
            />
            <span
              v-if="isMedelementCancellationLocalOnly(appointment)"
              class="text-xs leading-5 text-n-slate-11 text-end"
            >
              {{ $t('SCHEDULING.MEDELEMENT.LOCAL_CANCEL_HINT') }}
            </span>
          </div>

          <div
            v-show="isAppointmentOpen(appointment)"
            class="border-t border-n-weak px-4 py-3"
          >
            <div
              v-if="appointmentForms[appointmentKey(appointment)]"
              class="grid gap-3"
            >
              <div class="scheduling-appointment-drawer-form">
                <div
                  class="scheduling-appointment-drawer-section scheduling-appointment-drawer-section--top"
                >
                  <div class="scheduling-appointment-drawer-row">
                    <label
                      class="scheduling-appointment-drawer-label"
                      :for="`scheduling-conversation-appointment-status-${appointment.id}`"
                    >
                      {{ $t('SCHEDULING.APPOINTMENT_FORM.STATUS') }}
                    </label>
                    <SchedulingSelectField
                      :id="`scheduling-conversation-appointment-status-${appointment.id}`"
                      class="scheduling-appointment-drawer-control scheduling-appointment-drawer-select-control"
                      :aria-label="$t('SCHEDULING.APPOINTMENT_FORM.STATUS')"
                      :model-value="
                        appointmentForms[appointmentKey(appointment)].status
                      "
                      :options="statusOptions"
                      :placeholder="$t('SCHEDULING.APPOINTMENT_FORM.STATUS')"
                      dropdown-placement="auto"
                      @update:model-value="
                        appointmentForms[appointmentKey(appointment)].status =
                          $event
                      "
                    />
                  </div>

                  <div class="scheduling-appointment-drawer-row">
                    <label
                      class="scheduling-appointment-drawer-label"
                      :for="`scheduling-conversation-appointment-client-first-name-${appointment.id}`"
                    >
                      {{ $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_FIRST_NAME') }}
                    </label>
                    <Input
                      :id="`scheduling-conversation-appointment-client-first-name-${appointment.id}`"
                      class="scheduling-appointment-drawer-control"
                      custom-input-class="!rounded-md !bg-n-alpha-black2"
                      :aria-label="
                        $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_FIRST_NAME')
                      "
                      :model-value="
                        appointmentForms[appointmentKey(appointment)]
                          .clientFirstName
                      "
                      size="sm"
                      @update:model-value="
                        updatePatientNamePart(
                          appointmentForms[appointmentKey(appointment)],
                          'clientFirstName',
                          $event
                        )
                      "
                    />
                  </div>

                  <div class="scheduling-appointment-drawer-row">
                    <label
                      class="scheduling-appointment-drawer-label"
                      :for="`scheduling-conversation-appointment-client-last-name-${appointment.id}`"
                    >
                      {{ $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_LAST_NAME') }}
                    </label>
                    <Input
                      :id="`scheduling-conversation-appointment-client-last-name-${appointment.id}`"
                      class="scheduling-appointment-drawer-control"
                      custom-input-class="!rounded-md !bg-n-alpha-black2"
                      :aria-label="
                        $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_LAST_NAME')
                      "
                      :model-value="
                        appointmentForms[appointmentKey(appointment)]
                          .clientLastName
                      "
                      :message="
                        medelementLastNameError(
                          appointmentForms[appointmentKey(appointment)]
                        )
                      "
                      :message-type="
                        medelementLastNameError(
                          appointmentForms[appointmentKey(appointment)]
                        )
                          ? 'error'
                          : 'info'
                      "
                      size="sm"
                      @update:model-value="
                        updatePatientNamePart(
                          appointmentForms[appointmentKey(appointment)],
                          'clientLastName',
                          $event
                        )
                      "
                    />
                  </div>

                  <div class="scheduling-appointment-drawer-row">
                    <label
                      class="scheduling-appointment-drawer-label"
                      :for="`scheduling-conversation-appointment-client-middle-name-${appointment.id}`"
                    >
                      {{ $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_MIDDLE_NAME') }}
                    </label>
                    <Input
                      :id="`scheduling-conversation-appointment-client-middle-name-${appointment.id}`"
                      class="scheduling-appointment-drawer-control"
                      custom-input-class="!rounded-md !bg-n-alpha-black2"
                      :aria-label="
                        $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_MIDDLE_NAME')
                      "
                      :model-value="
                        appointmentForms[appointmentKey(appointment)]
                          .clientMiddleName
                      "
                      size="sm"
                      @update:model-value="
                        updatePatientNamePart(
                          appointmentForms[appointmentKey(appointment)],
                          'clientMiddleName',
                          $event
                        )
                      "
                    />
                  </div>

                  <div class="scheduling-appointment-drawer-row">
                    <label
                      class="scheduling-appointment-drawer-label"
                      :for="`scheduling-conversation-appointment-client-phone-${appointment.id}`"
                    >
                      {{ $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_PHONE') }}
                    </label>
                    <Input
                      :id="`scheduling-conversation-appointment-client-phone-${appointment.id}`"
                      class="scheduling-appointment-drawer-control"
                      custom-input-class="!rounded-md !bg-n-alpha-black2"
                      :aria-label="
                        $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_PHONE')
                      "
                      :model-value="
                        appointmentForms[appointmentKey(appointment)]
                          .clientPhone
                      "
                      :message="
                        medelementPhoneError(
                          appointmentForms[appointmentKey(appointment)]
                        )
                      "
                      :message-type="
                        medelementPhoneError(
                          appointmentForms[appointmentKey(appointment)]
                        )
                          ? 'error'
                          : 'info'
                      "
                      size="sm"
                      @update:model-value="
                        appointmentForms[
                          appointmentKey(appointment)
                        ].clientPhone = $event
                      "
                    />
                  </div>

                  <div
                    v-if="
                      isMedelementResource(
                        selectedResourceForForm(
                          appointmentForms[appointmentKey(appointment)]
                        )
                      )
                    "
                    class="scheduling-appointment-drawer-row"
                  >
                    <label
                      class="scheduling-appointment-drawer-label"
                      :for="`scheduling-conversation-appointment-client-iin-${appointment.id}`"
                    >
                      {{ $t('SCHEDULING.CONTACT.IIN') }}
                    </label>
                    <Input
                      :id="`scheduling-conversation-appointment-client-iin-${appointment.id}`"
                      class="scheduling-appointment-drawer-control"
                      custom-input-class="!rounded-md !bg-n-alpha-black2"
                      :aria-label="$t('SCHEDULING.CONTACT.IIN')"
                      :model-value="
                        appointmentForms[appointmentKey(appointment)]
                          .clientIdentifier
                      "
                      :message="
                        medelementIinError(
                          appointmentForms[appointmentKey(appointment)]
                        )
                      "
                      :message-type="
                        medelementIinError(
                          appointmentForms[appointmentKey(appointment)]
                        )
                          ? 'error'
                          : 'info'
                      "
                      inputmode="numeric"
                      autocomplete="off"
                      size="sm"
                      @update:model-value="
                        updatePatientIin(
                          appointmentForms[appointmentKey(appointment)],
                          $event
                        )
                      "
                    />
                  </div>

                  <div class="scheduling-appointment-drawer-row">
                    <label
                      class="scheduling-appointment-drawer-label"
                      :for="`scheduling-conversation-appointment-resource-${appointment.id}`"
                    >
                      {{ $t('SCHEDULING.APPOINTMENT_FORM.RESOURCE') }}
                    </label>
                    <SchedulingSelectField
                      :id="`scheduling-conversation-appointment-resource-${appointment.id}`"
                      class="scheduling-appointment-drawer-control scheduling-appointment-drawer-select-control"
                      :aria-label="$t('SCHEDULING.APPOINTMENT_FORM.RESOURCE')"
                      :model-value="
                        appointmentForms[appointmentKey(appointment)].resourceId
                      "
                      :options="resourceOptions"
                      :placeholder="$t('SCHEDULING.APPOINTMENT_FORM.RESOURCE')"
                      :empty-state="$t('SCHEDULING.CALENDAR.NO_RESOURCES')"
                      dropdown-placement="auto"
                      @update:model-value="
                        handleFormResourceChange(
                          appointmentForms[appointmentKey(appointment)],
                          $event
                        )
                      "
                    />
                  </div>

                  <div
                    v-if="
                      isMedelementResource(
                        selectedResourceForForm(
                          appointmentForms[appointmentKey(appointment)]
                        )
                      )
                    "
                    class="scheduling-appointment-drawer-row"
                  >
                    <label
                      class="scheduling-appointment-drawer-label"
                      :for="`scheduling-conversation-appointment-medelement-cabinet-${appointment.id}`"
                    >
                      {{ $t('SCHEDULING.MEDELEMENT.CABINET') }}
                    </label>
                    <SchedulingSelectField
                      :id="`scheduling-conversation-appointment-medelement-cabinet-${appointment.id}`"
                      class="scheduling-appointment-drawer-control scheduling-appointment-drawer-select-control"
                      :aria-label="$t('SCHEDULING.MEDELEMENT.CABINET')"
                      :model-value="
                        appointmentForms[appointmentKey(appointment)]
                          .medelementCabinetCode
                      "
                      :options="
                        medelementCabinetOptionsForForm(
                          appointmentForms[appointmentKey(appointment)]
                        )
                      "
                      :placeholder="$t('SCHEDULING.MEDELEMENT.CABINET')"
                      :message="
                        medelementCabinetError(
                          appointmentForms[appointmentKey(appointment)]
                        )
                      "
                      :message-type="
                        medelementCabinetError(
                          appointmentForms[appointmentKey(appointment)]
                        )
                          ? 'error'
                          : 'info'
                      "
                      dropdown-placement="auto"
                      @update:model-value="
                        appointmentForms[
                          appointmentKey(appointment)
                        ].medelementCabinetCode = $event
                      "
                    />
                  </div>

                  <div class="scheduling-appointment-drawer-row">
                    <label
                      class="scheduling-appointment-drawer-label"
                      :for="`scheduling-conversation-appointment-service-${appointment.id}`"
                    >
                      {{ $t('SCHEDULING.APPOINTMENT_FORM.SERVICE') }}
                    </label>
                    <SchedulingSelectField
                      v-if="
                        hasServiceOptionsForForm(
                          appointmentForms[appointmentKey(appointment)]
                        )
                      "
                      :id="`scheduling-conversation-appointment-service-${appointment.id}`"
                      class="scheduling-appointment-drawer-control scheduling-appointment-drawer-select-control"
                      :aria-label="$t('SCHEDULING.APPOINTMENT_FORM.SERVICE')"
                      :model-value="
                        appointmentForms[appointmentKey(appointment)].serviceId
                      "
                      :options="
                        serviceOptionsForForm(
                          appointmentForms[appointmentKey(appointment)]
                        )
                      "
                      :placeholder="$t('SCHEDULING.APPOINTMENT_FORM.SERVICE')"
                      :empty-state="
                        $t('SCHEDULING.APPOINTMENT_FORM.SERVICE_EMPTY')
                      "
                      dropdown-placement="auto"
                      wrap-label
                      clamp-selected-label
                      @update:model-value="
                        handleFormServiceChange(
                          appointmentForms[appointmentKey(appointment)],
                          $event
                        )
                      "
                    />
                    <Input
                      v-else-if="
                        !isMedelementResource(
                          selectedResourceForForm(
                            appointmentForms[appointmentKey(appointment)]
                          )
                        )
                      "
                      :id="`scheduling-conversation-appointment-service-${appointment.id}`"
                      class="scheduling-appointment-drawer-control"
                      custom-input-class="!rounded-md !bg-n-alpha-black2"
                      :aria-label="$t('SCHEDULING.APPOINTMENT_FORM.SERVICE')"
                      :model-value="
                        appointmentForms[appointmentKey(appointment)]
                          .serviceNameSnapshot
                      "
                      :placeholder="$t('SCHEDULING.APPOINTMENT_FORM.SERVICE')"
                      size="sm"
                      @update:model-value="
                        appointmentForms[
                          appointmentKey(appointment)
                        ].serviceNameSnapshot = $event
                      "
                    />
                    <p v-else class="mt-1 mb-0 text-xs text-n-slate-10">
                      {{ $t('SCHEDULING.MEDELEMENT.NO_SPECIALIST_SERVICES') }}
                    </p>
                  </div>

                  <div class="scheduling-appointment-drawer-row">
                    <span class="scheduling-appointment-drawer-label">
                      {{ $t('SCHEDULING.APPOINTMENT_FORM.STARTS_AT') }}
                    </span>
                    <SchedulingDateTimeField
                      class="scheduling-appointment-drawer-control"
                      :aria-label="$t('SCHEDULING.APPOINTMENT_FORM.STARTS_AT')"
                      :model-value="
                        appointmentForms[appointmentKey(appointment)].startsAt
                      "
                      :placeholder="$t('SCHEDULING.APPOINTMENT_FORM.STARTS_AT')"
                      @update:model-value="
                        value => {
                          appointmentForms[
                            appointmentKey(appointment)
                          ].startsAt = value;
                          updateFormEndFromDuration(
                            appointmentForms[appointmentKey(appointment)]
                          );
                        }
                      "
                    />
                  </div>

                  <div class="scheduling-appointment-drawer-row">
                    <span class="scheduling-appointment-drawer-label">
                      {{ $t('SCHEDULING.APPOINTMENT_FORM.ENDS_AT') }}
                    </span>
                    <SchedulingDateTimeField
                      class="scheduling-appointment-drawer-control"
                      :aria-label="$t('SCHEDULING.APPOINTMENT_FORM.ENDS_AT')"
                      :model-value="
                        appointmentForms[appointmentKey(appointment)].endsAt
                      "
                      :placeholder="$t('SCHEDULING.APPOINTMENT_FORM.ENDS_AT')"
                      :message="
                        appointmentForms[appointmentKey(appointment)].endsAt &&
                        !appointmentFormEndsAfterStart(
                          appointmentForms[appointmentKey(appointment)]
                        )
                          ? $t(
                              'SCHEDULING.APPOINTMENT_FORM.ERRORS.END_BEFORE_START'
                            )
                          : ''
                      "
                      :message-type="
                        appointmentForms[appointmentKey(appointment)].endsAt &&
                        !appointmentFormEndsAfterStart(
                          appointmentForms[appointmentKey(appointment)]
                        )
                          ? 'error'
                          : 'info'
                      "
                      @update:model-value="
                        appointmentForms[appointmentKey(appointment)].endsAt =
                          $event
                      "
                    />
                  </div>

                  <div class="scheduling-appointment-drawer-row">
                    <label
                      class="scheduling-appointment-drawer-label"
                      :for="`scheduling-conversation-appointment-service-amount-${appointment.id}`"
                    >
                      {{ $t('SCHEDULING.APPOINTMENT_FORM.SERVICE_AMOUNT') }}
                    </label>
                    <Input
                      :id="`scheduling-conversation-appointment-service-amount-${appointment.id}`"
                      class="scheduling-appointment-drawer-control"
                      custom-input-class="!rounded-md !bg-n-alpha-black2"
                      inputmode="numeric"
                      min="0"
                      step="1"
                      type="number"
                      :aria-label="
                        $t('SCHEDULING.APPOINTMENT_FORM.SERVICE_AMOUNT')
                      "
                      :model-value="
                        appointmentForms[appointmentKey(appointment)]
                          .serviceAmount
                      "
                      size="sm"
                      @update:model-value="
                        appointmentForms[
                          appointmentKey(appointment)
                        ].serviceAmount = $event
                      "
                    />
                  </div>
                </div>
              </div>

              <div class="flex items-center justify-end gap-2">
                <Button
                  size="sm"
                  color="blue"
                  :is-loading="
                    savingAppointmentKey === appointmentKey(appointment)
                  "
                  :disabled="
                    isAppointmentFormInvalid(
                      appointmentForms[appointmentKey(appointment)]
                    ) ||
                    patientActionBusyKey === appointmentKey(appointment) ||
                    cancellingAppointmentKey === appointmentKey(appointment)
                  "
                  :label="$t('SCHEDULING.GENERAL.SAVE')"
                  @click="saveAppointment(appointment)"
                />
              </div>
            </div>
          </div>
        </section>
      </div>
    </div>
  </div>
</template>

<style scoped>
.scheduling-appointment-drawer-form {
  @apply grid gap-3;
}

.scheduling-appointment-drawer-section {
  @apply grid gap-2 border-t border-n-weak pt-3;
}

.scheduling-appointment-drawer-section:first-of-type {
  @apply border-t-0 pt-0;
}

.scheduling-appointment-drawer-row {
  display: grid;
  gap: 0.375rem;
  min-width: 0;
}

.scheduling-appointment-drawer-label {
  @apply mb-0 min-w-0 text-[13px] font-medium leading-4 text-n-slate-12;
}

.scheduling-appointment-drawer-control,
.scheduling-appointment-drawer-form
  :deep(.scheduling-appointment-drawer-control) {
  width: 100%;
  min-width: 0;
}

.scheduling-appointment-drawer-form
  :deep(.scheduling-appointment-drawer-control input),
.scheduling-appointment-drawer-form
  :deep(.scheduling-appointment-drawer-control select),
.scheduling-appointment-drawer-form
  :deep(.scheduling-appointment-drawer-control .reka-date-time-picker__trigger),
.scheduling-appointment-drawer-form
  :deep(.scheduling-appointment-drawer-select-control button) {
  @apply border border-n-weak bg-n-alpha-black2 text-sm font-normal text-n-slate-12 shadow-none outline outline-1 outline-transparent transition-colors duration-150 !important;
  border-radius: 0.375rem !important;
  min-height: 2rem !important;
}

.scheduling-appointment-drawer-form
  :deep(.scheduling-appointment-drawer-control input),
.scheduling-appointment-drawer-form
  :deep(.scheduling-appointment-drawer-control select),
.scheduling-appointment-drawer-form
  :deep(.scheduling-appointment-drawer-control .reka-date-time-picker__trigger),
.scheduling-appointment-drawer-form
  :deep(.scheduling-appointment-drawer-select-control button) {
  height: 2rem !important;
}

.scheduling-appointment-drawer-form
  :deep(
    .scheduling-appointment-drawer-select-control.combobox-label-preview button
  ) {
  height: auto !important;
}

.scheduling-appointment-drawer-form
  :deep(.scheduling-appointment-drawer-control input) {
  @apply px-2 py-1 !important;
}

.scheduling-appointment-drawer-form
  :deep(.scheduling-appointment-drawer-control .reka-date-time-picker__trigger),
.scheduling-appointment-drawer-form
  :deep(.scheduling-appointment-drawer-select-control button) {
  @apply justify-start py-1 !important;
}

.scheduling-appointment-drawer-form
  :deep(.scheduling-appointment-drawer-control input:hover),
.scheduling-appointment-drawer-form
  :deep(.scheduling-appointment-drawer-control select:hover),
.scheduling-appointment-drawer-form
  :deep(
    .scheduling-appointment-drawer-control .reka-date-time-picker__trigger:hover
  ),
.scheduling-appointment-drawer-form
  :deep(.scheduling-appointment-drawer-select-control button:hover) {
  @apply border-n-slate-6 bg-n-alpha-black2 outline-transparent !important;
}

.scheduling-appointment-drawer-form
  :deep(.scheduling-appointment-drawer-control input:focus),
.scheduling-appointment-drawer-form
  :deep(.scheduling-appointment-drawer-control select:focus),
.scheduling-appointment-drawer-form
  :deep(
    .scheduling-appointment-drawer-control .reka-date-time-picker__trigger:focus
  ),
.scheduling-appointment-drawer-form
  :deep(
    .scheduling-appointment-drawer-control
      .reka-date-time-picker__trigger[data-state='open']
  ),
.scheduling-appointment-drawer-form
  :deep(.scheduling-appointment-drawer-select-control button:focus),
.scheduling-appointment-drawer-form
  :deep(
    .scheduling-appointment-drawer-select-control button[data-state='open']
  ) {
  @apply border-n-weak bg-n-alpha-black2 outline-n-brand !important;
}

.scheduling-appointment-drawer-value {
  @apply min-w-0 truncate text-sm font-normal text-n-slate-12;
}
</style>
