import { defineStore } from 'pinia';
import SchedulingAppointmentsAPI from 'dashboard/api/scheduling/appointments';
import SchedulingContactsAPI from 'dashboard/api/scheduling/contacts';
import { PAYMENT_METHOD_VALUES } from 'dashboard/routes/dashboard/scheduling/constants';
import {
  compactPayload,
  extractSchedulingError,
  normalizePayload,
  normalizeMeta,
  toNumeric,
} from './shared';
import {
  fromDateTimeInputValue,
  getServicePriceForResource,
  toDateTimeInputValue,
} from 'dashboard/routes/dashboard/scheduling/helpers';

const DEFAULT_PREPAID_PAYMENT_METHOD =
  PAYMENT_METHOD_VALUES.find(value => value === 'cash') ||
  PAYMENT_METHOD_VALUES[0] ||
  'cash';

const resolveAmount = value => {
  if (value === '' || value === null || value === undefined) {
    return 0;
  }

  const numericValue = Number(value);
  return Number.isFinite(numericValue) ? numericValue : 0;
};

const normalizePrepaymentForm = form => ({
  ...form,
  prepaidPaymentMethod:
    resolveAmount(form.prepaidAmount) > 0
      ? form.prepaidPaymentMethod || DEFAULT_PREPAID_PAYMENT_METHOD
      : '',
});

const createDefaultForm = () => ({
  appointmentType: 'primary',
  clientBirthDate: '',
  clientComment: '',
  clientGender: '',
  clientIdentifier: '',
  clientName: '',
  clientPhone: '',
  companyId: '',
  contactId: '',
  conversationId: '',
  customAttributes: {},
  endsAt: '',
  prepaidAmount: '',
  prepaidPaymentMethod: '',
  resourceId: '',
  serviceAmount: '',
  serviceId: '',
  source: 'manual',
  startsAt: '',
  status: 'scheduled',
});

export const useSchedulingAppointmentFormStore = defineStore(
  'schedulingAppointmentForm',
  {
    state: () => ({
      contacts: [],
      contactsMeta: {},
      form: createDefaultForm(),
      isOpen: false,
      mode: 'create',
      recordId: null,
      selectedContact: null,
      selectedAppointment: null,
      ui: {
        error: null,
        isCreatingContact: false,
        isLoadingContacts: false,
        isSaving: false,
      },
    }),

    getters: {
      validationErrors: state => ({
        endsAt:
          state.form.endsAt &&
          state.form.startsAt &&
          new Date(state.form.endsAt) <= new Date(state.form.startsAt)
            ? 'SCHEDULING.APPOINTMENT_FORM.ERRORS.END_BEFORE_START'
            : '',
        prepaidAmount:
          resolveAmount(state.form.prepaidAmount) >
          resolveAmount(state.form.serviceAmount)
            ? 'SCHEDULING.APPOINTMENT_FORM.ERRORS.PREPAID_EXCEEDS_SERVICE_AMOUNT'
            : '',
        resourceId: !state.form.resourceId
          ? 'SCHEDULING.APPOINTMENT_FORM.ERRORS.RESOURCE_REQUIRED'
          : '',
        startsAt: !state.form.startsAt
          ? 'SCHEDULING.APPOINTMENT_FORM.ERRORS.START_REQUIRED'
          : '',
      }),
      isFormInvalid() {
        return Object.values(this.validationErrors).some(Boolean);
      },
    },

    actions: {
      reset() {
        this.form = createDefaultForm();
        this.mode = 'create';
        this.recordId = null;
        this.selectedContact = null;
        this.selectedAppointment = null;
        this.ui.error = null;
      },

      openCreate(slot = {}, defaults = {}) {
        this.reset();
        this.isOpen = true;
        this.form = {
          ...this.form,
          ...defaults,
          endsAt: toDateTimeInputValue(slot.endsAt),
          resourceId: slot.resourceId || defaults.resourceId || '',
          startsAt: toDateTimeInputValue(slot.startsAt),
        };
        this.form = normalizePrepaymentForm(this.form);
      },

      openEdit(appointment) {
        this.reset();
        this.mode = 'edit';
        this.recordId = appointment.id;
        this.selectedAppointment = appointment;
        this.isOpen = true;
        this.form = {
          appointmentType: appointment.appointmentType || 'primary',
          clientBirthDate: appointment.clientBirthDate || '',
          clientComment: appointment.clientComment || '',
          clientGender: appointment.clientGender || '',
          clientIdentifier: appointment.clientIdentifier || '',
          clientName: appointment.clientName || '',
          clientPhone: appointment.clientPhone || '',
          companyId: appointment.companyId || '',
          contactId: appointment.contactId || '',
          conversationId: appointment.conversationId || '',
          customAttributes: appointment.customAttributes || {},
          endsAt: toDateTimeInputValue(appointment.endsAt),
          prepaidAmount: appointment.prepaidAmount ?? '',
          prepaidPaymentMethod: appointment.prepaidPaymentMethod || '',
          resourceId: appointment.resourceId || '',
          serviceAmount: appointment.serviceAmount ?? '',
          serviceId: appointment.serviceId || '',
          source: appointment.source || 'manual',
          startsAt: toDateTimeInputValue(appointment.startsAt),
          status: appointment.status || 'scheduled',
        };
        this.form = normalizePrepaymentForm(this.form);
      },

      close() {
        this.isOpen = false;
        this.ui.error = null;
      },

      updateField(field, value) {
        this.form = normalizePrepaymentForm({
          ...this.form,
          [field]: value,
        });
      },

      applyContact(contact) {
        this.selectedContact = contact;
        this.form = {
          ...this.form,
          clientBirthDate: contact.birthDate || '',
          clientGender: contact.gender || '',
          clientIdentifier: contact.identifier || '',
          clientName: contact.fullName || '',
          clientPhone: contact.phone || '',
          companyId: contact.companyId || this.form.companyId || '',
          contactId: contact.id,
        };
      },

      syncServicePricing(services) {
        const selectedService = services.find(
          service => Number(service.id) === Number(this.form.serviceId)
        );
        if (!selectedService) return;
        if (
          this.mode === 'edit' &&
          this.selectedAppointment &&
          Number(this.form.resourceId) ===
            Number(this.selectedAppointment.resourceId) &&
          Number(this.form.serviceId) ===
            Number(this.selectedAppointment.serviceId)
        ) {
          return;
        }

        const nextServiceAmount = getServicePriceForResource(
          selectedService,
          this.form.resourceId
        );
        if (
          `${this.form.serviceAmount ?? ''}` === `${nextServiceAmount ?? ''}`
        ) {
          return;
        }

        this.form = {
          ...this.form,
          serviceAmount: nextServiceAmount,
        };
      },

      async searchContacts(query) {
        this.ui.isLoadingContacts = true;

        try {
          const { data } = await SchedulingContactsAPI.get({
            limit: 20,
            search: query,
          });
          this.contacts = normalizePayload(data);
          this.contactsMeta = normalizeMeta(data);
          return this.contacts;
        } catch (error) {
          this.ui.error = extractSchedulingError(error);
          throw error;
        } finally {
          this.ui.isLoadingContacts = false;
        }
      },

      async createInlineContact(contact) {
        this.ui.isCreatingContact = true;

        try {
          const payload = compactPayload({
            birth_date: contact.birthDate,
            company_id: toNumeric(contact.companyId),
            full_name: contact.fullName,
            gender: contact.gender,
            iin: contact.iin || undefined,
            phone: contact.phone,
          });
          const { data } = await SchedulingContactsAPI.create(payload);
          const createdContact = normalizePayload(data);
          this.contacts = [createdContact, ...this.contacts];
          this.applyContact(createdContact);
          return createdContact;
        } catch (error) {
          this.ui.error = extractSchedulingError(error);
          throw error;
        } finally {
          this.ui.isCreatingContact = false;
        }
      },

      async updateInlineContact(contactId, contact) {
        this.ui.isCreatingContact = true;

        try {
          const payload = compactPayload({
            birth_date: contact.birthDate,
            company_id: toNumeric(contact.companyId),
            full_name: contact.fullName,
            gender: contact.gender,
            iin: contact.iin || undefined,
            phone: contact.phone,
          });
          const { data } = await SchedulingContactsAPI.update(
            contactId,
            payload
          );
          const updatedContact = normalizePayload(data);
          this.contacts = [
            updatedContact,
            ...this.contacts.filter(item => item.id !== updatedContact.id),
          ];
          this.applyContact(updatedContact);
          return updatedContact;
        } catch (error) {
          this.ui.error = extractSchedulingError(error);
          throw error;
        } finally {
          this.ui.isCreatingContact = false;
        }
      },

      buildPayload() {
        const normalizedForm = normalizePrepaymentForm(this.form);

        return compactPayload({
          appointment_type: normalizedForm.appointmentType,
          client_birth_date: normalizedForm.clientBirthDate || undefined,
          client_comment: normalizedForm.clientComment,
          client_gender: normalizedForm.clientGender,
          client_identifier: normalizedForm.clientIdentifier,
          client_name:
            normalizedForm.clientName || this.selectedContact?.fullName,
          client_phone: normalizedForm.clientPhone,
          company_id: toNumeric(normalizedForm.companyId),
          contact_id: toNumeric(normalizedForm.contactId),
          conversation_id: toNumeric(normalizedForm.conversationId),
          custom_attributes: normalizedForm.customAttributes || {},
          ends_at: fromDateTimeInputValue(normalizedForm.endsAt),
          prepaid_amount: toNumeric(normalizedForm.prepaidAmount) || 0,
          prepaid_payment_method:
            normalizedForm.prepaidPaymentMethod || undefined,
          resource_id: toNumeric(normalizedForm.resourceId),
          service_amount: toNumeric(normalizedForm.serviceAmount) || 0,
          service_id: toNumeric(normalizedForm.serviceId),
          source: normalizedForm.source || 'manual',
          starts_at: fromDateTimeInputValue(normalizedForm.startsAt),
          status: normalizedForm.status,
        });
      },

      async submit(calendarStore) {
        this.ui.isSaving = true;
        this.ui.error = null;

        try {
          const payload = this.buildPayload();
          const response =
            this.mode === 'edit' && this.recordId
              ? await SchedulingAppointmentsAPI.update(this.recordId, payload)
              : await SchedulingAppointmentsAPI.create(payload);
          const appointment = normalizePayload(response.data);
          calendarStore.syncAppointment(appointment);
          if (calendarStore.currentView === 'month') {
            await calendarStore.refresh();
          }
          this.close();
          return appointment;
        } catch (error) {
          this.ui.error = extractSchedulingError(error);
          throw error;
        } finally {
          this.ui.isSaving = false;
        }
      },

      async cancel(calendarStore) {
        if (!this.recordId) return null;

        this.ui.isSaving = true;
        this.ui.error = null;

        try {
          const { data } = await SchedulingAppointmentsAPI.cancel(
            this.recordId
          );
          const appointment = normalizePayload(data);
          calendarStore.syncAppointment(appointment);
          if (calendarStore.currentView === 'month') {
            await calendarStore.refresh();
          }
          this.close();
          return appointment;
        } catch (error) {
          this.ui.error = extractSchedulingError(error);
          throw error;
        } finally {
          this.ui.isSaving = false;
        }
      },
    },
  }
);
