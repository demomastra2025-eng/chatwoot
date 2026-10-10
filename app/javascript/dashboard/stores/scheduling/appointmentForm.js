import { defineStore } from 'pinia';
import SchedulingAppointmentsAPI from 'dashboard/api/scheduling/appointments';
import SchedulingContactsAPI from 'dashboard/api/scheduling/contacts';
import { DEFAULT_WORKSPACE_TIMEZONE } from 'dashboard/routes/dashboard/scheduling/constants';
import { schedulingContactNameParts } from './contactName';
import {
  hasProviderPatientIdentity,
  patientBookingContact,
} from './patientContext';
import {
  compactPayload,
  extractSchedulingError,
  normalizePayload,
  normalizeMeta,
  toIntegerNumeric,
  toNumeric,
} from './shared';
import {
  addMinutesToDateTimeInputValue,
  dateTimeInputDurationMinutes,
  fromDateTimeInputValue,
  getServicePriceForResource,
  isAppointmentProviderOwned,
  toDateTimeInputValue,
} from 'dashboard/routes/dashboard/scheduling/helpers';

// The drawer shows and reads start/end on the clinic clock, the same zone as
// the calendar grid, whatever the browser timezone is.
const SCHEDULING_TIMEZONE = DEFAULT_WORKSPACE_TIMEZONE;
const toFormDateTime = value =>
  toDateTimeInputValue(value, SCHEDULING_TIMEZONE);
const fromFormDateTime = value =>
  fromDateTimeInputValue(value, SCHEDULING_TIMEZONE);

export const refreshCurrentCalendarProviderAction = async ({
  refresh,
  isCurrent,
  onCurrent,
}) => {
  if (!isCurrent()) return false;
  try {
    await refresh();
  } catch {
    // The provider result remains authoritative if the calendar read fails.
  }
  if (!isCurrent()) return false;
  onCurrent();
  return true;
};

export const runCurrentCalendarProviderAction = async ({
  run,
  isCurrent,
  onSuccess,
  onError,
  onFinally = () => {},
}) => {
  if (!isCurrent()) return null;
  try {
    const result = await run();
    if (!isCurrent()) return null;
    onSuccess(result);
    return result;
  } catch (error) {
    if (isCurrent()) onError(error);
    return null;
  } finally {
    if (isCurrent()) onFinally();
  }
};

export const appointmentFormMutationContext = store =>
  JSON.stringify([
    store.formVersion,
    store.inlineContactEditVersion,
    store.isOpen,
    store.mode,
    store.recordId,
    store.form,
  ]);

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

const inlineContactPayload = (contact, omitPhone = false) =>
  compactPayload({
    birth_date: contact.birthDate,
    company_id: toNumeric(contact.companyId),
    first_name: contact.firstName,
    full_name: contact.fullName,
    gender: contact.gender,
    iin: contact.iin || undefined,
    last_name: contact.lastName,
    middle_name: contact.middleName,
    ...(omitPhone ? {} : { phone: contact.phone }),
    resource_id: toNumeric(contact.resourceId),
  });

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
  patientContactId: '',
  conversationDisplayId: '',
  conversationId: '',
  crmDealSelection: {},
  durationMin: '',
  customAttributes: {},
  endsAt: '',
  medelementCabinetCode: '',
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
      formVersion: 0,
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
      inlineContactSnapshot: null,
      inlineContactEditVersion: 0,
      ui: {
        error: null,
        isCreatingContact: false,
        isLoadingContacts: false,
        isSaving: false,
        mutationOperationId: 0,
      },
    }),

    getters: {
      isProviderPatientIdentity: state =>
        hasProviderPatientIdentity(state.selectedContact) ||
        isAppointmentProviderOwned(state.selectedAppointment) ||
        Boolean(
          state.selectedAppointment?.externalRef?.startsWith(
            'medelement:reception:'
          )
        ) ||
        Boolean(
          state.selectedAppointment?.customAttributes
            ?.medelement_reception_code ||
            state.selectedAppointment?.customAttributes?.medelementReceptionCode
        ) ||
        hasProviderPatientIdentity({
          custom_attributes:
            state.selectedAppointment?.customAttributes ||
            state.selectedAppointment?.custom_attributes,
        }),
      validationErrors: state => ({
        durationMin:
          state.form.durationMin !== '' &&
          (!Number.isInteger(Number(state.form.durationMin)) ||
            Number(state.form.durationMin) < 5 ||
            Number(state.form.durationMin) > 1440)
            ? 'SCHEDULING.APPOINTMENT_FORM.ERRORS.INVALID_DURATION'
            : '',
        endsAt:
          state.form.endsAt &&
          state.form.startsAt &&
          new Date(state.form.endsAt) <= new Date(state.form.startsAt)
            ? 'SCHEDULING.APPOINTMENT_FORM.ERRORS.END_BEFORE_START'
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
        this.formVersion += 1;
        this.ui.mutationOperationId += 1;
        this.ui.isSaving = false;
        this.form = createDefaultForm();
        this.mode = 'create';
        this.recordId = null;
        this.selectedContact = null;
        this.selectedAppointment = null;
        this.inlineContactSnapshot = null;
        this.inlineContactEditVersion += 1;
        this.ui.isCreatingContact = false;
        this.ui.error = null;
      },

      openCreate(slot = {}, defaults = {}) {
        this.reset();
        this.isOpen = true;
        this.form = {
          ...this.form,
          ...defaults,
          endsAt: toFormDateTime(slot.endsAt),
          resourceId: slot.resourceId || defaults.resourceId || '',
          startsAt: toFormDateTime(slot.startsAt),
        };
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
          patientContactId: appointment.patientContactId || '',
          conversationDisplayId: appointment.conversationDisplayId || '',
          conversationId: appointment.conversationId || '',
          crmDealSelection: {},
          durationMin: appointment.durationMin || '',
          customAttributes: appointment.customAttributes || {},
          endsAt: toFormDateTime(appointment.endsAt),
          medelementCabinetCode:
            appointment.customAttributes?.medelement_cabinet_code ||
            appointment.customAttributes?.medelementCabinetCode ||
            '',
          resourceId: appointment.resourceId || '',
          serviceAmount: appointment.serviceAmount ?? '',
          serviceId: appointment.serviceId || '',
          serviceIds:
            normalizeIdArray(appointment.serviceIds).length > 0
              ? normalizeIdArray(appointment.serviceIds)
              : normalizeIdArray([appointment.serviceId]),
          serviceNameSnapshot: appointment.serviceNameSnapshot || '',
          source: appointment.source || 'manual',
          startsAt: toFormDateTime(appointment.startsAt),
          status: appointment.status || 'scheduled',
        };
        if (this.form.patientContactId) {
          this.selectedContact = {
            id: this.form.patientContactId,
            birthDate: this.form.clientBirthDate,
            firstName: this.form.clientFirstName,
            fullName: appointment.patientContactName || this.form.clientName,
            gender: this.form.clientGender,
            identifier: this.form.clientIdentifier,
            lastName: this.form.clientLastName,
            middleName: this.form.clientMiddleName,
            phone: this.form.clientPhone,
            customAttributes:
              appointment.customAttributes ||
              appointment.custom_attributes ||
              {},
          };
        }
      },

      close() {
        this.formVersion += 1;
        this.ui.mutationOperationId += 1;
        this.ui.isSaving = false;
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
        if (this.ui.isSaving) return;
        const durationMinutes = dateTimeInputDurationMinutes(
          this.form.startsAt,
          this.form.endsAt,
          SCHEDULING_TIMEZONE
        );
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
          ...(field === 'startsAt' && durationMinutes > 0 && value
            ? {
                endsAt: addMinutesToDateTimeInputValue(
                  value,
                  durationMinutes,
                  SCHEDULING_TIMEZONE
                ),
              }
            : {}),
        };
        if (CLIENT_NAME_PART_FIELDS.has(field)) {
          updatedForm.clientName = fullPatientName(updatedForm);
          updatedForm.clientNameStructured = true;
        }
        this.form = updatedForm;
      },

      applyContact(contact) {
        if (this.ui.isSaving) return;
        const existingPhone = this.form.clientPhone || '';
        const previousContactPhone = this.selectedContact?.phone || '';
        const phoneCameFromPreviousContact =
          previousContactPhone && existingPhone === previousContactPhone;
        const patient = patientBookingContact(contact);
        const contactName = schedulingContactNameParts(patient);

        this.selectedContact = contact;
        this.form = {
          ...this.form,
          clientBirthDate: patient.birthDate || '',
          clientFirstName: contactName.firstName,
          clientGender: patient.gender || '',
          clientIdentifier: patient.identifier || '',
          clientLastName: contactName.lastName,
          clientMiddleName: contactName.middleName,
          clientName: patient.fullName || '',
          clientNameStructured: true,
          clientPhone:
            contact.phone ||
            (phoneCameFromPreviousContact ? '' : existingPhone),
          companyId: contact.companyId || this.form.companyId || '',
          contactId: contact.id,
          crmDealSelection: {},
          patientContactId: '',
        };
      },

      applyPatientContact(contact) {
        if (this.ui.isSaving) return;
        const ownerId = this.form.contactId;
        const dealSelection = this.form.crmDealSelection;
        this.applyContact({
          ...contact,
          phone: contact.phone || this.form.clientPhone,
        });
        this.form.contactId = ownerId;
        this.form.patientContactId = contact.id;
        this.form.crmDealSelection = dealSelection;
      },

      beginInlineContactEdit(contact) {
        if (this.ui.isSaving) return;
        this.inlineContactEditVersion += 1;
        this.inlineContactSnapshot = this.isProviderPatientIdentity
          ? null
          : inlineContactPayload(contact, Boolean(this.form.patientContactId));
      },

      syncServicePricing(services) {
        if (this.ui.isSaving) return;
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

      async updateInlineContact(
        contactId,
        contact,
        isCurrentContext = () => true
      ) {
        if (
          this.ui.isSaving ||
          this.isProviderPatientIdentity ||
          !isCurrentContext()
        )
          return null;
        const recordId = this.recordId;
        const patientId = this.form.patientContactId;
        const ownerId = this.form.contactId;
        const version = this.inlineContactEditVersion;
        const accountId =
          this.selectedContact?.accountId ||
          this.selectedAppointment?.accountId;
        if (ownerId && Number(contactId) !== Number(patientId || ownerId))
          return null;
        const isPatientCard =
          this.mode === 'edit' && Number(patientId) === Number(contactId);
        const isCurrent = () =>
          isCurrentContext() &&
          this.recordId === recordId &&
          this.form.patientContactId === patientId &&
          this.form.contactId === ownerId &&
          this.inlineContactEditVersion === version;
        const values = inlineContactPayload(contact, isPatientCard);
        const dirtyValues = this.inlineContactSnapshot
          ? Object.fromEntries(
              Object.entries(values).filter(
                ([field, value]) =>
                  field !== 'resource_id' &&
                  value !== this.inlineContactSnapshot[field]
              )
            )
          : values;
        if (!Object.keys(dirtyValues).length) return this.selectedContact;
        const payload = {
          ...dirtyValues,
          ...(values.resource_id ? { resource_id: values.resource_id } : {}),
        };
        this.ui.isCreatingContact = true;

        try {
          const { data } = await SchedulingContactsAPI.update(
            contactId,
            payload
          );
          let updatedContact = normalizePayload(data);
          if (!isCurrent()) return null;
          if (Number(updatedContact?.id) !== Number(contactId))
            throw new Error('patient_context_mismatch');
          if (
            accountId &&
            Number(updatedContact.accountId) !== Number(accountId)
          )
            throw new Error('patient_context_mismatch');
          if (isPatientCard) {
            const response = await SchedulingContactsAPI.patients(ownerId);
            if (!isCurrent()) return null;
            const projection = normalizePayload(response.data);
            if (Number(projection?.contactId) !== Number(ownerId))
              throw new Error('patient_context_mismatch');
            updatedContact = projection.patients?.find(
              patient =>
                Number(patient.id) === Number(patientId) &&
                Number(patient.communicationContactId) === Number(ownerId) &&
                (!accountId || Number(patient.accountId) === Number(accountId))
            );
            if (!updatedContact) throw new Error('patient_context_mismatch');
          }
          this.contacts = [
            updatedContact,
            ...this.contacts.filter(item => item.id !== updatedContact.id),
          ];
          if (isPatientCard) this.applyPatientContact(updatedContact);
          else this.applyContact(updatedContact);
          return updatedContact;
        } catch (error) {
          if (isCurrent()) this.ui.error = extractSchedulingError(error);
          throw error;
        } finally {
          if (isCurrent()) this.ui.isCreatingContact = false;
        }
      },

      buildPayload() {
        const normalizedForm = this.form;
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
          ...(toNumeric(normalizedForm.patientContactId)
            ? { patient_contact_id: toNumeric(normalizedForm.patientContactId) }
            : {}),
          conversation_display_id: toNumeric(
            normalizedForm.conversationId
              ? undefined
              : normalizedForm.conversationDisplayId
          ),
          conversation_id: toNumeric(normalizedForm.conversationId),
          ...(this.mode === 'create'
            ? {
                crm_deal_id: toNumeric(normalizedForm.crmDealSelection?.crm_deal_id),
                crm_pipeline_id: toNumeric(normalizedForm.crmDealSelection?.crm_pipeline_id),
                crm_deal_selection: normalizedForm.crmDealSelection?.crm_deal_selection || undefined,
              }
            : {}),
          custom_attributes: {
            ...editableCustomAttributes(normalizedForm.customAttributes),
            ...(normalizedForm.medelementCabinetCode
              ? {
                  medelement_cabinet_code: normalizedForm.medelementCabinetCode,
                }
              : {}),
          },
          ends_at: fromFormDateTime(normalizedForm.endsAt),
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
          starts_at: fromFormDateTime(normalizedForm.startsAt),
          status: normalizedForm.status,
          ...(this.requirements.companyEnabled
            ? {
                company_id: toNumeric(normalizedForm.companyId),
              }
            : {}),
        });

        if (
          normalizedForm.status === 'cancelled' &&
          this.selectedAppointment?.medelementCancellationMode
        ) {
          payload.medelement_cancellation_mode =
            this.selectedAppointment.medelementCancellationMode;
        }

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

      async submit(
        calendarStore,
        { isCurrent: isCurrentContext = () => true, closeOnSuccess = true } = {}
      ) {
        if (
          this.ui.isSaving ||
          this.ui.isCreatingContact ||
          !isCurrentContext()
        )
          return null;
        const context = appointmentFormMutationContext(this);
        this.ui.mutationOperationId += 1;
        const operationId = this.ui.mutationOperationId;
        const isCurrent = () =>
          isCurrentContext() &&
          this.ui.mutationOperationId === operationId &&
          appointmentFormMutationContext(this) === context;
        this.ui.isSaving = true;
        this.ui.error = null;

        try {
          const payload = this.buildPayload();
          const response =
            this.mode === 'edit' && this.recordId
              ? await SchedulingAppointmentsAPI.update(this.recordId, payload)
              : await SchedulingAppointmentsAPI.create(payload);
          const appointment = normalizePayload(response.data);
          if (!isCurrent()) return null;
          calendarStore.syncAppointment(appointment);
          if (calendarStore.currentView === 'month') {
            await calendarStore.refresh();
          }
          if (!isCurrent()) return null;
          if (closeOnSuccess) this.close();
          return appointment;
        } catch (error) {
          if (isCurrent()) this.ui.error = extractSchedulingError(error);
          throw error;
        } finally {
          if (this.ui.mutationOperationId === operationId)
            this.ui.isSaving = false;
        }
      },

      async cancel(
        calendarStore,
        { isCurrent: isCurrentContext = () => true, closeOnSuccess = true } = {}
      ) {
        if (this.ui.isSaving || !this.recordId || !isCurrentContext())
          return null;
        const context = appointmentFormMutationContext(this);
        this.ui.mutationOperationId += 1;
        const operationId = this.ui.mutationOperationId;
        const isCurrent = () =>
          isCurrentContext() &&
          this.ui.mutationOperationId === operationId &&
          appointmentFormMutationContext(this) === context;

        this.ui.isSaving = true;
        this.ui.error = null;

        try {
          const cancellationMode =
            this.selectedAppointment?.medelementCancellationMode;
          const { data } = cancellationMode
            ? await SchedulingAppointmentsAPI.cancel(this.recordId, {
                medelement_cancellation_mode: cancellationMode,
              })
            : await SchedulingAppointmentsAPI.cancel(this.recordId);
          const appointment = normalizePayload(data);
          if (!isCurrent()) return null;
          calendarStore.syncAppointment(appointment);
          if (calendarStore.currentView === 'month') {
            await calendarStore.refresh();
          }
          if (!isCurrent()) return null;
          if (closeOnSuccess) this.close();
          return appointment;
        } catch (error) {
          if (isCurrent()) this.ui.error = extractSchedulingError(error);
          throw error;
        } finally {
          if (this.ui.mutationOperationId === operationId)
            this.ui.isSaving = false;
        }
      },

      async destroy(
        calendarStore,
        { isCurrent: isCurrentContext = () => true, closeOnSuccess = true } = {}
      ) {
        if (this.ui.isSaving || !this.recordId || !isCurrentContext())
          return null;
        const deletedAppointmentId = this.recordId;
        const context = appointmentFormMutationContext(this);
        this.ui.mutationOperationId += 1;
        const operationId = this.ui.mutationOperationId;
        const isCurrent = () =>
          isCurrentContext() &&
          this.ui.mutationOperationId === operationId &&
          appointmentFormMutationContext(this) === context;

        this.ui.isSaving = true;
        this.ui.error = null;

        try {
          await SchedulingAppointmentsAPI.delete(deletedAppointmentId);
          if (!isCurrent()) return null;
          calendarStore.removeAppointment(deletedAppointmentId);
          if (calendarStore.currentView === 'month') {
            await calendarStore.refresh();
          }
          if (!isCurrent()) return null;
          if (closeOnSuccess) {
            this.close();
            this.reset();
          }
          return deletedAppointmentId;
        } catch (error) {
          if (isCurrent()) this.ui.error = extractSchedulingError(error);
          throw error;
        } finally {
          if (this.ui.mutationOperationId === operationId)
            this.ui.isSaving = false;
        }
      },
    },
  }
);
