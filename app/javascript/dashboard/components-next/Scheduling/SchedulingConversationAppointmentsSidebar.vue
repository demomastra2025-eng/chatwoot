<script setup>
import { computed, nextTick, onMounted, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';

import SchedulingAppointmentsAPI from 'dashboard/api/scheduling/appointments';
import SidebarActionsHeader from 'dashboard/components-next/SidebarActionsHeader.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import SchedulingDateTimeField from 'dashboard/components-next/Scheduling/SchedulingDateTimeField.vue';
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
import { useSchedulingReferencesStore } from 'dashboard/stores/scheduling/references';
import {
  fromDateTimeInputValue,
  getServicePriceForResource,
  toDateTimeInputValue,
} from 'dashboard/routes/dashboard/scheduling/helpers';
import {
  APPOINTMENT_STATUS_ICONS,
  APPOINTMENT_STATUS_ICON_CLASSES,
  APPOINTMENT_STATUS_RAIL_CLASSES,
  APPOINTMENT_STATUS_VALUES,
} from 'dashboard/routes/dashboard/scheduling/constants';

const props = defineProps({
  currentChat: {
    required: true,
    type: Object,
  },
});

const emit = defineEmits(['close']);

const NEW_APPOINTMENT_KEY = 'new-appointment';

const { t, locale } = useI18n();
const store = useStore();
const schedulingReferencesStore = useSchedulingReferencesStore();

const appointments = ref([]);
const appointmentForms = reactive({});
const openAppointmentKeys = ref([]);
const scrollContainer = ref(null);
const isCreating = ref(false);
const isSavingCreate = ref(false);
const savingAppointmentKey = ref('');
const createForm = reactive({
  clientName: '',
  clientPhone: '',
  endsAt: '',
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
  isCreating.value
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
    value: service.id,
  }))
);
const hasServiceOptions = computed(() => serviceOptions.value.length > 0);

const contact = computed(() => resolveChatContact(props.currentChat));
const contactId = computed(() => resolveChatContactId(props.currentChat));

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
    contact.value?.name ||
    contact.value?.fullName ||
    contact.value?.full_name ||
    ''
);
const contactPhone = computed(
  () =>
    contact.value?.phone_number ||
    contact.value?.phoneNumber ||
    contact.value?.phone ||
    ''
);

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
    endsAt: toDateTimeInputValue(endsAt),
    startsAt: toDateTimeInputValue(startsAt),
  };
};

const resetCreateForm = () => {
  const primaryResource = activeResources.value[0];
  const defaults = buildDefaultAppointmentTimes();

  Object.assign(createForm, {
    clientName: contactName.value,
    clientPhone: contactPhone.value,
    endsAt: defaults.endsAt,
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

const appointmentKey = appointment => `appointment-${appointment.id}`;
const isAppointmentOpen = appointment =>
  openAppointmentKeys.value.includes(appointmentKey(appointment));

const statusIconClass = appointment =>
  APPOINTMENT_STATUS_ICON_CLASSES[appointment.status] ||
  APPOINTMENT_STATUS_ICON_CLASSES.scheduled;

const statusAccentClass = status =>
  APPOINTMENT_STATUS_RAIL_CLASSES[status] || 'text-n-slate-9';

const appointmentStatusAccentClass = appointment =>
  statusAccentClass(appointment.status);

const statusIcon = appointment =>
  APPOINTMENT_STATUS_ICONS[appointment.status] ||
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

const formFromAppointment = appointment => ({
  appointmentType: appointment.appointmentType || 'primary',
  clientName: appointment.clientName || '',
  clientPhone: appointment.clientPhone || '',
  contactId: appointment.contactId || contactId.value || '',
  conversationDisplayId:
    appointment.conversationDisplayId ||
    createConversationDisplayId.value ||
    '',
  conversationId: appointment.conversationId || '',
  endsAt: toDateTimeInputValue(appointment.endsAt),
  resourceId: appointment.resourceId || '',
  serviceAmount:
    appointment.serviceAmount === null ||
    typeof appointment.serviceAmount === 'undefined'
      ? ''
      : String(appointment.serviceAmount),
  serviceId: appointment.serviceId || '',
  serviceNameSnapshot: appointment.serviceNameSnapshot || '',
  startsAt: toDateTimeInputValue(appointment.startsAt),
  status: appointment.status || 'scheduled',
});

const setAppointmentForms = () => {
  Object.keys(appointmentForms).forEach(key => delete appointmentForms[key]);
  appointments.value.forEach(appointment => {
    appointmentForms[appointmentKey(appointment)] =
      formFromAppointment(appointment);
  });
};

const selectedServiceForForm = form =>
  activeServices.value.find(
    service => Number(service.id) === Number(form?.serviceId)
  );

const selectedResourceForForm = form =>
  activeResources.value.find(
    resource => Number(resource.id) === Number(form?.resourceId)
  );

const updateFormEndFromDuration = form => {
  if (!form?.startsAt) return;

  const startsAt = new Date(form.startsAt);
  if (Number.isNaN(startsAt.getTime())) return;

  const durationMin = Math.max(
    Number(selectedServiceForForm(form)?.durationMin) ||
      Number(selectedResourceForForm(form)?.slotDurationMin) ||
      30,
    5
  );
  const endsAt = new Date(startsAt);
  endsAt.setMinutes(endsAt.getMinutes() + durationMin);
  form.endsAt = toDateTimeInputValue(endsAt);
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

  return servicePayload;
};

const appointmentFormEndsAfterStart = form => {
  if (!form?.startsAt || !form?.endsAt) return false;

  return new Date(form.endsAt) > new Date(form.startsAt);
};

const isAppointmentFormInvalid = form =>
  !contactId.value ||
  !form?.clientName?.trim() ||
  !form?.resourceId ||
  !form?.startsAt ||
  !form?.endsAt ||
  !appointmentFormEndsAfterStart(form);

const buildAppointmentPayload = form =>
  appendServicePayload(
    {
      appointment_type: form.appointmentType || 'primary',
      client_name: form.clientName,
      client_phone: form.clientPhone,
      contact_id: toNumeric(form.contactId || contactId.value),
      conversation_display_id: toNumeric(
        form.conversationId
          ? null
          : form.conversationDisplayId || createConversationDisplayId.value
      ),
      conversation_id: toNumeric(form.conversationId),
      ends_at: fromDateTimeInputValue(form.endsAt),
      resource_id: toNumeric(form.resourceId),
      service_amount:
        toIntegerNumeric(form.serviceAmount || 0, 'service_amount') || 0,
      source: 'conversation',
      starts_at: fromDateTimeInputValue(form.startsAt),
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
      client_name: createForm.clientName,
      client_phone: createForm.clientPhone,
      contact_id: toNumeric(contactId.value),
      conversation_display_id: toNumeric(createConversationDisplayId.value),
      ends_at: fromDateTimeInputValue(createForm.endsAt),
      resource_id: toNumeric(createForm.resourceId),
      service_amount:
        toIntegerNumeric(createForm.serviceAmount || 0, 'service_amount') || 0,
      source: 'conversation',
      starts_at: fromDateTimeInputValue(createForm.startsAt),
      status: createForm.status || 'scheduled',
    },
    {
      serviceId: createForm.serviceId,
      serviceNameSnapshot: createForm.serviceNameSnapshot,
    }
  );

const upsertAppointment = appointment => {
  appointments.value = mergeUniqueAppointments(
    [appointment],
    appointments.value
  );
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

const loadAppointments = async () => {
  if (!lookupParams.value.length) {
    appointments.value = [];
    setAppointmentForms();
    return;
  }

  ui.isLoading = true;
  ui.error = null;

  try {
    const results = await Promise.all(
      lookupParams.value.map(params => fetchAppointmentsByParams(params))
    );
    appointments.value = mergeUniqueAppointments(...results);
    setAppointmentForms();
    openAppointmentKeys.value = appointments.value[0]
      ? [appointmentKey(appointments.value[0])]
      : [];
  } catch (error) {
    ui.error = error;
  } finally {
    ui.isLoading = false;
  }
};

const toggleAppointment = appointment => {
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

  const startsAt = new Date(createForm.startsAt);
  if (Number.isNaN(startsAt.getTime())) return;

  const durationMin = Math.max(
    Number(selectedCreateService.value?.durationMin) ||
      Number(selectedCreateResource.value?.slotDurationMin) ||
      30,
    5
  );
  const endsAt = new Date(startsAt);
  endsAt.setMinutes(endsAt.getMinutes() + durationMin);
  createForm.endsAt = toDateTimeInputValue(endsAt);
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
  syncCreateServiceFields();
};

const handleCreateServiceChange = value => {
  createForm.serviceId = value;
  createForm.serviceNameSnapshot = '';
  syncCreateServiceFields();
};

const startCreateAppointment = async ({ scroll = true } = {}) => {
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
  openAppointmentKeys.value = openAppointmentKeys.value.filter(
    key => key !== NEW_APPOINTMENT_KEY
  );
};

const createFormEndsAfterStart = computed(() => {
  if (!createForm.startsAt || !createForm.endsAt) return false;

  return new Date(createForm.endsAt) > new Date(createForm.startsAt);
});

const isCreateFormInvalid = computed(
  () =>
    !contactId.value ||
    !createForm.clientName?.trim() ||
    !createForm.resourceId ||
    !createForm.startsAt ||
    !createForm.endsAt ||
    !createFormEndsAfterStart.value
);

const refreshDialogAppointments = savedAppointment => {
  upsertAppointment(savedAppointment);
  isCreating.value = false;
  openAppointmentKeys.value = [appointmentKey(savedAppointment)];
};

const saveCreateAppointment = async () => {
  if (isCreateFormInvalid.value) return;

  isSavingCreate.value = true;
  try {
    const response =
      await SchedulingAppointmentsAPI.create(buildCreatePayload());
    const savedAppointment = normalizePayload(response.data);
    refreshDialogAppointments(savedAppointment);
    refreshSidebarCounters();
    useAlert(t('SCHEDULING.APPOINTMENT_FORM.SUCCESS_SAVE'));
  } catch (error) {
    useAlert(formatSchedulingErrorMessage(error, t));
  } finally {
    isSavingCreate.value = false;
  }
};

const saveAppointment = async appointment => {
  const key = appointmentKey(appointment);
  const form = appointmentForms[key];
  if (isAppointmentFormInvalid(form)) return;

  savingAppointmentKey.value = key;
  try {
    const response = await SchedulingAppointmentsAPI.update(
      appointment.id,
      buildAppointmentPayload(form)
    );
    const savedAppointment = normalizePayload(response.data);
    upsertAppointment(savedAppointment);
    openAppointmentKeys.value = [appointmentKey(savedAppointment)];
    refreshSidebarCounters();
    useAlert(t('SCHEDULING.APPOINTMENT_FORM.SUCCESS_SAVE'));
  } catch (error) {
    useAlert(formatSchedulingErrorMessage(error, t));
  } finally {
    savingAppointmentKey.value = '';
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
  }).format(start);
  const startTime = new Intl.DateTimeFormat(locale.value, {
    hour: '2-digit',
    minute: '2-digit',
  }).format(start);
  const endTime =
    end && !Number.isNaN(end.getTime())
      ? new Intl.DateTimeFormat(locale.value, {
          hour: '2-digit',
          minute: '2-digit',
        }).format(end)
      : '';

  return endTime
    ? `${dateLabel}, ${startTime}–${endTime}`
    : `${dateLabel}, ${startTime}`;
};

const appointmentTitle = appointment =>
  appointment.clientName ||
  appointment.serviceNameSnapshot ||
  t('SCHEDULING.CALENDAR.NO_SERVICE');

const appointmentMeta = appointment => {
  const serviceName =
    appointment.serviceNameSnapshot || t('SCHEDULING.CALENDAR.NO_SERVICE');
  return `${formatDateTimeRange(appointment)} · ${serviceName}`;
};

const initializeSidebar = async () => {
  try {
    await Promise.all([
      schedulingReferencesStore.loadResources(),
      schedulingReferencesStore.loadServices(),
    ]);
  } catch {
    // Keep the appointments list usable even if optional references fail.
  }

  await loadAppointments();
  if (!appointments.value.length) {
    await startCreateAppointment({ scroll: false });
  }
};

onMounted(() => {
  initializeSidebar();
});

watch(
  () => [
    props.currentChat?.id,
    props.currentChat?.contact_id,
    props.currentChat?.contactId,
  ],
  async () => {
    isCreating.value = false;
    await loadAppointments();
    if (!appointments.value.length) {
      await startCreateAppointment({ scroll: false });
    }
  }
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

      <div v-else-if="ui.error" class="px-4 py-6 text-sm text-n-ruby-11">
        {{ $t('SCHEDULING.DIALOGS.ERROR') }}
      </div>

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
              class="appointment-status-dashed-rail shrink-0 self-stretch rounded-full"
              :class="statusAccentClass(createForm.status)"
            />
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
                      for="scheduling-conversation-appointment-client-name"
                    >
                      {{ $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_NAME') }}
                    </label>
                    <Input
                      id="scheduling-conversation-appointment-client-name"
                      class="scheduling-appointment-drawer-control"
                      custom-input-class="!rounded-md !bg-n-alpha-black2"
                      :aria-label="
                        $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_NAME')
                      "
                      :model-value="createForm.clientName"
                      size="sm"
                      @update:model-value="createForm.clientName = $event"
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
                      size="sm"
                      @update:model-value="createForm.clientPhone = $event"
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

                  <div class="scheduling-appointment-drawer-row">
                    <label
                      class="scheduling-appointment-drawer-label"
                      for="scheduling-conversation-appointment-service"
                    >
                      {{ $t('SCHEDULING.APPOINTMENT_FORM.SERVICE') }}
                    </label>
                    <SchedulingSelectField
                      v-if="hasServiceOptions"
                      id="scheduling-conversation-appointment-service"
                      class="scheduling-appointment-drawer-control scheduling-appointment-drawer-select-control"
                      :aria-label="$t('SCHEDULING.APPOINTMENT_FORM.SERVICE')"
                      :model-value="createForm.serviceId"
                      :options="serviceOptions"
                      :placeholder="$t('SCHEDULING.APPOINTMENT_FORM.SERVICE')"
                      :empty-state="
                        $t('SCHEDULING.APPOINTMENT_FORM.SERVICE_EMPTY')
                      "
                      dropdown-placement="auto"
                      @update:model-value="handleCreateServiceChange"
                    />
                    <Input
                      v-else
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
            class="flex w-full p-0 text-left hover:bg-n-alpha-1 rtl:text-right"
            @click="toggleAppointment(appointment)"
          >
            <span
              class="appointment-status-dashed-rail shrink-0 self-stretch rounded-full"
              :class="appointmentStatusAccentClass(appointment)"
            />
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
                </span>
              </span>
              <span
                class="i-lucide-chevron-down mt-0.5 size-4 shrink-0 text-n-slate-10 transition-transform"
                :class="{ 'rotate-180': isAppointmentOpen(appointment) }"
              />
            </span>
          </button>

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
                      :for="`scheduling-conversation-appointment-client-name-${appointment.id}`"
                    >
                      {{ $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_NAME') }}
                    </label>
                    <Input
                      :id="`scheduling-conversation-appointment-client-name-${appointment.id}`"
                      class="scheduling-appointment-drawer-control"
                      custom-input-class="!rounded-md !bg-n-alpha-black2"
                      :aria-label="
                        $t('SCHEDULING.APPOINTMENT_FORM.CLIENT_NAME')
                      "
                      :model-value="
                        appointmentForms[appointmentKey(appointment)].clientName
                      "
                      size="sm"
                      @update:model-value="
                        appointmentForms[
                          appointmentKey(appointment)
                        ].clientName = $event
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
                      size="sm"
                      @update:model-value="
                        appointmentForms[
                          appointmentKey(appointment)
                        ].clientPhone = $event
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

                  <div class="scheduling-appointment-drawer-row">
                    <label
                      class="scheduling-appointment-drawer-label"
                      :for="`scheduling-conversation-appointment-service-${appointment.id}`"
                    >
                      {{ $t('SCHEDULING.APPOINTMENT_FORM.SERVICE') }}
                    </label>
                    <SchedulingSelectField
                      v-if="hasServiceOptions"
                      :id="`scheduling-conversation-appointment-service-${appointment.id}`"
                      class="scheduling-appointment-drawer-control scheduling-appointment-drawer-select-control"
                      :aria-label="$t('SCHEDULING.APPOINTMENT_FORM.SERVICE')"
                      :model-value="
                        appointmentForms[appointmentKey(appointment)].serviceId
                      "
                      :options="serviceOptions"
                      :placeholder="$t('SCHEDULING.APPOINTMENT_FORM.SERVICE')"
                      :empty-state="
                        $t('SCHEDULING.APPOINTMENT_FORM.SERVICE_EMPTY')
                      "
                      dropdown-placement="auto"
                      @update:model-value="
                        handleFormServiceChange(
                          appointmentForms[appointmentKey(appointment)],
                          $event
                        )
                      "
                    />
                    <Input
                      v-else
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
                    )
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
.appointment-status-dashed-rail {
  width: 0.125rem;
  margin-block: 0.25rem;
  border-radius: 9999px;
  background-image: repeating-linear-gradient(
    to bottom,
    currentColor 0,
    currentColor 0.5rem,
    transparent 0.5rem,
    transparent 0.75rem
  );
  background-position: center;
  background-repeat: repeat-y;
}

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

@media (min-width: 768px) {
  .scheduling-appointment-drawer-row {
    align-items: center;
    grid-template-columns: minmax(6.5rem, 1fr) minmax(8rem, 14rem);
  }

  .scheduling-appointment-drawer-label {
    @apply text-left;
  }
}
</style>
