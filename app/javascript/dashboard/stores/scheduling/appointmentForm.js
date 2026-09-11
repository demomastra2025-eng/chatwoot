import { defineStore } from 'pinia';
import SchedulingAppointmentsAPI from 'dashboard/api/scheduling/appointments';
import SchedulingContactsAPI from 'dashboard/api/scheduling/contacts';
import { PAYMENT_METHOD_VALUES } from 'dashboard/routes/dashboard/scheduling/constants';
import {
  compactPayload,
  extractSchedulingError,
  normalizePayload,
  normalizeMeta,
  toIntegerNumeric,
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
const BACKEND_MANAGED_CUSTOM_ATTRIBUTE_KEYS = new Set([
  'service_ids',
  'services',
  'source_mode',
]);
const MEDELEMENT_CABINET_CODE_KEY = 'medelement_cabinet_code';
const CLIENT_NAME_PART_FIELDS = new Set([
  'clientFirstName',
  'clientLastName',
  'clientMiddleName',
]);

const fullPatientName = form =>
  [form?.clientFirstName, form?.clientLastName, form?.clientMiddleName]
    .map(value => String(value || '').trim())
    .filter(Boolean)
    .join(' ');

const patientNameParts = appointment => {
  if (
    appointment?.clientFirstName ||
    appointment?.clientLastName ||
    appointment?.clientMiddleName
  ) {
    return {
      clientFirstName: appointment.clientFirstName || '',
      clientLastName: appointment.clientLastName || '',
      clientMiddleName: appointment.clientMiddleName || '',
      clientNameStructured: true,
    };
  }

  return {
    clientFirstName: String(appointment?.clientName || '').trim(),
    clientLastName: '',
    clientMiddleName: '',
    clientNameStructured: false,
  };
};

const editableCustomAttributes = attributes =>
  Object.fromEntries(
    Object.entries(attributes || {}).filter(([key]) => {
      if (BACKEND_MANAGED_CUSTOM_ATTRIBUTE_KEYS.has(key)) return false;

      return (
        !key.startsWith('medelement_') || key === MEDELEMENT_CABINET_CODE_KEY
      );
    })
  );

const resolveAmount = value => {
  if (value === '' || value === null || value === undefined) {
    return 0;
  }

  const numericValue = Number(value);
  return Number.isFinite(numericValue) ? numericValue : 0;
};

const normalizeIdArray = values => {
  const normalizedValues = Array.isArray(values) ? values : [values];

  return normalizedValues
    .map(value => Number(value))
    .filter(value => Number.isFinite(value) && value > 0)
    .filter((value, index, array) => array.indexOf(value) === index);
};

const haveEqualIds = (left = [], right = []) => {
  const normalizedLeft = normalizeIdArray(left);
  const normalizedRight = normalizeIdArray(right);

  if (normalizedLeft.length !== normalizedRight.length) {
    return false;
  }

  return normalizedLeft.every(
    (value, index) => value === normalizedRight[index]
  );
};

const normalizePrepaymentForm = form => ({
  ...form,
  prepaidPaymentMethod:
    resolveAmount(form.prepaidAmount) > 0
      ? form.prepaidPaymentMethod || DEFAULT_PREPAID_PAYMENT_METHOD
      : '',
});

export const isKazakhstanE164Phone = value => {
  let digits = String(value || '').replace(/\D/g, '');
  digits = digits.length === 10 ? `7${digits}` : digits;
  digits =
    digits.length === 11 && digits.startsWith('8')
      ? `7${digits.slice(1)}`
      : digits;

  return /^7\d{10}$/.test(digits);
};

const createDefaultForm = () => ({
  appointmentType: 'primary',
  clientBirthDate: '',
  clientComment: '',
  clientFirstName: '',
  clientGender: '',
  clientIdentifier: '',
  clientLastName: '',
  clientMiddleName: '',
  clientName: '',
  clientNameStructured: true,
  clientPhone: '',
  companyId: '',
  contactId: '',
  conversationDisplayId: '',
  conversationId: '',
  customAttributes: {},
  endsAt: '',
  medelementCabinetCode: '',
  prepaidAmount: '',
  prepaidPaymentMethod: '',
  resourceId: '',
  serviceAmount: '',
  serviceId: '',
  serviceIds: [],
  serviceNameSnapshot: '',
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
      requirements: {
        companyEnabled: true,
        contactRequired: true,
        medelementIdentityRequired: false,
        medelementPhoneRequired: false,
        medelementServiceRequired: false,
      },
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
        clientName: !state.form.clientFirstName?.trim()
          ? 'SCHEDULING.APPOINTMENT_FORM.ERRORS.CLIENT_NAME_REQUIRED'
          : '',
        clientLastName:
          state.requirements.medelementIdentityRequired &&
          !state.form.clientLastName?.trim()
            ? 'SCHEDULING.APPOINTMENT_FORM.ERRORS.MEDELEMENT_LAST_NAME_REQUIRED'
            : '',
        contactId:
          state.requirements.contactRequired && !state.form.contactId
            ? 'SCHEDULING.APPOINTMENT_FORM.ERRORS.CONTACT_REQUIRED'
            : '',
        clientPhone:
          state.requirements.medelementPhoneRequired &&
          !isKazakhstanE164Phone(state.form.clientPhone)
            ? 'SCHEDULING.APPOINTMENT_FORM.ERRORS.MEDELEMENT_PHONE_REQUIRED'
            : '',
        resourceId: !state.form.resourceId
          ? 'SCHEDULING.APPOINTMENT_FORM.ERRORS.RESOURCE_REQUIRED'
          : '',
        serviceIds:
          state.requirements.medelementServiceRequired &&
          normalizeIdArray(state.form.serviceIds).length === 0 &&
          !toNumeric(state.form.serviceId)
            ? 'SCHEDULING.APPOINTMENT_FORM.ERRORS.MEDELEMENT_SERVICE_REQUIRED'
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
        const nameParts = patientNameParts(appointment);
        this.mode = 'edit';
        this.recordId = appointment.id;
        this.selectedAppointment = {
          ...appointment,
          serviceIds:
            normalizeIdArray(appointment.serviceIds).length > 0
              ? normalizeIdArray(appointment.serviceIds)
              : normalizeIdArray([appointment.serviceId]),
        };
        this.isOpen = true;
        this.form = {
          appointmentType: appointment.appointmentType || 'primary',
          clientBirthDate: appointment.clientBirthDate || '',
          clientComment: appointment.clientComment || '',
          clientFirstName: nameParts.clientFirstName,
          clientGender: appointment.clientGender || '',
          clientIdentifier: appointment.clientIdentifier || '',
          clientLastName: nameParts.clientLastName,
          clientMiddleName: nameParts.clientMiddleName,
          clientName: appointment.clientName || '',
          clientNameStructured: nameParts.clientNameStructured,
          clientPhone: appointment.clientPhone || '',
          companyId: appointment.companyId || '',
          contactId: appointment.contactId || '',
          conversationDisplayId: appointment.conversationDisplayId || '',
          conversationId: appointment.conversationId || '',
          customAttributes: appointment.customAttributes || {},
          endsAt: toDateTimeInputValue(appointment.endsAt),
          medelementCabinetCode:
            appointment.customAttributes?.medelement_cabinet_code ||
            appointment.customAttributes?.medelementCabinetCode ||
            '',
          prepaidAmount: appointment.prepaidAmount ?? '',
          prepaidPaymentMethod: appointment.prepaidPaymentMethod || '',
          resourceId: appointment.resourceId || '',
          serviceAmount: appointment.serviceAmount ?? '',
          serviceId: appointment.serviceId || '',
          serviceIds:
            normalizeIdArray(appointment.serviceIds).length > 0
              ? normalizeIdArray(appointment.serviceIds)
              : normalizeIdArray([appointment.serviceId]),
          serviceNameSnapshot: appointment.serviceNameSnapshot || '',
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

      setRequirements(requirements = {}) {
        this.requirements = {
          ...this.requirements,
          ...requirements,
        };
      },

      updateField(field, value) {
        const currentStart = new Date(this.form.startsAt);
        const currentEnd = new Date(this.form.endsAt);
        const durationMs = currentEnd - currentStart;
        const normalizedValue =
          field === 'serviceIds' ? normalizeIdArray(value) : value;
        const normalizedServiceIds =
          field === 'serviceIds' ? normalizeIdArray(value) : [];

        const updatedForm = {
          ...this.form,
          [field]: normalizedValue,
          ...(field === 'serviceIds'
            ? {
                serviceId: normalizedServiceIds[0] || '',
                ...(normalizedServiceIds.length
                  ? { serviceNameSnapshot: '' }
                  : {}),
              }
            : {}),
          ...(field === 'startsAt' && durationMs > 0 && value
            ? {
                endsAt: toDateTimeInputValue(
                  new Date(new Date(value).getTime() + durationMs)
                ),
              }
            : {}),
        };
        if (CLIENT_NAME_PART_FIELDS.has(field)) {
          updatedForm.clientName = fullPatientName(updatedForm);
          updatedForm.clientNameStructured = true;
        }
        this.form = normalizePrepaymentForm(updatedForm);
      },

      applyContact(contact) {
        const existingPhone = this.form.clientPhone || '';
        const previousContactPhone = this.selectedContact?.phone || '';
        const phoneCameFromPreviousContact =
          previousContactPhone && existingPhone === previousContactPhone;

        this.selectedContact = contact;
        this.form = {
          ...this.form,
          clientBirthDate: contact.birthDate || '',
          clientFirstName: contact.firstName || contact.fullName || '',
          clientGender: contact.gender || '',
          clientIdentifier: contact.identifier || '',
          clientLastName: contact.lastName || '',
          clientMiddleName: contact.middleName || '',
          clientName: contact.fullName || '',
          clientNameStructured: true,
          clientPhone:
            contact.phone ||
            (phoneCameFromPreviousContact ? '' : existingPhone),
          companyId: contact.companyId || this.form.companyId || '',
          contactId: contact.id,
        };
      },

      syncServicePricing(services) {
        const activeServiceIds = normalizeIdArray(this.form.serviceIds);
        const serviceIdsForPricing = activeServiceIds.length
          ? activeServiceIds
          : normalizeIdArray([this.form.serviceId]);
        const selectedServices = serviceIdsForPricing
          .map(serviceId =>
            services.find(service => Number(service.id) === Number(serviceId))
          )
          .filter(Boolean);
        if (!selectedServices.length) return;
        if (
          this.mode === 'edit' &&
          this.selectedAppointment &&
          Number(this.form.resourceId) ===
            Number(this.selectedAppointment.resourceId) &&
          haveEqualIds(
            this.form.serviceIds,
            this.selectedAppointment.serviceIds
          )
        ) {
          return;
        }

        const nextServiceAmount = selectedServices.reduce(
          (sum, service) =>
            sum + getServicePriceForResource(service, this.form.resourceId),
          0
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

      async loadContact(contactId) {
        this.ui.isLoadingContacts = true;

        try {
          const { data } = await SchedulingContactsAPI.get({
            contact_id: contactId,
            limit: 1,
          });
          const contact = normalizePayload(data)[0] || null;
          if (!contact) return null;

          this.contacts = [
            contact,
            ...this.contacts.filter(item => item.id !== contact.id),
          ];
          this.applyContact(contact);
          return contact;
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
            first_name: contact.firstName,
            full_name: contact.fullName,
            gender: contact.gender,
            iin: contact.iin || undefined,
            last_name: contact.lastName,
            middle_name: contact.middleName,
            phone: contact.phone,
            resource_id: toNumeric(contact.resourceId),
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
            first_name: contact.firstName,
            full_name: contact.fullName,
            gender: contact.gender,
            iin: contact.iin || undefined,
            last_name: contact.lastName,
            middle_name: contact.middleName,
            phone: contact.phone,
            resource_id: toNumeric(contact.resourceId),
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
        const serviceIds = normalizeIdArray(normalizedForm.serviceIds);
        const serviceId = toNumeric(normalizedForm.serviceId);
        const hasSelectedService = serviceIds.length || serviceId;
        const payload = compactPayload({
          appointment_type: normalizedForm.appointmentType,
          client_birth_date: normalizedForm.clientBirthDate || undefined,
          client_comment: normalizedForm.clientComment,
          ...(normalizedForm.clientNameStructured
            ? {
                client_first_name: normalizedForm.clientFirstName,
                client_last_name: normalizedForm.clientLastName,
                client_middle_name: normalizedForm.clientMiddleName,
              }
            : {}),
          client_gender: normalizedForm.clientGender,
          client_identifier: normalizedForm.clientIdentifier,
          client_name: fullPatientName(normalizedForm),
          client_phone: normalizedForm.clientPhone,
          contact_id: toNumeric(normalizedForm.contactId),
          conversation_display_id: toNumeric(
            normalizedForm.conversationId
              ? undefined
              : normalizedForm.conversationDisplayId
          ),
          conversation_id: toNumeric(normalizedForm.conversationId),
          custom_attributes: {
            ...editableCustomAttributes(normalizedForm.customAttributes),
            ...(normalizedForm.medelementCabinetCode
              ? {
                  medelement_cabinet_code: normalizedForm.medelementCabinetCode,
                }
              : {}),
          },
          ends_at: fromDateTimeInputValue(normalizedForm.endsAt),
          prepaid_amount:
            toIntegerNumeric(normalizedForm.prepaidAmount, 'prepaid_amount') ||
            0,
          prepaid_payment_method:
            normalizedForm.prepaidPaymentMethod || undefined,
          resource_id: toNumeric(normalizedForm.resourceId),
          service_amount:
            toIntegerNumeric(normalizedForm.serviceAmount, 'service_amount') ||
            0,
          service_id: serviceId,
          service_ids: serviceIds,
          service_name_snapshot: hasSelectedService
            ? undefined
            : normalizedForm.serviceNameSnapshot,
          source: normalizedForm.source || 'manual',
          starts_at: fromDateTimeInputValue(normalizedForm.startsAt),
          status: normalizedForm.status,
          ...(this.requirements.companyEnabled
            ? {
                company_id: toNumeric(normalizedForm.companyId),
              }
            : {}),
        });

        if (!hasSelectedService) {
          payload.service_ids = [];
        }
        if (normalizedForm.clientNameStructured) {
          payload.client_last_name =
            normalizedForm.clientLastName?.trim() || null;
          payload.client_middle_name =
            normalizedForm.clientMiddleName?.trim() || null;
        }

        const selectedAppointmentContactId = Number(
          this.selectedAppointment?.contactId || 0
        );
        const formContactId = Number(normalizedForm.contactId || 0);
        if (
          this.mode === 'edit' &&
          this.selectedAppointment &&
          selectedAppointmentContactId !== formContactId
        ) {
          payload.conversation_id = null;
          delete payload.conversation_display_id;
        }

        return payload;
      },

      async createAndLinkConversation(
        { appointmentId = this.recordId, contactId, inbox },
        calendarStore,
        shouldApplyResponse = () => true
      ) {
        const normalizedAppointmentId = Number(appointmentId);
        const normalizedContactId = Number(contactId);
        const normalizedInboxId = Number(inbox?.value || inbox?.id);

        if (
          !Number.isFinite(normalizedAppointmentId) ||
          normalizedAppointmentId <= 0
        ) {
          throw new Error('An existing appointment is required');
        }
        if (
          !Number.isFinite(normalizedContactId) ||
          normalizedContactId <= 0 ||
          !Number.isFinite(normalizedInboxId) ||
          normalizedInboxId <= 0
        ) {
          throw new Error('A contact and inbox are required');
        }

        const { data } = await SchedulingAppointmentsAPI.createConversation(
          normalizedAppointmentId,
          {
            contact_id: normalizedContactId,
            contact_inbox_id: inbox.contactInboxId || undefined,
            inbox_id: normalizedInboxId,
            source_id: inbox.sourceId || undefined,
          }
        );
        const appointment = normalizePayload(data);

        if (!shouldApplyResponse()) return appointment;

        calendarStore.syncAppointment(appointment);
        if (
          this.mode === 'edit' &&
          Number(this.recordId) === normalizedAppointmentId &&
          Number(this.form.contactId) === normalizedContactId
        ) {
          this.selectedAppointment = appointment;
          this.form = {
            ...this.form,
            contactId: appointment.contactId || normalizedContactId,
            conversationDisplayId: appointment.conversationDisplayId || '',
            conversationId: appointment.conversationId || '',
          };
        }

        return appointment;
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

      async destroy(calendarStore) {
        if (!this.recordId) return null;

        this.ui.isSaving = true;
        this.ui.error = null;

        try {
          await SchedulingAppointmentsAPI.delete(this.recordId);
          calendarStore.removeAppointment(this.recordId);
          if (calendarStore.currentView === 'month') {
            await calendarStore.refresh();
          }
          const deletedAppointmentId = this.recordId;
          this.close();
          this.reset();
          return deletedAppointmentId;
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
