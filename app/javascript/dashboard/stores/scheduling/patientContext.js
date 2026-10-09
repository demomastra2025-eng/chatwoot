import { defineStore } from 'pinia';
import SchedulingContactsAPI from 'dashboard/api/scheduling/contacts';

export const PATIENT_SELECTION_STORAGE_KEY =
  'onelink.scheduling.patient-selections.v1';

export const patientContactId = value => {
  if (!['number', 'string'].includes(typeof value)) return null;
  const id = Number(value);
  return Number.isSafeInteger(id) && id > 0 ? id : null;
};

export const conversationPatientContextKey = ({ accountId, userId, chat }) => {
  const account = patientContactId(accountId);
  const user = patientContactId(userId);
  const dialog = patientContactId(
    chat?.display_id || chat?.displayId || chat?.id
  );
  if (!account || !user || !dialog) return '';
  const kind = chat?.is_communication_thread ? 'thread' : 'conversation';
  return `${account}:${user}:${kind}:${dialog}`;
};

export const patientDisplayName = patient =>
  patient?.full_name ||
  patient?.fullName ||
  patient?.name ||
  [patient?.last_name, patient?.first_name, patient?.middle_name]
    .filter(Boolean)
    .join(' ');

export const patientBirthDate = patient =>
  patient?.birth_date ||
  patient?.birthDate ||
  patient?.custom_attributes?.birth_date ||
  patient?.customAttributes?.birth_date ||
  '';

export const formatPatientBirthDate = patient => {
  const value = patientBirthDate(patient);
  const match = String(value).match(/^(\d{4})-(\d{2})-(\d{2})/);
  return match ? `${match[3]}.${match[2]}.${match[1]}` : '';
};

export const hasProviderPatientIdentity = patient => {
  const attributes =
    patient?.custom_attributes || patient?.customAttributes || {};
  return [
    'medelement_patient_code',
    'medelement_iin',
    'medelement_first_name',
    'medelement_last_name',
    'medelement_middle_name',
    'medelement_birth_date',
    'medelement_gender',
  ].some(key => {
    const camelKey = key.replace(/_([a-z])/g, (_, letter) =>
      letter.toUpperCase()
    );
    const value = attributes[key] ?? attributes[camelKey];
    return value != null && Boolean(String(value).trim());
  });
};

export const canEditLocalPatient = patient =>
  Boolean(patient?.patient_contact_id) &&
  Number(patient.id) !== Number(patient.communication_contact_id) &&
  !hasProviderPatientIdentity(patient);

export const normalizePatientGender = value =>
  ({
    1: 'female',
    2: 'male',
    f: 'female',
    m: 'male',
    female: 'female',
    male: 'male',
    other: 'other',
    unknown: 'unknown',
  })[String(value || '').toLowerCase()] || 'unknown';

export const patientBookingContact = contact => {
  if (!hasProviderPatientIdentity(contact)) return contact;
  // The scoped patient DTO is already the server's clinical projection. Generic
  // contacts retain messenger aliases, so only their recorded provider profile
  // supplies booking identity; the original Contact object remains unchanged.
  if (contact.communicationContactId || contact.communication_contact_id) {
    return { ...contact, gender: normalizePatientGender(contact.gender) };
  }
  const attributes =
    contact.customAttributes || contact.custom_attributes || {};
  const recorded = key =>
    attributes[key] ??
    attributes[key.replace(/_([a-z])/g, (_, letter) => letter.toUpperCase())];
  const nameKeys = ['first_name', 'last_name', 'middle_name'];
  const hasRecordedNames = nameKeys.some(key =>
    Boolean(recorded(`medelement_${key}`))
  );
  const names = hasRecordedNames
    ? nameKeys.map(key => recorded(`medelement_${key}`) || '')
    : [
        contact.firstName || contact.first_name || '',
        contact.lastName || contact.last_name || '',
        contact.middleName || contact.middle_name || '',
      ];
  return {
    ...contact,
    firstName: names[0],
    lastName: names[1],
    middleName: names[2],
    fullName: hasRecordedNames
      ? names.filter(Boolean).join(' ')
      : contact.fullName || contact.full_name || '',
    identifier:
      recorded('medelement_iin') || contact.identifier || attributes.iin || '',
    birthDate:
      recorded('medelement_birth_date') ||
      contact.birthDate ||
      contact.birth_date ||
      '',
    gender: normalizePatientGender(
      recorded('medelement_gender') || contact.gender
    ),
  };
};

const readSelections = () => {
  try {
    const values = JSON.parse(
      window.localStorage.getItem(PATIENT_SELECTION_STORAGE_KEY) || '{}'
    );
    return Object.fromEntries(
      Object.entries(values).filter(
        ([key, id]) =>
          /^\d+:\d+:(thread|conversation):\d+$/.test(key) &&
          patientContactId(id)
      )
    );
  } catch {
    return {};
  }
};

const responsePayload = response => response.data?.payload || response.data;

export const useConversationPatientContextStore = defineStore(
  'conversationPatientContext',
  {
    state: () => ({ contexts: {}, selections: readSelections(), drafts: {} }),
    getters: {
      selectedPatient: state => key => {
        const entry = state.contexts[key];
        return (
          entry?.patients.find(
            patient => Number(patient.id) === Number(entry.selectedId)
          ) || null
        );
      },
    },
    actions: {
      saveDraft(key, draft) {
        if (!key) return;
        // Clinical drafts are never written to browser storage.
        this.drafts[key] = JSON.parse(JSON.stringify(draft));
      },
      clearDraft(key) {
        if (key) delete this.drafts[key];
      },
      rememberSelection(key, id) {
        const contactId = patientContactId(id);
        if (!key || !contactId) return;
        // Persist IDs only; patient details and form drafts stay in memory.
        delete this.selections[key];
        this.selections[key] = contactId;
        const entries = Object.entries(this.selections).slice(-500);
        this.selections = Object.fromEntries(entries);
        try {
          window.localStorage.setItem(
            PATIENT_SELECTION_STORAGE_KEY,
            JSON.stringify(this.selections)
          );
        } catch {
          // Selection still works when browser storage is unavailable.
        }
      },
      select(key, id) {
        const entry = this.contexts[key];
        const contactId = patientContactId(id);
        if (
          !entry?.patients.some(patient => Number(patient.id) === contactId)
        ) {
          return false;
        }
        entry.selectedId = contactId;
        this.rememberSelection(key, contactId);
        return true;
      },
      async load(key, contactId, { force = false } = {}) {
        if (!key || !patientContactId(contactId)) return;
        let entry = this.contexts[key];
        if (entry?.contactId === Number(contactId) && !force) {
          if (entry.loading || entry.loaded) return;
        }
        const requestId = (entry?.requestId || 0) + 1;
        const sameContact = entry?.contactId === Number(contactId);
        entry = {
          contactId: Number(contactId),
          patients: sameContact ? entry.patients : [],
          selectedId: sameContact ? entry.selectedId : null,
          requestId,
          loading: true,
          loaded: false,
          saving: false,
          error: null,
        };
        this.contexts[key] = entry;
        const isCurrent = () => this.contexts[key]?.requestId === requestId;
        try {
          const response = await SchedulingContactsAPI.patients(contactId);
          if (!isCurrent()) return;
          const payload = responsePayload(response);
          if (Number(payload?.contact_id) !== Number(contactId)) {
            throw new Error('patient_context_mismatch');
          }
          entry = this.contexts[key];
          entry.patients = (payload.patients || []).filter(
            patient =>
              patientContactId(patient.id) &&
              Number(patient.account_id) === Number(key.split(':')[0]) &&
              Number(patient.communication_contact_id) === Number(contactId)
          );
          entry.loaded = true;
          const desired = this.selections[key] || entry.selectedId || contactId;
          if (!this.select(key, desired)) this.select(key, contactId);
        } catch (error) {
          if (!isCurrent()) return;
          this.contexts[key].error = error;
          this.contexts[key].patients = [];
          this.contexts[key].selectedId = null;
        } finally {
          if (isCurrent()) this.contexts[key].loading = false;
        }
      },
      async createPatient(key, attributes) {
        const entry = this.contexts[key];
        if (!entry?.loaded || entry.saving) return null;
        const requestId = entry.requestId;
        const contactId = entry.contactId;
        const selectedId = entry.selectedId;
        entry.saving = true;
        try {
          const response = await SchedulingContactsAPI.createPatient(
            contactId,
            attributes
          );
          if (
            this.contexts[key]?.requestId !== requestId ||
            this.contexts[key]?.selectedId !== selectedId
          )
            return null;
          const patient = responsePayload(response);
          if (
            !patientContactId(patient?.id) ||
            Number(patient.account_id) !== Number(key.split(':')[0]) ||
            Number(patient.communication_contact_id) !== contactId
          ) {
            throw new Error('patient_context_mismatch');
          }
          entry.patients = [
            ...entry.patients.filter(
              item => Number(item.id) !== Number(patient.id)
            ),
            patient,
          ];
          this.select(key, patient.id);
          return patient;
        } finally {
          if (this.contexts[key]?.requestId === requestId) entry.saving = false;
        }
      },
      async updatePatient(key, id, attributes) {
        const entry = this.contexts[key];
        const existing = entry?.patients.find(
          patient => Number(patient.id) === Number(id)
        );
        if (
          !entry?.loaded ||
          entry.saving ||
          !canEditLocalPatient(existing) ||
          Number(entry.selectedId) !== Number(id)
        )
          return null;
        const requestId = entry.requestId;
        const selectedId = entry.selectedId;
        const contactId = entry.contactId;
        const isCurrent = () =>
          this.contexts[key]?.requestId === requestId &&
          this.contexts[key]?.contactId === contactId &&
          this.contexts[key]?.selectedId === selectedId;
        if (!Object.keys(attributes).length) return existing;
        entry.saving = true;
        try {
          const response = await SchedulingContactsAPI.update(id, attributes);
          if (!isCurrent()) return null;
          const updated = responsePayload(response);
          if (
            Number(updated?.id) !== Number(id) ||
            Number(updated.account_id) !== Number(existing.account_id)
          ) {
            throw new Error('patient_context_mismatch');
          }
          // A generic contact PATCH returns communication fields. Always reload the
          // patient projection, retaining this employee's current selection.
          const projection = responsePayload(
            await SchedulingContactsAPI.patients(contactId)
          );
          if (!isCurrent()) return null;
          if (Number(projection?.contact_id) !== contactId)
            throw new Error('patient_context_mismatch');
          const patients = (projection.patients || []).filter(
            patient =>
              patientContactId(patient.id) &&
              Number(patient.account_id) === Number(key.split(':')[0]) &&
              Number(patient.communication_contact_id) === contactId
          );
          const patient = patients.find(item => Number(item.id) === Number(id));
          if (!patient) throw new Error('patient_context_mismatch');
          entry.patients = patients;
          this.select(key, selectedId);
          return patient;
        } finally {
          if (this.contexts[key]?.requestId === requestId) entry.saving = false;
        }
      },
    },
  }
);
