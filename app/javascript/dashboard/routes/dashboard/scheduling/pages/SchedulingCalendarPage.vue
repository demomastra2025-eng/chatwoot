<script setup>
import { computed, onMounted, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';

import { useAlert } from 'dashboard/composables';
import SchedulingAppointmentsAPI from 'dashboard/api/scheduling/appointments';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import PhoneNumberInput from 'dashboard/components-next/phonenumberinput/PhoneNumberInput.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import SchedulingCalendarGrid from 'dashboard/components-next/Scheduling/SchedulingCalendarGrid.vue';
import SchedulingDateTimeField from 'dashboard/components-next/Scheduling/SchedulingDateTimeField.vue';
import SchedulingDrawer from 'dashboard/components-next/Scheduling/SchedulingDrawer.vue';
import SchedulingErrorState from 'dashboard/components-next/Scheduling/SchedulingErrorState.vue';
import SchedulingFormFieldGroup from 'dashboard/components-next/Scheduling/SchedulingFormFieldGroup.vue';
import SchedulingMoneyInput from 'dashboard/components-next/Scheduling/SchedulingMoneyInput.vue';
import SchedulingMultiSelectFilter from 'dashboard/components-next/Scheduling/SchedulingMultiSelectFilter.vue';
import SchedulingResourceFilter from 'dashboard/components-next/Scheduling/SchedulingResourceFilter.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import SchedulingToolbar from 'dashboard/components-next/Scheduling/SchedulingToolbar.vue';
import SchedulingViewSwitcher from 'dashboard/components-next/Scheduling/SchedulingViewSwitcher.vue';
import {
  APPOINTMENT_STATUS_ICONS,
  APPOINTMENT_STATUS_VALUES,
} from '../constants';
import {
  formatSchedulingErrorMessage,
  normalizePayload,
} from 'dashboard/stores/scheduling/shared';
import { formatCalendarTitle } from '../helpers';
import { useSchedulingAppointmentFormStore } from 'dashboard/stores/scheduling/appointmentForm';
import { useSchedulingCalendarStore } from 'dashboard/stores/scheduling/calendar';
import { useSchedulingReferencesStore } from 'dashboard/stores/scheduling/references';

const { t, locale } = useI18n();
const calendarStore = useSchedulingCalendarStore();
const referencesStore = useSchedulingReferencesStore();
const formStore = useSchedulingAppointmentFormStore();
const currentPresentation = ref('calendar');
const contactEditorMode = ref(null);

const inlineContactForm = reactive({
  birthDate: '',
  fullName: '',
  gender: '',
  id: null,
  iin: '',
  phone: '',
});

const currentView = computed({
  get: () => calendarStore.currentView,
  set: async value => {
    calendarStore.setView(value);
    await calendarStore.fetchCalendar();
  },
});

const viewLabels = computed(() => ({
  day: t('SCHEDULING.VIEWS.DAY'),
  month: t('SCHEDULING.VIEWS.MONTH'),
  week: t('SCHEDULING.VIEWS.WEEK'),
}));

const presentationLabels = computed(() => ({
  calendar: t('SCHEDULING.VIEWS.CALENDAR'),
  kanban: t('SCHEDULING.VIEWS.KANBAN'),
  list: t('SCHEDULING.VIEWS.LIST'),
}));

const appointmentStatusLabels = computed(() => ({
  cancelled: t('SCHEDULING.APPOINTMENT_STATUS.cancelled'),
  completed: t('SCHEDULING.APPOINTMENT_STATUS.completed'),
  confirmed: t('SCHEDULING.APPOINTMENT_STATUS.confirmed'),
  no_show: t('SCHEDULING.APPOINTMENT_STATUS.no_show'),
  scheduled: t('SCHEDULING.APPOINTMENT_STATUS.scheduled'),
}));

const formatErrorMessage = error => formatSchedulingErrorMessage(error, t);

const calendarErrorDescription = computed(() =>
  formatErrorMessage(calendarStore.ui.error)
);

const formErrorMessage = computed(() => formatErrorMessage(formStore.ui.error));

const validationErrorMessage = key => {
  const labels = {
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
  ['calendar', 'list', 'kanban'].map(value => ({
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
  referencesStore.services.map(service => ({
    label: service.name,
    value: service.id,
  }))
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
    label: appointmentStatusLabels.value[value] || value,
    value,
  }))
);

const genderOptions = computed(() => [
  { label: t('SCHEDULING.CONTACT.GENDER.MALE'), value: 'male' },
  { label: t('SCHEDULING.CONTACT.GENDER.FEMALE'), value: 'female' },
  { label: t('SCHEDULING.CONTACT.GENDER.OTHER'), value: 'other' },
  { label: t('SCHEDULING.CONTACT.GENDER.UNKNOWN'), value: 'unknown' },
]);

const selectedStatusFilters = computed(() => calendarStore.statusFilters);
const isContactEditorOpen = computed(() => !!contactEditorMode.value);
const isEditingContact = computed(() => contactEditorMode.value === 'edit');

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

const contactEditorTitle = computed(() =>
  isEditingContact.value
    ? t('SCHEDULING.CONTACT.EDIT_TITLE')
    : t('SCHEDULING.CONTACT.QUICK_CREATE_TITLE')
);

const contactEditorActionLabel = computed(() =>
  isEditingContact.value
    ? t('SCHEDULING.CONTACT.EDIT_ACTION')
    : t('SCHEDULING.CONTACT.CREATE_ACTION')
);

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
    referencesStore.loadResources({ include_inactive: true }),
    referencesStore.loadServices({ include_inactive: true }),
  ]);
  syncSelectedResources();
  await calendarStore.fetchCalendar();
};

const handleAnchorDateSelect = async nextDate => {
  if (!nextDate) return;

  calendarStore.setAnchorDate(nextDate.toISOString());
  await calendarStore.fetchCalendar();
};

const openNewAppointment = () => {
  const preferredResources = calendarStore.visibleResources.length
    ? calendarStore.visibleResources
    : calendarStore.resources;
  const primaryResource = preferredResources[0] || null;
  const primaryResourceId = primaryResource?.id || '';
  const primaryDurationMin = Math.max(
    5,
    Number(primaryResource?.slotDurationMin) || 30
  );
  const now = new Date();

  const nextSlot =
    calendarStore.slots
      .filter(slot => {
        return (
          (!primaryResourceId ||
            Number(slot.resourceId) === Number(primaryResourceId)) &&
          new Date(slot.endsAt) > now
        );
      })
      .sort(
        (left, right) => new Date(left.startsAt) - new Date(right.startsAt)
      )[0] ||
    calendarStore.slots
      .filter(slot => new Date(slot.endsAt) > now)
      .sort(
        (left, right) => new Date(left.startsAt) - new Date(right.startsAt)
      )[0] ||
    null;

  const startsAt = nextSlot ? new Date(nextSlot.startsAt) : new Date(now);
  if (!nextSlot) {
    startsAt.setMinutes(Math.ceil(startsAt.getMinutes() / 5) * 5, 0, 0);
  }

  const endsAt = nextSlot ? new Date(nextSlot.endsAt) : new Date(startsAt);
  if (!nextSlot) {
    endsAt.setMinutes(endsAt.getMinutes() + primaryDurationMin);
  }

  formStore.openCreate({
    endsAt: endsAt.toISOString(),
    resourceId: nextSlot?.resourceId || primaryResourceId,
    startsAt: startsAt.toISOString(),
  });
};

const handleDrawerClose = () => {
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

  try {
    if (isEditingContact.value) {
      await formStore.updateInlineContact(
        formStore.form.contactId,
        inlineContactForm
      );
      useAlert(t('SCHEDULING.CONTACT.SUCCESS_UPDATE'));
    } else {
      await formStore.createInlineContact(inlineContactForm);
      useAlert(t('SCHEDULING.CONTACT.SUCCESS_CREATE'));
    }

    closeInlineContactEditor();
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

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

const handleStatusFiltersChange = async values => {
  calendarStore.setStatusFilters(values);
  await calendarStore.fetchCalendar();
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
  [() => formStore.form.serviceId, () => formStore.form.resourceId],
  ([serviceId, resourceId]) => {
    if (!serviceId || !resourceId) return;
    formStore.syncServicePricing(referencesStore.services);
  }
);

onMounted(async () => {
  calendarStore.hydratePreferences();
  currentPresentation.value = 'calendar';
  await loadPage();
});
</script>

<template>
  <section class="flex flex-col flex-1 min-h-0 overflow-hidden bg-n-surface-1">
    <SchedulingToolbar
      v-model="currentView"
      :anchor-date="calendarStore.anchorDate"
      :current-label="pageTitle"
      :views="calendarTypeViews"
      @previous="
        calendarStore.shiftAnchor(-1);
        calendarStore.fetchCalendar();
      "
      @next="
        calendarStore.shiftAnchor(1);
        calendarStore.fetchCalendar();
      "
      @today="
        calendarStore.setAnchorDate(new Date().toISOString());
        calendarStore.fetchCalendar();
      "
      @select-date="handleAnchorDateSelect"
    >
      <template #filters>
        <SchedulingViewSwitcher
          v-model="currentPresentation"
          :views="presentationOptions"
        />
      </template>
      <template #actions>
        <Button
          size="sm"
          :label="$t('SCHEDULING.CALENDAR.NEW_APPOINTMENT')"
          icon="i-lucide-plus"
          @click="openNewAppointment"
        />
      </template>
    </SchedulingToolbar>

    <div class="bg-n-surface-1 px-5 pb-2 pt-1.5">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <SchedulingResourceFilter
          :resources="filterableResources"
          :model-value="calendarStore.selectedResourceIds"
          @update:model-value="
            calendarStore.setSelectedResources($event);
            calendarStore.fetchCalendar();
          "
        />
        <SchedulingMultiSelectFilter
          :model-value="selectedStatusFilters"
          :options="appointmentStatusOptions"
          :placeholder="$t('SCHEDULING.TOOLBAR.STATUS')"
          @update:model-value="handleStatusFiltersChange"
        />
      </div>
    </div>

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
          :appointments="calendarStore.appointments"
          :break-rules="calendarStore.breakRules"
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
          @create-appointment="formStore.openCreate($event)"
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
          @select-appointment="formStore.openEdit($event)"
        />
      </div>
    </div>

    <SchedulingDrawer
      v-model="formStore.isOpen"
      width="lg"
      :title="drawerTitle"
      :confirm-label="drawerConfirmLabel"
      :is-loading="formStore.ui.isSaving"
      :disable-confirm="formStore.isFormInvalid"
      @close="handleDrawerClose"
      @confirm="handleAppointmentSubmit"
    >
      <div class="flex flex-col gap-6">
        <div
          v-if="formStore.ui.error"
          class="px-4 py-3 text-sm rounded-xl bg-n-ruby-3/70 text-n-ruby-11"
        >
          {{ formErrorMessage }}
        </div>

        <SchedulingFormFieldGroup
          :framed="false"
          :title="$t('SCHEDULING.APPOINTMENT_FORM.CONTACT_TITLE')"
          :description="$t('SCHEDULING.APPOINTMENT_FORM.CONTACT_DESCRIPTION')"
        >
          <div class="flex flex-wrap items-center gap-2">
            <div class="flex shrink-0 items-center">
              <Button
                size="sm"
                variant="outline"
                color="slate"
                icon="i-lucide-plus"
                :aria-label="$t('SCHEDULING.CONTACT.CREATE_ACTION')"
                @click="openInlineContactCreate"
              />
            </div>

            <div class="min-w-[18rem] max-w-full flex-1">
              <SchedulingSelectField
                class="w-full"
                :model-value="formStore.form.contactId"
                :options="contactOptions"
                use-api-results
                :placeholder="$t('SCHEDULING.APPOINTMENT_FORM.CONTACT')"
                :search-placeholder="
                  $t('SCHEDULING.APPOINTMENT_FORM.CONTACT_SEARCH')
                "
                :empty-state="$t('SCHEDULING.APPOINTMENT_FORM.CONTACT_EMPTY')"
                @open="handleContactDropdownOpen"
                @search="formStore.searchContacts($event)"
                @update:model-value="
                  formStore.updateField('contactId', $event);
                  handleContactSelect($event);
                "
              >
                <template #append>
                  <Button
                    v-if="formStore.form.contactId"
                    size="xs"
                    variant="ghost"
                    color="slate"
                    icon="i-lucide-pencil"
                    class="!h-6 !w-6 !rounded-md !p-0"
                    :aria-label="$t('SCHEDULING.CONTACT.EDIT_ACTION')"
                    @click.stop="openInlineContactEdit"
                  />
                </template>
              </SchedulingSelectField>
            </div>
          </div>

          <div
            v-if="isContactEditorOpen"
            class="grid gap-4 rounded-2xl bg-n-surface-1 p-4 outline outline-1 outline-n-container"
          >
            <div class="flex items-center justify-between gap-3">
              <h4 class="mb-0 text-sm font-semibold text-n-slate-12">
                {{ contactEditorTitle }}
              </h4>
              <Button
                size="xs"
                variant="ghost"
                color="slate"
                icon="i-lucide-x"
                @click="closeInlineContactEditor"
              />
            </div>

            <div class="grid gap-4 md:grid-cols-2">
              <Input
                v-model="inlineContactForm.fullName"
                autocomplete="name"
                :label="$t('SCHEDULING.CONTACT.FULL_NAME')"
              />
              <PhoneNumberInput
                v-model="inlineContactForm.phone"
                default-country="KZ"
                :max-digits="11"
                :label="$t('SCHEDULING.CONTACT.PHONE')"
                size="md"
              />
              <div
                class="grid gap-4 md:col-span-2 md:grid-cols-[minmax(0,8fr)_minmax(0,7fr)_minmax(0,5fr)]"
              >
                <Input
                  v-model="inlineContactForm.iin"
                  inputmode="numeric"
                  maxlength="12"
                  custom-input-class="tabular-nums"
                  :label="$t('SCHEDULING.CONTACT.IIN')"
                  :message="inlineContactIinMessage"
                  :message-type="inlineContactIinMessage ? 'error' : 'info'"
                />
                <SchedulingDateTimeField
                  v-model="inlineContactForm.birthDate"
                  type="date"
                  :label="$t('SCHEDULING.CONTACT.BIRTH_DATE')"
                />
                <SchedulingSelectField
                  :model-value="inlineContactForm.gender"
                  :options="genderOptions"
                  :label="$t('SCHEDULING.CONTACT.GENDER_LABEL')"
                  :placeholder="$t('SCHEDULING.CONTACT.GENDER_LABEL')"
                  @update:model-value="inlineContactForm.gender = $event"
                />
              </div>
            </div>

            <div class="flex justify-end">
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
        </SchedulingFormFieldGroup>

        <SchedulingFormFieldGroup
          :framed="false"
          :title="$t('SCHEDULING.APPOINTMENT_FORM.APPOINTMENT_TITLE')"
          :description="
            $t('SCHEDULING.APPOINTMENT_FORM.APPOINTMENT_DESCRIPTION')
          "
        >
          <div class="grid gap-4 md:grid-cols-2">
            <SchedulingSelectField
              :model-value="formStore.form.resourceId"
              :options="resourceOptions"
              :placeholder="$t('SCHEDULING.APPOINTMENT_FORM.RESOURCE')"
              :message="
                formStore.validationErrors.resourceId
                  ? validationErrorMessage(
                      formStore.validationErrors.resourceId
                    )
                  : ''
              "
              :has-error="!!formStore.validationErrors.resourceId"
              @update:model-value="formStore.updateField('resourceId', $event)"
            />
            <SchedulingSelectField
              :model-value="formStore.form.serviceId"
              :options="serviceOptions"
              :placeholder="$t('SCHEDULING.APPOINTMENT_FORM.SERVICE')"
              @update:model-value="formStore.updateField('serviceId', $event)"
            />
            <div class="grid gap-4 md:col-span-2 md:grid-cols-3">
              <SchedulingSelectField
                :model-value="formStore.form.status"
                :options="appointmentStatusOptions"
                :label="$t('SCHEDULING.APPOINTMENT_FORM.STATUS')"
                :placeholder="$t('SCHEDULING.APPOINTMENT_FORM.STATUS')"
                @update:model-value="formStore.updateField('status', $event)"
              />
              <SchedulingMoneyInput
                v-model="formStore.form.serviceAmount"
                min="0"
                :label="$t('SCHEDULING.APPOINTMENT_FORM.SERVICE_AMOUNT')"
              />
              <SchedulingMoneyInput
                v-model="formStore.form.prepaidAmount"
                min="0"
                :label="$t('SCHEDULING.APPOINTMENT_FORM.PREPAID_AMOUNT')"
                :message="
                  formStore.validationErrors.prepaidAmount
                    ? validationErrorMessage(
                        formStore.validationErrors.prepaidAmount
                      )
                    : ''
                "
                :message-type="
                  formStore.validationErrors.prepaidAmount ? 'error' : 'info'
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
                    ? validationErrorMessage(formStore.validationErrors.endsAt)
                    : ''
                "
                :message-type="
                  formStore.validationErrors.endsAt ? 'error' : 'info'
                "
              />
            </div>
          </div>
        </SchedulingFormFieldGroup>

        <SchedulingFormFieldGroup :framed="false">
          <TextArea
            v-model="formStore.form.clientComment"
            auto-height
            :label="$t('SCHEDULING.APPOINTMENT_FORM.COMMENT')"
            :placeholder="$t('SCHEDULING.APPOINTMENT_FORM.COMMENT_PLACEHOLDER')"
          />
        </SchedulingFormFieldGroup>
      </div>

      <template #footer>
        <div class="flex items-center justify-between w-full gap-3">
          <div class="flex items-center gap-2">
            <Button
              size="sm"
              variant="faded"
              color="slate"
              :label="$t('SCHEDULING.GENERAL.CANCEL')"
              @click="handleDrawerClose"
            />
            <Button
              v-if="formStore.mode === 'edit'"
              size="sm"
              variant="faded"
              color="ruby"
              :is-loading="formStore.ui.isSaving"
              :label="$t('SCHEDULING.APPOINTMENT_FORM.CANCEL_APPOINTMENT')"
              @click="handleAppointmentCancel"
            />
          </div>
          <Button
            size="sm"
            :is-loading="formStore.ui.isSaving"
            :disabled="formStore.isFormInvalid || formStore.ui.isSaving"
            :label="drawerConfirmLabel"
            @click="handleAppointmentSubmit"
          />
        </div>
      </template>
    </SchedulingDrawer>
  </section>
</template>
