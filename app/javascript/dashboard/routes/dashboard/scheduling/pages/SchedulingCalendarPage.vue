<script setup>
import { computed, onMounted, reactive, watch } from 'vue';
import { useI18n } from 'vue-i18n';

import { useAlert } from 'dashboard/composables';
import SchedulingAppointmentsAPI from 'dashboard/api/scheduling/appointments';
import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import SchedulingCalendarGrid from 'dashboard/components-next/Scheduling/SchedulingCalendarGrid.vue';
import SchedulingDateTimeField from 'dashboard/components-next/Scheduling/SchedulingDateTimeField.vue';
import SchedulingDrawer from 'dashboard/components-next/Scheduling/SchedulingDrawer.vue';
import SchedulingErrorState from 'dashboard/components-next/Scheduling/SchedulingErrorState.vue';
import SchedulingFormFieldGroup from 'dashboard/components-next/Scheduling/SchedulingFormFieldGroup.vue';
import SchedulingPageHeader from 'dashboard/components-next/Scheduling/SchedulingPageHeader.vue';
import SchedulingResourceFilter from 'dashboard/components-next/Scheduling/SchedulingResourceFilter.vue';
import SchedulingToolbar from 'dashboard/components-next/Scheduling/SchedulingToolbar.vue';
import {
  APPOINTMENT_STATUS_VALUES,
  APPOINTMENT_TYPE_VALUES,
  PAYMENT_STATUS_VALUES,
  SCHEDULING_VIEWS,
} from '../constants';
import {
  extractSchedulingError,
  normalizePayload,
} from 'dashboard/stores/scheduling/shared';
import { formatCalendarTitle } from '../helpers';
import { useSchedulingAppointmentFormStore } from 'dashboard/stores/scheduling/appointmentForm';
import { useSchedulingCalendarStore } from 'dashboard/stores/scheduling/calendar';
import { useSchedulingReferencesStore } from 'dashboard/stores/scheduling/references';

const { t } = useI18n();

const calendarStore = useSchedulingCalendarStore();
const referencesStore = useSchedulingReferencesStore();
const formStore = useSchedulingAppointmentFormStore();

const inlineContactForm = reactive({
  birthDate: '',
  fullName: '',
  gender: '',
  identifier: '',
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
  list: t('SCHEDULING.VIEWS.LIST'),
  month: t('SCHEDULING.VIEWS.MONTH'),
  week: t('SCHEDULING.VIEWS.WEEK'),
}));

const appointmentStatusLabels = computed(() => ({
  cancelled: t('SCHEDULING.APPOINTMENT_STATUS.cancelled'),
  completed: t('SCHEDULING.APPOINTMENT_STATUS.completed'),
  confirmed: t('SCHEDULING.APPOINTMENT_STATUS.confirmed'),
  no_show: t('SCHEDULING.APPOINTMENT_STATUS.no_show'),
  scheduled: t('SCHEDULING.APPOINTMENT_STATUS.scheduled'),
}));

const paymentStatusLabels = computed(() => ({
  awaiting_payment: t('SCHEDULING.PAYMENT_STATUS.awaiting_payment'),
  cancelled: t('SCHEDULING.PAYMENT_STATUS.cancelled'),
  paid: t('SCHEDULING.PAYMENT_STATUS.paid'),
  prepaid: t('SCHEDULING.PAYMENT_STATUS.prepaid'),
}));

const appointmentTypeLabels = computed(() => ({
  other: t('SCHEDULING.APPOINTMENT_TYPE.other'),
  primary: t('SCHEDULING.APPOINTMENT_TYPE.primary'),
  secondary: t('SCHEDULING.APPOINTMENT_TYPE.secondary'),
}));

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

const translatedViews = computed(() =>
  SCHEDULING_VIEWS.map(view => ({
    ...view,
    label: viewLabels.value[view.value] || view.value,
  }))
);

const pageTitle = computed(() =>
  formatCalendarTitle(calendarStore.currentView, calendarStore.anchorDate)
);

const resourceOptions = computed(() =>
  calendarStore.resources.map(resource => ({
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

const contactOptions = computed(() =>
  formStore.contacts.map(contact => ({
    label: [contact.fullName, contact.phone].filter(Boolean).join(' · '),
    value: contact.id,
  }))
);

const appointmentStatusOptions = computed(() =>
  APPOINTMENT_STATUS_VALUES.map(value => ({
    label: appointmentStatusLabels.value[value] || value,
    value,
  }))
);

const paymentStatusOptions = computed(() =>
  PAYMENT_STATUS_VALUES.map(value => ({
    label: paymentStatusLabels.value[value] || value,
    value,
  }))
);

const appointmentTypeOptions = computed(() =>
  APPOINTMENT_TYPE_VALUES.map(value => ({
    label: appointmentTypeLabels.value[value] || value,
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
const selectedPaymentStatusFilters = computed(
  () => calendarStore.paymentStatusFilters
);

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

const resetInlineContactForm = () => {
  Object.assign(inlineContactForm, {
    birthDate: '',
    fullName: '',
    gender: '',
    identifier: '',
    iin: '',
    phone: '',
  });
};

const loadPage = async () => {
  await Promise.all([
    calendarStore.fetchCalendar(),
    referencesStore.loadServices({ include_inactive: true }),
  ]);
};

const openNewAppointment = () => {
  const resourceId =
    calendarStore.visibleResources[0]?.id || calendarStore.resources[0]?.id;
  const startsAt = new Date();
  startsAt.setMinutes(Math.ceil(startsAt.getMinutes() / 30) * 30, 0, 0);
  const endsAt = new Date(startsAt);
  endsAt.setMinutes(endsAt.getMinutes() + 30);

  formStore.openCreate({
    endsAt: endsAt.toISOString(),
    resourceId,
    startsAt: startsAt.toISOString(),
  });
};

const handleDrawerClose = () => {
  formStore.close();
  formStore.reset();
  resetInlineContactForm();
};

const handleInlineContactCreate = async () => {
  try {
    await formStore.createInlineContact(inlineContactForm);
    resetInlineContactForm();
    useAlert(t('SCHEDULING.CONTACT.SUCCESS_CREATE'));
  } catch (error) {
    const payload = extractSchedulingError(error);
    useAlert(payload.message);
  }
};

const handleContactSelect = contactId => {
  const selectedContact = formStore.contacts.find(
    contact => Number(contact.id) === Number(contactId)
  );

  if (selectedContact) {
    formStore.applyContact(selectedContact);
  }
};

const handleAppointmentSubmit = async () => {
  try {
    await formStore.submit(calendarStore);
    useAlert(t('SCHEDULING.APPOINTMENT_FORM.SUCCESS_SAVE'));
    handleDrawerClose();
  } catch (error) {
    const payload = extractSchedulingError(error);
    useAlert(payload.message);
  }
};

const handleAppointmentCancel = async () => {
  try {
    await formStore.cancel(calendarStore);
    useAlert(t('SCHEDULING.APPOINTMENT_FORM.SUCCESS_CANCEL'));
    handleDrawerClose();
  } catch (error) {
    const payload = extractSchedulingError(error);
    useAlert(payload.message);
  }
};

const updateAppointmentMutation = async (appointment, patch) => {
  try {
    const { data } = await SchedulingAppointmentsAPI.update(
      appointment.id,
      patch
    );
    const updatedAppointment = normalizePayload(data);
    calendarStore.upsertAppointment(updatedAppointment);
    await calendarStore.refresh();
  } catch (error) {
    const payload = extractSchedulingError(error);
    useAlert(payload.message);
  }
};

const toggleStatusFilter = async status => {
  if (calendarStore.statusFilters.includes(status)) {
    calendarStore.setStatusFilters(
      calendarStore.statusFilters.filter(item => item !== status)
    );
  } else {
    calendarStore.setStatusFilters([...calendarStore.statusFilters, status]);
  }

  await calendarStore.fetchCalendar();
};

const togglePaymentStatusFilter = async status => {
  if (calendarStore.paymentStatusFilters.includes(status)) {
    calendarStore.setPaymentStatusFilters(
      calendarStore.paymentStatusFilters.filter(item => item !== status)
    );
  } else {
    calendarStore.setPaymentStatusFilters([
      ...calendarStore.paymentStatusFilters,
      status,
    ]);
  }

  await calendarStore.fetchCalendar();
};

watch(
  () => [
    formStore.form.serviceId,
    formStore.form.resourceId,
    referencesStore.services,
  ],
  () => {
    if (!formStore.form.serviceId || !formStore.form.resourceId) return;
    formStore.syncServicePricing(referencesStore.services);
  },
  { deep: true }
);

onMounted(async () => {
  await loadPage();
});
</script>

<template>
  <section class="flex flex-col flex-1 min-h-0 overflow-hidden bg-n-surface-1">
    <SchedulingPageHeader
      :title="$t('SCHEDULING.NAV.CALENDAR')"
      :description="$t('SCHEDULING.CALENDAR.DESCRIPTION')"
    >
      <template #actions>
        <Button
          size="sm"
          :label="$t('SCHEDULING.CALENDAR.NEW_APPOINTMENT')"
          icon="i-lucide-plus"
          @click="openNewAppointment"
        />
      </template>
    </SchedulingPageHeader>

    <SchedulingToolbar
      v-model="currentView"
      :current-label="pageTitle"
      :views="translatedViews"
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
    >
      <template #filters>
        <SchedulingResourceFilter
          :resources="calendarStore.resources"
          :model-value="calendarStore.selectedResourceIds"
          @update:model-value="
            calendarStore.setSelectedResources($event);
            calendarStore.fetchCalendar();
          "
        />
      </template>
    </SchedulingToolbar>

    <div class="px-6 py-4 border-b bg-n-surface-1 border-n-weak">
      <div
        class="flex flex-col gap-4 xl:flex-row xl:items-center xl:justify-between"
      >
        <div class="flex flex-wrap items-center gap-2">
          <span class="text-xs font-semibold uppercase text-n-slate-10">
            {{ $t('SCHEDULING.TOOLBAR.STATUS') }}
          </span>
          <Button
            size="sm"
            variant="faded"
            color="slate"
            :label="$t('SCHEDULING.GENERAL.CLEAR')"
            :disabled="!selectedStatusFilters.length"
            @click="
              calendarStore.setStatusFilters([]);
              calendarStore.fetchCalendar();
            "
          />
          <Button
            v-for="option in appointmentStatusOptions"
            :key="option.value"
            size="sm"
            :variant="
              selectedStatusFilters.includes(option.value) ? 'solid' : 'faded'
            "
            :label="option.label"
            :color="
              selectedStatusFilters.includes(option.value) ? 'blue' : 'slate'
            "
            @click="toggleStatusFilter(option.value)"
          />
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <span class="text-xs font-semibold uppercase text-n-slate-10">
            {{ $t('SCHEDULING.TOOLBAR.PAYMENT_STATUS') }}
          </span>
          <Button
            size="sm"
            variant="faded"
            color="slate"
            :label="$t('SCHEDULING.GENERAL.CLEAR')"
            :disabled="!selectedPaymentStatusFilters.length"
            @click="
              calendarStore.setPaymentStatusFilters([]);
              calendarStore.fetchCalendar();
            "
          />
          <Button
            v-for="option in paymentStatusOptions"
            :key="option.value"
            size="sm"
            :variant="
              selectedPaymentStatusFilters.includes(option.value)
                ? 'solid'
                : 'faded'
            "
            :label="option.label"
            :color="
              selectedPaymentStatusFilters.includes(option.value)
                ? 'blue'
                : 'slate'
            "
            @click="togglePaymentStatusFilter(option.value)"
          />
        </div>
      </div>
    </div>

    <div class="flex-1 overflow-y-auto">
      <div class="flex flex-col gap-6 p-6">
        <div
          v-if="calendarStore.ui.isLoading"
          class="flex items-center justify-center py-16"
        >
          <Spinner class="!w-8 !h-8" />
        </div>

        <SchedulingErrorState
          v-else-if="calendarStore.ui.error"
          :title="$t('SCHEDULING.GENERAL.ERROR_TITLE')"
          :description="calendarStore.ui.error.message"
          @retry="loadPage"
        />

        <SchedulingCalendarGrid
          v-else
          :anchor-date="calendarStore.anchorDate"
          :appointments="calendarStore.appointments"
          :break-rules="calendarStore.breakRules"
          :holidays="calendarStore.holidays"
          :resources="calendarStore.visibleResources"
          :time-offs="calendarStore.timeOffs"
          :view="calendarStore.currentView"
          :work-rules="calendarStore.workRules"
          :workday-overrides="calendarStore.workdayOverrides"
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
          {{ formStore.ui.error.message }}
        </div>

        <SchedulingFormFieldGroup
          :title="$t('SCHEDULING.APPOINTMENT_FORM.CONTACT_TITLE')"
          :description="$t('SCHEDULING.APPOINTMENT_FORM.CONTACT_DESCRIPTION')"
        >
          <ComboBox
            :model-value="formStore.form.contactId"
            :options="contactOptions"
            use-api-results
            :placeholder="$t('SCHEDULING.APPOINTMENT_FORM.CONTACT')"
            :search-placeholder="
              $t('SCHEDULING.APPOINTMENT_FORM.CONTACT_SEARCH')
            "
            :empty-state="$t('SCHEDULING.APPOINTMENT_FORM.CONTACT_EMPTY')"
            @search="formStore.searchContacts($event)"
            @update:model-value="
              formStore.updateField('contactId', $event);
              handleContactSelect($event);
            "
          />

          <div class="grid gap-4 md:grid-cols-2">
            <Input
              v-model="formStore.form.clientName"
              :label="$t('SCHEDULING.APPOINTMENT_FORM.CLIENT_NAME')"
            />
            <Input
              v-model="formStore.form.clientPhone"
              :label="$t('SCHEDULING.APPOINTMENT_FORM.CLIENT_PHONE')"
            />
            <Input
              v-model="formStore.form.clientIdentifier"
              :label="$t('SCHEDULING.APPOINTMENT_FORM.CLIENT_IDENTIFIER')"
            />
            <SchedulingDateTimeField
              v-model="formStore.form.clientBirthDate"
              type="date"
              :label="$t('SCHEDULING.APPOINTMENT_FORM.CLIENT_BIRTH_DATE')"
            />
          </div>

          <ComboBox
            :model-value="formStore.form.clientGender"
            :options="genderOptions"
            :placeholder="$t('SCHEDULING.APPOINTMENT_FORM.CLIENT_GENDER')"
            @update:model-value="formStore.updateField('clientGender', $event)"
          />

          <div class="grid gap-4 p-4 rounded-2xl bg-n-alpha-black2">
            <h4 class="mb-0 text-sm font-semibold text-n-slate-12">
              {{ $t('SCHEDULING.CONTACT.QUICK_CREATE_TITLE') }}
            </h4>
            <div class="grid gap-4 md:grid-cols-2">
              <Input
                v-model="inlineContactForm.fullName"
                :label="$t('SCHEDULING.CONTACT.FULL_NAME')"
              />
              <Input
                v-model="inlineContactForm.phone"
                :label="$t('SCHEDULING.CONTACT.PHONE')"
              />
              <Input
                v-model="inlineContactForm.identifier"
                :label="$t('SCHEDULING.CONTACT.IDENTIFIER')"
              />
              <Input
                v-model="inlineContactForm.iin"
                :label="$t('SCHEDULING.CONTACT.IIN')"
              />
              <SchedulingDateTimeField
                v-model="inlineContactForm.birthDate"
                type="date"
                :label="$t('SCHEDULING.CONTACT.BIRTH_DATE')"
              />
              <ComboBox
                :model-value="inlineContactForm.gender"
                :options="genderOptions"
                :placeholder="$t('SCHEDULING.CONTACT.GENDER_LABEL')"
                @update:model-value="inlineContactForm.gender = $event"
              />
            </div>
            <div class="flex justify-end">
              <Button
                size="sm"
                variant="faded"
                color="slate"
                :is-loading="formStore.ui.isCreatingContact"
                :label="$t('SCHEDULING.CONTACT.CREATE_ACTION')"
                @click="handleInlineContactCreate"
              />
            </div>
          </div>
        </SchedulingFormFieldGroup>

        <SchedulingFormFieldGroup
          :title="$t('SCHEDULING.APPOINTMENT_FORM.APPOINTMENT_TITLE')"
          :description="
            $t('SCHEDULING.APPOINTMENT_FORM.APPOINTMENT_DESCRIPTION')
          "
        >
          <div class="grid gap-4 md:grid-cols-2">
            <ComboBox
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
            <ComboBox
              :model-value="formStore.form.serviceId"
              :options="serviceOptions"
              :placeholder="$t('SCHEDULING.APPOINTMENT_FORM.SERVICE')"
              @update:model-value="formStore.updateField('serviceId', $event)"
            />
            <Input
              v-model="formStore.form.companyId"
              type="number"
              :label="$t('SCHEDULING.APPOINTMENT_FORM.COMPANY_ID')"
            />
            <Input
              v-model="formStore.form.serviceAmount"
              type="number"
              min="0"
              :label="$t('SCHEDULING.APPOINTMENT_FORM.SERVICE_AMOUNT')"
            />
            <SchedulingDateTimeField
              v-model="formStore.form.startsAt"
              type="datetime"
              :label="$t('SCHEDULING.APPOINTMENT_FORM.STARTS_AT')"
              :message="
                formStore.validationErrors.startsAt
                  ? validationErrorMessage(formStore.validationErrors.startsAt)
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
            <ComboBox
              :model-value="formStore.form.status"
              :options="appointmentStatusOptions"
              :placeholder="$t('SCHEDULING.APPOINTMENT_FORM.STATUS')"
              @update:model-value="formStore.updateField('status', $event)"
            />
            <ComboBox
              :model-value="formStore.form.appointmentType"
              :options="appointmentTypeOptions"
              :placeholder="$t('SCHEDULING.APPOINTMENT_FORM.APPOINTMENT_TYPE')"
              @update:model-value="
                formStore.updateField('appointmentType', $event)
              "
            />
          </div>
        </SchedulingFormFieldGroup>

        <SchedulingFormFieldGroup
          :title="$t('SCHEDULING.APPOINTMENT_FORM.NOTES_TITLE')"
          :description="$t('SCHEDULING.APPOINTMENT_FORM.NOTES_DESCRIPTION')"
        >
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
