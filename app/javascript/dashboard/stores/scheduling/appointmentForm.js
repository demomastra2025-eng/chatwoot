import { defineStore } from 'pinia';
import SchedulingAppointmentsAPI from 'dashboard/api/scheduling/appointments';
import SchedulingContactsAPI from 'dashboard/api/scheduling/contacts';
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
          resourceId: appointment.resourceId || '',
          serviceAmount: appointment.serviceAmount || '',
          serviceId: appointment.serviceId || '',
          source: appointment.source || 'manual',
          startsAt: toDateTimeInputValue(appointment.startsAt),
          status: appointment.status || 'scheduled',
        };
      },

      close() {
        this.isOpen = false;
        this.ui.error = null;
      },

      updateField(field, value) {
        this.form = {
          ...this.form,
          [field]: value,
        };
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
        return compactPayload({
          appointment_type: this.form.appointmentType,
          client_birth_date: this.form.clientBirthDate || undefined,
          client_comment: this.form.clientComment,
          client_gender: this.form.clientGender,
          client_identifier: this.form.clientIdentifier,
          client_name: this.form.clientName || this.selectedContact?.fullName,
          client_phone: this.form.clientPhone,
          company_id: toNumeric(this.form.companyId),
          contact_id: toNumeric(this.form.contactId),
          conversation_id: toNumeric(this.form.conversationId),
          custom_attributes: this.form.customAttributes || {},
          ends_at: fromDateTimeInputValue(this.form.endsAt),
          resource_id: toNumeric(this.form.resourceId),
          service_amount: toNumeric(this.form.serviceAmount) || 0,
          service_id: toNumeric(this.form.serviceId),
          source: this.form.source || 'manual',
          starts_at: fromDateTimeInputValue(this.form.startsAt),
          status: this.form.status,
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
