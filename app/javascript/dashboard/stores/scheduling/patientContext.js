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
  const dialog = patientContactId(chat?.display_id || chat?.displayId || chat?.id);
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

const readSelections = () => {
  try {
    const values = JSON.parse(
      window.localStorage.getItem(PATIENT_SELECTION_STORAGE_KEY) || '{}'
    );
    return Object.fromEntries(
      Object.entries(values).filter(
        ([key, id]) =>
          /^\d+:\d+:(thread|conversation):\d+$/.test(key) && patientContactId(id)
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
        if (!entry?.patients.some(patient => Number(patient.id) === contactId)) {
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
          entry.patients = (payload.patients || []).filter(patient =>
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
          if (this.contexts[key]?.requestId !== requestId ||
              this.contexts[key]?.selectedId !== selectedId) return null;
          const patient = responsePayload(response);
          if (
            !patientContactId(patient?.id) ||
            Number(patient.account_id) !== Number(key.split(':')[0]) ||
            Number(patient.communication_contact_id) !== contactId
          ) {
            throw new Error('patient_context_mismatch');
          }
          entry.patients = [
            ...entry.patients.filter(item => Number(item.id) !== Number(patient.id)),
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
        const existing = entry?.patients.find(patient => Number(patient.id) === Number(id));
        if (!entry?.loaded || entry.saving || !existing?.patient_contact_id) return null;
        const requestId = entry.requestId;
        const selectedId = entry.selectedId;
        entry.saving = true;
        try {
          const response = await SchedulingContactsAPI.update(id, attributes);
          if (this.contexts[key]?.requestId !== requestId ||
              this.contexts[key]?.selectedId !== selectedId) return null;
          const updated = responsePayload(response);
          if (Number(updated?.id) !== Number(id) ||
              Number(updated.account_id) !== Number(existing.account_id)) {
            throw new Error('patient_context_mismatch');
          }
          const patient = { ...existing, ...updated, phone: updated.phone || existing.phone };
          entry.patients = entry.patients.map(item =>
            Number(item.id) === Number(id) ? patient : item
          );
          return patient;
        } finally {
          if (this.contexts[key]?.requestId === requestId) entry.saving = false;
        }
      },
    },
  }
);
